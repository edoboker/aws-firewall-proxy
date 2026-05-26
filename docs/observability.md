# monitoring

Minimal CloudWatch wiring for the nginx proxy and async SNI-spoofing detector.
The TLS proxy path is prevention-first: it forwards to the SNI-derived upstream
and emits compact override observations. Detection happens later from
CloudWatch Logs.

## What's wired

| Signal | Where to see it |
|---|---|
| Override observations | `/aws/firewall-proxy/nginx/override-observations`, shipped from `/var/log/nginx/override_observations.log` |
| Suspected spoofing | Lambda logs for `${env}-proxy-sni-spoofing-detector` and metric `AwsFirewallProxy/SuspectedSniSpoofing` |
| Blocked HTTP prototype requests | `/aws/firewall-proxy/nginx/policy-denied` and the existing dashboard connection widgets |
| Proxy/runtime failures | `/aws/firewall-proxy/nginx/error`, runtime sync logs, and Lambda logs |
| Host saturation | Existing CloudWatch dashboard EC2 CPU/memory/network widgets |

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
