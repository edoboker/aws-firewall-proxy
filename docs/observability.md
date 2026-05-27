# monitoring

Minimal CloudWatch wiring for the nginx override proxy and async SNI-spoofing
detector. The TLS proxy path is prevention-first: it forwards to the SNI-derived
upstream and emits compact override observations. Detection happens later from
CloudWatch Logs.

## What's wired

| Signal | Where to see it |
|---|---|
| Override observations | `/aws/firewall-proxy/nginx/override-observations`, shipped from `/var/log/nginx/override_observations.log` |
| Suspected spoofing | Lambda logs for `${env}-proxy-sni-spoofing-detector`, metric `AwsFirewallProxy/SuspectedSniSpoofing`, and the matching CloudWatch alarm |
| Blocked HTTP prototype requests | `/aws/firewall-proxy/nginx/policy-denied` and metric `AwsFirewallProxy/Nginx/HttpRequestsBlocked` |
| Proxy/runtime failures | `/aws/firewall-proxy/nginx/error`, runtime sync logs, AppConfig Agent logs, and Lambda logs |
| Host saturation | CloudWatch dashboard EC2 CPU/memory/network widgets |

## How it works

1. **nginx stream access log**
   writes one JSON observation for each TLS override connection. The JSON body
   intentionally omits instance metadata; the CloudWatch Agent uses
   `log_stream_name = "{instance_id}"`.
2. **CloudWatch Agent**
   tails the override observation file and sends it to
   `/aws/firewall-proxy/nginx/override-observations` with 3-day retention.
3. **CloudWatch Logs subscription**
   invokes the async detector Lambda for each batch of observations.
4. **Detector Lambda**
   decodes the subscription payload, parses each JSON message independently,
   resolves the SNI with bounded DNS timeouts, compares the original destination
   IP, logs structured alerts, and publishes `SuspectedSniSpoofing` on mismatch.

Detection is probabilistic. CDN-backed domains can produce different A-record
sets over time or across resolvers, so alerts are investigation signals and do
not block traffic.

## Design principles

The wiring above follows a few cost-conscious telemetry rules.

**Prefer metrics to per-connection logs.** Aggregated metrics are far cheaper
than shipping one log line per connection, and they drive dashboards and alarms
directly. Override observations are the one intentional per-connection stream,
and they exist only because async detection needs them — not for general
traffic visibility.

**Keep metric dimensions low-cardinality.** Safe dimensions are bounded sets:
`InstanceId`, `AutoScalingGroup`, `AvailabilityZone`, and coarse decision labels
(e.g. `Decision=allow|block`, `Reason=sni_mismatch|dns_failure|allowlist_denied`).
Never use per-request values — SNI, source/destination IP, resolved IP, or
request ID — as dimensions; each distinct value becomes its own billed metric.

**Log security events sparsely.** Emit a structured line only when something
meaningful happens: an SNI/destination mismatch, a blocked request, a DNS
failure under fail-closed policy, a missing original destination, or a
config/internal error. Do not log every allowed SNI, resolved IP, original
destination, connect time, or successful decision — that is high-volume,
low-value telemetry.

**Measure latency by aggregation, not logging.** To track decision, DNS, or
upstream-connect latency, aggregate internally and publish percentiles
periodically rather than logging each connection's timings. If true percentiles
are impractical at first, start with count/sum/min/max or a bucketed histogram
and approximate from there.

## Operational notes

Observability is tuned for a small CloudWatch footprint. Override observations
are always written as compact JSON to
`/var/log/nginx/override_observations.log` and shipped to
`/aws/firewall-proxy/nginx/override-observations`. The CloudWatch log stream
name is the EC2 instance ID, so the async detector can include that context in
alert logs without adding instance metadata to the nginx JSON body.

The CloudWatch Agent publishes host CPU and memory metrics every 60 seconds.
The legacy request-path Lua metrics were removed with the resolve-and-block
guard; the TLS override path does not emit per-connection Lua metrics.

For verbose Lua diagnostics on the experimental HTTP path, set `PROXY_DEBUG=1`
in `/etc/sysconfig/aws-firewall-proxy-runtime` and restart nginx. The TLS
override path does not use Lua.

## Ad-hoc Logs Insights queries

**Recent override observations** - run against `/aws/firewall-proxy/nginx/override-observations`:
```text
fields @timestamp, sni, original_destination_ip, upstream_host_used, @logStream
| sort @timestamp desc
| limit 50
```

**Original destination mismatches flagged by Lambda** - run against `/aws/lambda/<env>-proxy-sni-spoofing-detector`:
```text
fields @timestamp, sni, original_destination_ip, resolved_ips, proxy_instance_id
| filter event = "suspected_sni_spoofing"
| sort @timestamp desc
| limit 50
```
