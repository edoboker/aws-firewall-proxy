# ── Observability (§7) ────────────────────────────────────────────────────────
#
# Minimal CloudWatch wiring that proves the §7 KPIs are visible end-to-end:
# nginx access + error logs shipped from the proxy EC2, three metric filters
# turning log lines into time-series, and a single dashboard surfacing the
# whole story. Cache hits and data-plane latency are out of scope here
# (covered by §3 benchmark / cache sub-task).

locals {
  log_group_access = "/aws/firewall-proxy/nginx/access"
  log_group_error  = "/aws/firewall-proxy/nginx/error"
  metric_namespace = "AwsFirewallProxy/Nginx"
}

# Pre-create the log groups so retention is under our control rather than
# whatever the CW agent decides on first write (default: never expire).
# Group names must match packer/nginx-proxy/assets/cloudwatch/amazon-cloudwatch-agent.json.
resource "aws_cloudwatch_log_group" "proxy_access" {
  name              = local.log_group_access
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "proxy_error" {
  name              = local.log_group_error
  retention_in_days = 7
}

# CloudWatchAgentServerPolicy covers CreateLogStream + PutLogEvents on
# any log group. The proxy role already exists in nginx_allowlist.tf.
resource "aws_iam_role_policy_attachment" "proxy_cw_agent" {
  role       = aws_iam_role.proxy.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# ── Metric filters ────────────────────────────────────────────────────────────
# nginx log_format `proxy` (packer/nginx-proxy/assets/nginx/conf/nginx.conf.template) ends each
# line with `allowed=1` or `allowed=0`. Substring matching is enough.

resource "aws_cloudwatch_log_metric_filter" "requests_allowed" {
  name           = "${local.name}-requests-allowed"
  log_group_name = aws_cloudwatch_log_group.proxy_access.name
  pattern        = "\"allowed=1\""

  metric_transformation {
    name          = "RequestsAllowed"
    namespace     = local.metric_namespace
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_log_metric_filter" "requests_denied" {
  name           = "${local.name}-requests-denied"
  log_group_name = aws_cloudwatch_log_group.proxy_access.name
  pattern        = "\"allowed=0\""

  metric_transformation {
    name          = "RequestsDenied"
    namespace     = local.metric_namespace
    value         = "1"
    default_value = "0"
  }
}

# Failures: any line in nginx error.log. Stream-mode access status (200)
# isn't a reliable success/fail signal, so error log volume is the cleaner
# KPI here.
resource "aws_cloudwatch_log_metric_filter" "failures" {
  name           = "${local.name}-failures"
  log_group_name = aws_cloudwatch_log_group.proxy_error.name
  pattern        = ""

  metric_transformation {
    name          = "Failures"
    namespace     = local.metric_namespace
    value         = "1"
    default_value = "0"
  }
}

# ── Dashboard ────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_dashboard" "proxy" {
  dashboard_name = "${local.name}-proxy"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Proxy requests/min (allowed vs denied)"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = true
          period  = 60
          stat    = "Sum"
          metrics = [
            [local.metric_namespace, "RequestsAllowed"],
            [local.metric_namespace, "RequestsDenied"],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "nginx failures/min"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "Sum"
          metrics = [
            [local.metric_namespace, "Failures"],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "ANF alert volume (detected attacks)"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/Logs", "IncomingLogEvents", "LogGroupName", aws_cloudwatch_log_group.anf_alert.name],
          ]
        }
      },
      {
        type   = "log"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Top 10 SNIs (last 1h)"
          region = var.aws_region
          query  = "SOURCE '${aws_cloudwatch_log_group.proxy_access.name}' | parse @message /sni=\"(?<sni>[^\"]*)\"/ | stats count(*) as requests by sni | sort requests desc | limit 10"
          view   = "table"
        }
      },
    ]
  })
}

output "proxy_dashboard_url" {
  description = "CloudWatch dashboard URL for proxy observability (§7)"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.proxy.dashboard_name}"
}
