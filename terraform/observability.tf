# ── Observability (§7) ────────────────────────────────────────────────────────
#
# Deliberately minimal CloudWatch footprint. The proxy emits two *sparse* event
# logs (SNI-spoofing and policy-denied) plus its error log; per-connection access
# logging is disabled by default (see README "Debugging"). A small set of metric
# filters turns those sparse logs into time-series, surfaced by one dashboard.
# Per-request latency / throughput KPIs are out of scope here: added latency is
# covered by the §3 benchmark, and request-rate metrics will later be published
# directly from nginx (stub_status) rather than via per-connection log shipping.

locals {
  log_group_access        = "/aws/firewall-proxy/nginx/access"
  log_group_error         = "/aws/firewall-proxy/nginx/error"
  log_group_sni_spoofing  = "/aws/firewall-proxy/nginx/sni-spoofing"
  log_group_policy_denied = "/aws/firewall-proxy/nginx/policy-denied"
  metric_namespace        = "AwsFirewallProxy/Nginx"
}

# Pre-create the log groups so retention is under our control rather than
# whatever the CW agent decides on first write (default: never expire).
# Group names must match packer/nginx-proxy/assets/cloudwatch/amazon-cloudwatch-agent.json.

# SNI-spoofing: requested SNI is allowlisted but the connection's original
# destination IP is not among the SNI's resolved A records. The attack signal.
resource "aws_cloudwatch_log_group" "proxy_sni_spoofing" {
  name              = local.log_group_sni_spoofing
  retention_in_days = 3
}

# Policy-denied: SNI not in the allowlist, or no SNI present. Normal enforcement.
resource "aws_cloudwatch_log_group" "proxy_policy_denied" {
  name              = local.log_group_policy_denied
  retention_in_days = 3
}

resource "aws_cloudwatch_log_group" "proxy_error" {
  name              = local.log_group_error
  retention_in_days = 3
}

# Per-connection access log. Disabled at the nginx level by default; the group is
# pre-provisioned so enabling debug logging is a one-line nginx toggle, not an
# infra change (see README "Debugging"). Stays empty until then.
resource "aws_cloudwatch_log_group" "proxy_access" {
  name              = local.log_group_access
  retention_in_days = 3
}

# CloudWatchAgentServerPolicy covers CreateLogStream + PutLogEvents on
# any log group. The proxy role already exists in nginx_allowlist.tf.
resource "aws_iam_role_policy_attachment" "proxy_cw_agent" {
  role       = aws_iam_role.proxy.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# ── Metric filters ────────────────────────────────────────────────────────────
# The spoofing and policy-denied groups each hold only their own event type, so
# an empty pattern (match every line) is the event count. Failures key off the
# literal `[error]` tag nginx writes for ngx.ERR (Lua internal failures) and
# upstream connect errors.

resource "aws_cloudwatch_log_metric_filter" "spoofing_detected" {
  name           = "${local.name}-spoofing-detected"
  log_group_name = aws_cloudwatch_log_group.proxy_sni_spoofing.name
  pattern        = ""

  metric_transformation {
    name          = "SpoofingDetected"
    namespace     = local.metric_namespace
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_log_metric_filter" "requests_blocked" {
  name           = "${local.name}-requests-blocked"
  log_group_name = aws_cloudwatch_log_group.proxy_policy_denied.name
  pattern        = ""

  metric_transformation {
    name          = "RequestsBlocked"
    namespace     = local.metric_namespace
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_log_metric_filter" "failures" {
  name           = "${local.name}-failures"
  log_group_name = aws_cloudwatch_log_group.proxy_error.name
  pattern        = "\"[error]\""

  metric_transformation {
    name          = "Failures"
    namespace     = local.metric_namespace
    value         = "1"
    default_value = "0"
  }
}

# ── Dashboard ────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_dashboard" "proxy" {
  dashboard_name = "${local.name}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 8
        height = 6
        properties = {
          title  = "SNI spoofing attacks detected/min"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "Sum"
          metrics = [
            [local.metric_namespace, "SpoofingDetected"],
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 0
        width  = 8
        height = 6
        properties = {
          title  = "Policy-denied requests/min"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          stat   = "Sum"
          metrics = [
            [local.metric_namespace, "RequestsBlocked"],
          ]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 0
        width  = 8
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
        type   = "log"
        x      = 0
        y      = 6
        width  = 24
        height = 6
        properties = {
          title  = "Recent SNI spoofing events"
          region = var.aws_region
          query  = "SOURCE '${aws_cloudwatch_log_group.proxy_sni_spoofing.name}' | fields @timestamp, @message | sort @timestamp desc | limit 20"
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
