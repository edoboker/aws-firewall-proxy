# monitoring

Minimal CloudWatch wiring for the nginx proxy — enough to demonstrate
the §7 KPIs (`steering/production-grade-plan.md`) work end-to-end. Cache
and data-plane latency are deliberately out of scope here (see §3 and
the `benchmark/` directory).

## What's wired

| §7 KPI | Where to see it |
|---|---|
| Failures | Dashboard widget *nginx failures/min* (from nginx `error.log`) |
| Detected attacks | *Proxy requests/min* `denied` series — SNI-spoof / not-in-allowlist attempts the nginx gate blocks |
| Repeating FQDNs / SNIs | Dashboard widget *Top 10 SNIs* (Logs Insights query) |
| Added latency | Already covered by `benchmark/run.py` — not duplicated here |
| Cache hits | Cache not implemented yet — wired in once the §3 cache sub-task lands |

## How it works

1. **CloudWatch agent baked into the nginx AMI** (`packer/nginx-proxy/files/cloudwatch-agent.json`)
   tails `/var/log/nginx/{access,error}.log` and ships them to two log
   groups under `/aws/firewall-proxy/nginx/`.
2. **Three metric filters** (`terraform/observability.tf`) turn lines
   into time-series under namespace `AwsFirewallProxy/Nginx`:
   `RequestsAllowed`, `RequestsDenied`, `Failures`.
3. **One CloudWatch dashboard** (`${env}-proxy-dashboard`) renders the three
   widgets. URL is exposed as the `proxy_dashboard_url` terraform output.

## Verify

After `packer build` (nginx AMI) and `terraform apply`:

```bash
# 1. Open the dashboard
terraform -chdir=terraform output -raw proxy_dashboard_url

# 2. Generate traffic from the workload via SSM
aws ssm send-command \
  --instance-ids "$(terraform -chdir=terraform output -raw workload_instance_id)" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["for i in $(seq 1 20); do curl -sk https://google.com >/dev/null; done"]'

# 3. After ~1 minute, expect non-zero data on every widget.
```

## Ad-hoc Logs Insights queries

Run against `/aws/firewall-proxy/nginx/access`:

**Top SNIs** (same query the dashboard widget uses):
```
parse @message /sni="(?<sni>[^"]*)"/
| stats count(*) as requests by sni
| sort requests desc
| limit 10
```

**Denials by SNI** (which FQDNs are clients trying to reach that nginx
is blocking?):
```
parse @message /sni="(?<sni>[^"]*)" allowed=(?<allowed>\d)/
| filter allowed = "0"
| stats count(*) as denied by sni
| sort denied desc
```

**Recent failures** (run against `/aws/firewall-proxy/nginx/error`):
```
fields @timestamp, @message
| sort @timestamp desc
| limit 50
```
