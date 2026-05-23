# monitoring

Minimal CloudWatch wiring for the nginx proxy - enough to demonstrate the section 7 KPIs in `steering/production-grade-plan.md` end to end. Cache and data-plane latency are still out of scope here.

## What's wired

| KPI | Where to see it |
|---|---|
| Failures | Dashboard widget *nginx failures/min* from `error.log` |
| Detected attacks | Dashboard widget *ANF alert volume* plus nginx `denied` request series and spoofing `WARN` lines in `/aws/firewall-proxy/nginx/error` |
| Repeating FQDNs / SNIs | Dashboard widget *Top 10 SNIs* |
| Added latency | Covered separately by `benchmark/run.py` |
| Cache hits | Not implemented yet |

## How it works

1. **CloudWatch agent baked into the nginx AMI** at `packer/nginx-proxy/assets/cloudwatch/amazon-cloudwatch-agent.json` tails `/var/log/nginx/{access,error}.log` and ships them to two log groups under `/aws/firewall-proxy/nginx/`.
2. **Three metric filters** in `terraform/observability.tf` turn access and error log lines into time-series under namespace `AwsFirewallProxy/Nginx`.
3. **One CloudWatch dashboard** renders the key widgets. Its URL is exposed as the `proxy_dashboard_url` Terraform output.

## Verify

After `packer build` and `terraform apply`:

```bash
# 1. Open the dashboard
terraform -chdir=terraform output -raw proxy_dashboard_url

# 2. Generate normal traffic from the workload via SSM
aws ssm send-command \
  --instance-ids "$(terraform -chdir=terraform output -raw workload_instance_id)" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["for i in $(seq 1 20); do curl -sk https://google.com >/dev/null; done"]'

# 3. Generate one spoof attempt
aws ssm send-command \
  --instance-ids "$(terraform -chdir=terraform output -raw workload_instance_id)" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["curl -sk --resolve google.com:443:1.1.1.1 https://google.com >/dev/null || true"]'
```

After about a minute you should see:

- request metrics in the access-log-backed widgets
- spoofing `WARN` lines in `/aws/firewall-proxy/nginx/error`

## Ad-hoc Logs Insights queries

Run against `/aws/firewall-proxy/nginx/access`:

**Top SNIs**
```text
parse @message /sni="(?<sni>[^"]*)"/
| stats count(*) as requests by sni
| sort requests desc
| limit 10
```

**Denials by SNI**
```text
parse @message /sni="(?<sni>[^"]*)" allowed=(?<allowed>\d)/
| filter allowed = "0"
| stats count(*) as denied by sni
| sort denied desc
```

Run against `/aws/firewall-proxy/nginx/error`:

**Recent spoof detections**
```text
fields @timestamp, @message
| filter @message like /sni_spoofing_detected/
| sort @timestamp desc
| limit 50
```

**Recent internal failures**
```text
fields @timestamp, @message
| filter @message not like /sni_spoofing_detected/
| sort @timestamp desc
| limit 50
```
