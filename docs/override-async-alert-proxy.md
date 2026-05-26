**Original prompt for goal**:

You are working in the existing aws-firewall-proxy repository.

Goal:
Implement a new “override proxy + async spoofing detection” architecture.

High-level behavior:
1. The NGINX/OpenResty transparent proxy should continue to intercept outbound TCP/443 traffic.
2. It should parse the TLS ClientHello SNI without terminating TLS.
3. It should ignore/override the original destination IP for the actual upstream connection:
   - upstream should be `$ssl_preread_server_name:443`
   - the client’s original destination IP should NOT be used for forwarding.
4. It must still recover and log the original destination IP using the existing SO_ORIGINAL_DST mechanism / C module.
5. For each proxied TLS connection, emit a compact structured JSON security-observation log containing:
   - timestamp
   - source IP
   - source port
   - SNI
   - original destination IP
   - original destination port
   - upstream host used by proxy
   - proxy decision, e.g. `override_allow`
   - proxy instance ID if available
   - availability zone if available
   - request/session ID if easy to generate
6. Ship these logs to CloudWatch Logs.
7. Create a Lambda function triggered by a CloudWatch Logs subscription filter.
8. The Lambda should parse these JSON events, resolve the SNI, and detect possible SNI spoofing:
   - resolve A records for the SNI
   - optionally chase CNAMEs if the resolver library does not do this automatically
   - compare `original_destination_ip` against the resolved IP set
   - if original destination IP is not in the resolved set, treat it as suspected spoofing
9. For suspected spoofing, the Lambda should:
   - log a structured alert event
   - publish a custom CloudWatch metric, e.g. namespace `AwsFirewallProxy`, metric `SuspectedSniSpoofing`
   - include low-cardinality dimensions only, for example `Environment`, `ProxyAutoScalingGroup`, or `DecisionReason`
   - DO NOT use SNI, source IP, or destination IP as metric dimensions
10. Add a CloudWatch Alarm on the custom metric, for example alarm when `SuspectedSniSpoofing >= 1` over a short evaluation window.
11. Keep the design fail-safe:
   - logging/CloudWatch/Lambda failures must not block proxy traffic
   - proxy forwarding path should remain simple and deterministic
   - detection is asynchronous and probabilistic
12. Update README/docs with the new architecture and caveats.

Important architectural framing:
- This architecture is prevention-first.
- The proxy prevents the actual malicious destination from being contacted because it always forwards to the proxy-resolved SNI destination.
- Detection is asynchronous: the proxy logs `{SNI, original_dst}` and the Lambda later checks whether the original destination appears valid for that SNI.
- Detection is probabilistic because DNS answers vary over time, especially for CDN-backed services.
- False positives are acceptable for the first version because they do not block traffic.
- Do not claim this provides perfect detection.

Implementation requirements:

NGINX / OpenResty:
- Use stream mode.
- Use `ssl_preread on`.
- Use `proxy_pass $ssl_preread_server_name:443`.
- Keep or add the existing original-destination recovery logic.
- Emit JSON logs for override observations.
- Prefer sparse/compact logs but for this feature log each proxied connection observation unless there is already a debug flag or config option.
- If per-connection logs are too expensive for default mode, add a runtime config flag such as `enable_override_observation_logs`.

CloudWatch Logs:
- Ensure the NGINX observation log file is collected by CloudWatch Agent.
- Create a dedicated log group, for example:
  `/aws/firewall-proxy/nginx/override-observations`
- Use short retention by default, e.g. 3 days, unless repository conventions say otherwise.

Lambda:
- Runtime: Python 3.12 unless repo conventions prefer another runtime.
- Trigger: CloudWatch Logs subscription filter on the override-observation log group.
- Decode CloudWatch Logs subscription payload:
  - base64 decode
  - gzip decompress
  - parse JSON wrapper
  - iterate over `logEvents`
  - parse each event message as JSON
- For each event:
  - validate required fields
  - canonicalize SNI: lowercase, strip trailing dot
  - resolve A records
  - compare original destination IP
  - publish metric on mismatch
  - log full structured alert details to Lambda logs
- Use bounded DNS timeouts so the Lambda cannot hang on slow resolution.
- Handle NXDOMAIN, timeout, SERVFAIL, malformed SNI, and missing original destination cleanly.
- Do not crash the entire batch because of one bad log event.

CloudWatch Alarm:
- Add Terraform for a CloudWatch metric alarm:
  - Metric namespace: `AwsFirewallProxy`
  - Metric name: `SuspectedSniSpoofing`
  - Statistic: Sum
  - Period: 60 or 300 seconds
  - Threshold: >= 1
  - Evaluation periods: 1
  - Treat missing data: notBreaching
- If the repo already has SNS/EventBridge alarm plumbing, integrate with it.
- Otherwise create the alarm only and document how to attach notification actions later.

Terraform:
- Add all required resources:
  - Lambda function
  - IAM role and policy
  - permission for CloudWatch Logs to invoke Lambda
  - CloudWatch Logs subscription filter
  - CloudWatch metric alarm
  - log group retention if needed
- Least privilege:
  - Lambda needs `cloudwatch:PutMetricData`
  - Lambda needs normal CloudWatch Logs execution permissions
  - no broad admin permissions
- Keep resource naming consistent with existing `var.env` / project naming conventions.

Testing:
- Add unit tests for the Lambda event parser and detector logic.
- Include tests for:
  - valid event with matching IP
  - valid event with mismatching IP
  - malformed JSON
  - missing SNI
  - missing original destination IP
  - DNS resolution failure
- Mock DNS resolution in tests.
- Add a simple integration/manual test doc:
  - normal curl to allowed domain
  - spoofed curl using `--resolve`
  - verify proxy still succeeds by overriding destination
  - verify CloudWatch log contains original spoofed destination
  - verify Lambda emits suspected spoofing metric/alarm

Suggested event format:

{
  "event_type": "sni_override_observation",
  "timestamp": "2026-05-26T12:34:56.123Z",
  "src_ip": "10.0.1.25",
  "src_port": 52144,
  "sni": "google.com",
  "original_dst_ip": "1.1.1.1",
  "original_dst_port": 443,
  "upstream_host": "google.com",
  "decision": "override_allow",
  "proxy_instance_id": "i-xxxxxxxx",
  "availability_zone": "eu-west-1a",
  "session_id": "optional-random-id"
}

Suggested Lambda alert log format:

{
  "event_type": "suspected_sni_spoofing",
  "timestamp": "...",
  "sni": "google.com",
  "original_dst_ip": "1.1.1.1",
  "resolved_ips": ["142.250.185.14", "142.250.185.46"],
  "proxy_instance_id": "i-xxxxxxxx",
  "availability_zone": "eu-west-1a",
  "confidence": "medium_high",
  "reason": "original_dst_not_in_current_dns_answers"
}

Caveats to document:
- This architecture provides deterministic prevention because the proxy overrides the original destination.
- Detection is asynchronous and DNS-based, so it may produce false positives for CDN-backed domains, stale DNS, resolver-location differences, or short TTLs.
- Since detection does not block traffic, false positives affect alert quality but not application availability.
- This does not solve ECH, QUIC/HTTP3, no-SNI TLS, or domain-fronting where the inner HTTP Host differs from SNI.
- Do not put high-cardinality values such as SNI/source IP/destination IP into CloudWatch metric dimensions.

Before editing:
1. Inspect the current repository structure.
2. Identify existing NGINX/OpenResty config, Lua files, C module/original destination logic, CloudWatch Agent config, Terraform layout, and tests.
3. Produce a short implementation plan.
4. Then implement the smallest coherent version.
5. Keep changes minimal and aligned with existing style.


**Plan**:

Override Proxy + Async SNI Spoofing Detection
Summary
Remove Lua from the TLS override path entirely.
Use nginx stream ssl_preread for SNI, the existing C module for SO_ORIGINAL_DST, and nginx access_log JSON for observations.
Start with minimal static/unit tests only; defer live AWS tests.
Key Changes
NGINX/OpenResty:

Remove preread_by_lua_file /etc/nginx/lua/check_sni.lua; from the TLS server.
Remove Lua metrics/log hooks from the TLS override server for now.
Add ssl_preread on;.
Set proxy_pass $ssl_preread_server_name:443.
Keep load_module ...ngx_stream_original_dst_module.so; and $original_dst.
Add stream map rules to split $original_dst into:
$original_destination_ip
$original_destination_port
Add log_format escape=json override_observation using only nginx variables:
timestamp: $time_iso8601
source_ip: $remote_addr
source_port: $remote_port
sni: $ssl_preread_server_name
original_destination_ip
original_destination_port
upstream_host_used: $ssl_preread_server_name
Write observations to /var/log/nginx/override_observations.log.
Do not include proxy_instance_id in the nginx JSON line.
CloudWatch Logs:

Add /aws/firewall-proxy/nginx/override-observations with 3-day retention.
Add /var/log/nginx/override_observations.log to CloudWatch Agent collect_list.
Use log_stream_name = "{instance_id}", matching existing repo style.
Lambda may treat subscription payload logStream as optional proxy instance context.
Lambda:

Add Python python3.12 Lambda for async detection.
Decode CloudWatch Logs subscription payload: base64, gzip, JSON wrapper, logEvents.
Parse each observation JSON event independently.
Canonicalize SNI by lowercasing and stripping trailing dot.
Resolve A records with bounded DNS timeouts and limited CNAME chasing.
Compare original_destination_ip to resolved IPs.
On mismatch, log structured alert JSON and publish:
namespace: AwsFirewallProxy
metric: SuspectedSniSpoofing
Include logStream as proxy_instance_id in Lambda alert logs only if available.
Terraform:

Add Lambda package, IAM role/policy, Lambda log group, invoke permission, CloudWatch Logs subscription filter, and metric alarm.
Keep permissions narrow: Lambda log writes plus cloudwatch:PutMetricData.
Follow existing ${local.name} naming.
Avoid unnecessary removal of old log groups/resources in this first pass.
Tests
Minimal static/unit only:
Terraform static assertions for override log group, subscription filter, Lambda permission, IAM metric policy, and alarm.
Python unit tests for Lambda payload decoding.
Python unit tests for malformed event isolation.
Mock DNS and CloudWatch client; assert metric publish only on mismatch.
No live AWS tests yet.
Assumptions
The C module remains original-destination recovery only.
SNI source of truth is nginx $ssl_preread_server_name.
Instance ID does not need to be inside the nginx JSON event for v1.
Detection is async and probabilistic; it must never block proxy traffic.
