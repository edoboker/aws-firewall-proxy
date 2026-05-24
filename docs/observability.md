# monitoring

Minimal CloudWatch wiring for the nginx proxy — enough to demonstrate the
section 7 KPIs in `docs/production-grade-plan.md` end to end, with a
deliberately small footprint. The proxy ships sparse event logs for meaningful
security events and publishes aggregated metrics directly through the local
CloudWatch agent StatsD listener every
`proxy_metrics_publish_interval_seconds` seconds (default `20`).

## What's wired

| KPI | Where to see it |
|---|---|
| Detected attacks | Dashboard widget *Security and Failure Signals* plus *Recent SNI spoofing events*, from direct `SniMismatchCount` metrics and the dedicated `/aws/firewall-proxy/nginx/sni-spoofing` log |
| Blocked requests | Dashboard widget *Connections* from direct `BlockedConnections` metrics |
| Failures | Dashboard widget *Security and Failure Signals* from direct `DnsResolutionFailureCount`, `UpstreamConnectFailureCount`, and `InternalFailureCount` metrics |
| Added latency | Covered separately by `benchmark/run.py` — not duplicated here |
| Request rate / p50-p99 latency | Dashboard widgets *Requests/sec*, *Proxy Decision Latency*, and *Upstream Connect Latency* from direct proxy metrics |
| Cache hits | Cache not implemented yet — wired in once the section 3 cache sub-task lands |

## How it works

1. **CloudWatch agent baked into the nginx AMI**
   renders its config on boot, tails the nginx/runtime logs, and listens on
   local StatsD `127.0.0.1:8125`.
2. **Direct proxy metrics from OpenResty/Lua**
   aggregate counts, active sessions, and latency histograms on-host, then
   flush one set of low-cardinality metrics every publish interval.
3. **Sparse event logs from nginx**
   `access_log ... if=$is_spoofing` and `access_log ... if=$is_policy_denied`
   write a line only on a `mismatch` / `deny_allowlist` / `drop_no_sni`
   decision — event-driven, not per-connection. Lua internal failures still go
   to `error.log` headed `lua="sni-guard"`.
4. **CloudWatch dashboard**
   `${env}-proxy-dashboard` renders request rate, connection outcomes, latency
   percentiles, host saturation, and a recent spoofing-events table. URL is
   exposed as the `proxy_dashboard_url` Terraform output.

All log groups use 3-day retention.

## Verify

After `packer build` and `terraform apply`:

```bash
# 1. Open the dashboard
terraform -chdir=terraform output -raw proxy_dashboard_url

# 2. Generate traffic
pytest -v tests/test_proxy_metrics.py
```

After one or two publish intervals you should see the direct proxy metrics on
the dashboard, matching entries in the `sni-spoofing` / `policy-denied` groups,
and no spoofing lines in `error.log`.

## Ad-hoc Logs Insights queries

**Recent spoofing events** — run against `/aws/firewall-proxy/nginx/sni-spoofing`:
```text
fields @timestamp, @message
| sort @timestamp desc
| limit 50
```

**Repeating spoofed SNIs** — run against `/aws/firewall-proxy/nginx/sni-spoofing`:
```text
parse @message /sni="(?<sni>[^"]*)"/
| stats count(*) as attempts by sni
| sort attempts desc
```

**Denials by SNI** — run against `/aws/firewall-proxy/nginx/policy-denied`:
```text
parse @message /sni="(?<sni>[^"]*)"/
| stats count(*) as denied by sni
| sort denied desc
```

**Recent internal failures** — run against `/aws/firewall-proxy/nginx/error`:
```text
fields @timestamp, @message
| filter @message like /lua="sni-guard"/
| sort @timestamp desc
| limit 50
```
