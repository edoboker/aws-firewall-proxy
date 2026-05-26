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

## Operational notes

Observability is tuned for a small CloudWatch footprint. Override observations
are always written as compact JSON to
`/var/log/nginx/override_observations.log` and shipped to
`/aws/firewall-proxy/nginx/override-observations`. The CloudWatch log stream
name is the EC2 instance ID, so the async detector can include that context in
alert logs without adding instance metadata to the nginx JSON body.

The proxy publishes aggregated metrics directly to the local CloudWatch Agent
every `proxy_metrics_publish_interval_seconds` seconds.

The per-connection access log is disabled by default because it can dominate
CloudWatch Logs ingestion cost. To capture it temporarily, uncomment
`access_log /var/log/nginx/access.log proxy;` in `/etc/nginx/nginx.conf` on a
running proxy instance and reload nginx. To bake it into the AMI, uncomment the
same line in `packer/nginx-proxy/assets/nginx/conf/nginx.conf.template` and
rebuild.

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
