# monitoring

Minimal CloudWatch wiring for the nginx proxy — enough to demonstrate the
section 7 KPIs in `steering/production-grade-plan.md` end to end, with a
deliberately small footprint. The proxy ships *sparse event logs*, not
per-connection access logs (see the project README "Debugging" for how to
turn the access log on temporarily).

## What's wired

| KPI | Where to see it |
|---|---|
| Detected attacks | Dashboard widget *SNI spoofing attacks detected/min* + *Recent SNI spoofing events*, from the dedicated `/aws/firewall-proxy/nginx/sni-spoofing` log |
| Blocked requests | Dashboard widget *Policy-denied requests/min*, from `/aws/firewall-proxy/nginx/policy-denied` (SNI not in allowlist / no SNI) |
| Failures | Dashboard widget *nginx failures/min*, from `[error]` lines in `/aws/firewall-proxy/nginx/error` (Lua internal failures + upstream connect errors) |
| Added latency | Covered separately by `benchmark/run.py` — not duplicated here |
| P95 request time / request rate | Deferred: would require per-connection logging. A later version publishes these directly from nginx (stub_status), not via log shipping |
| Cache hits | Cache not implemented yet — wired in once the §3 cache sub-task lands |

## How it works

1. **CloudWatch agent baked into the nginx AMI**
   (`packer/nginx-proxy/assets/cloudwatch/amazon-cloudwatch-agent.json`) tails the
   nginx logs and ships them to four log groups under `/aws/firewall-proxy/nginx/`:
   `sni-spoofing`, `policy-denied`, `error`, and `access` (the last stays empty
   unless per-connection logging is enabled — debug only).
2. **Sparse event logs from nginx** (`packer/nginx-proxy/assets/nginx/conf/nginx.conf.template`):
   `access_log … if=$is_spoofing` and `access_log … if=$is_policy_denied` write a
   line *only* on a `mismatch` / `deny_allowlist` / `drop_no_sni` decision —
   event-driven, not per-connection. Lua internal failures go to `error.log`
   headed `lua="sni-guard"`.
3. **Three metric filters** (`terraform/observability.tf`) under namespace
   `AwsFirewallProxy/Nginx`: `SpoofingDetected`, `RequestsBlocked`, `Failures`.
4. **One CloudWatch dashboard** (`${env}-proxy-dashboard`) renders the spoofing,
   policy-denied, and failures series plus a recent-spoofing-events table. URL is
   exposed as the `proxy_dashboard_url` Terraform output.

All log groups use 3-day retention (forensic window without paying for long-term
CloudWatch Logs storage).

## Verify

After `packer build` and `terraform apply`:

```bash
# 1. Open the dashboard
terraform -chdir=terraform output -raw proxy_dashboard_url

# 2. Allowed traffic (silent in v2 — no spoofing/deny lines expected)
aws ssm send-command \
  --instance-ids "$(terraform -chdir=terraform output -raw workload_instance_id)" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["for i in $(seq 1 20); do curl -sk https://google.com >/dev/null; done"]'

# 3. A blocked request (SNI not in the allowlist) -> policy-denied log + RequestsBlocked
aws ssm send-command \
  --instance-ids "$(terraform -chdir=terraform output -raw workload_instance_id)" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["curl -sk https://example.org >/dev/null || true"]'

# 4. A spoof attempt (allowlisted SNI pointed at a non-matching IP) -> sni-spoofing log + SpoofingDetected
aws ssm send-command \
  --instance-ids "$(terraform -chdir=terraform output -raw workload_instance_id)" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["curl -sk --resolve google.com:443:1.1.1.1 https://google.com >/dev/null || true"]'
```

After about a minute you should see `SpoofingDetected` and `RequestsBlocked`
data on the dashboard, matching entries in the `sni-spoofing` / `policy-denied`
groups, and **no** spoofing lines in `error.log`.

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
