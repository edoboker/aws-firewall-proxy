# Observability (§7)
#
# Keep the CloudWatch footprint intentionally small: sparse event logs for
# meaningful security signals, plus direct proxy metrics published through the
# local CloudWatch agent StatsD listener every N seconds.

locals {
  log_group_access        = "/aws/firewall-proxy/nginx/access"
  log_group_error         = "/aws/firewall-proxy/nginx/error"
  log_group_sni_spoofing  = "/aws/firewall-proxy/nginx/sni-spoofing"
  log_group_policy_denied = "/aws/firewall-proxy/nginx/policy-denied"
  metric_namespace        = "AwsFirewallProxy/Nginx"
  # CloudWatch dashboards reject metric widget periods below 60 seconds, even
  # when the agent publishes proxy metrics more frequently.
  dashboard_metric_period_seconds = max(var.proxy_metrics_publish_interval_seconds, 60)
}

resource "aws_cloudwatch_log_group" "proxy_sni_spoofing" {
  name              = local.log_group_sni_spoofing
  retention_in_days = 3
}

resource "aws_cloudwatch_log_group" "proxy_policy_denied" {
  name              = local.log_group_policy_denied
  retention_in_days = 3
}

resource "aws_cloudwatch_log_group" "proxy_error" {
  name              = local.log_group_error
  retention_in_days = 3
}

resource "aws_cloudwatch_log_group" "proxy_access" {
  name              = local.log_group_access
  retention_in_days = 3
}

resource "aws_iam_role_policy_attachment" "proxy_cw_agent" {
  role       = aws_iam_role.proxy.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Keep the sparse log-derived metrics for backwards compatibility and ad-hoc
# correlation, but the dashboard below prefers the direct proxy metrics.
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
          title  = "Requests/sec"
          region = var.aws_region
          view   = "timeSeries"
          period = local.dashboard_metric_period_seconds
          metrics = [
            [local.metric_namespace, "Requests", "InstanceId", aws_instance.proxy.id, "metric_type", "counter", { id = "m1", stat = "Sum", visible = false }],
            [{ expression = "m1/${local.dashboard_metric_period_seconds}", id = "e1", label = "Requests/sec" }],
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
          title  = "Connections"
          region = var.aws_region
          view   = "timeSeries"
          period = local.dashboard_metric_period_seconds
          metrics = [
            [local.metric_namespace, "ActiveConnections", "InstanceId", aws_instance.proxy.id, "metric_type", "gauge", { label = "Active", stat = "Average" }],
            [".", "AcceptedConnections", ".", ".", ".", "counter", { label = "Accepted", stat = "Sum" }],
            [".", "BlockedConnections", ".", ".", ".", "counter", { label = "Blocked", stat = "Sum" }],
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
          title  = "Security and Failure Signals"
          region = var.aws_region
          view   = "timeSeries"
          period = local.dashboard_metric_period_seconds
          metrics = [
            [local.metric_namespace, "SniMismatchCount", "InstanceId", aws_instance.proxy.id, "metric_type", "counter", { label = "SNI mismatch", stat = "Sum" }],
            [".", "DnsResolutionFailureCount", ".", ".", ".", ".", { label = "DNS failures", stat = "Sum" }],
            [".", "UpstreamConnectFailureCount", ".", ".", ".", ".", { label = "Upstream connect failures", stat = "Sum" }],
            [".", "InternalFailureCount", ".", ".", ".", ".", { label = "Internal failures", stat = "Sum" }],
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
          title  = "Proxy Decision Latency"
          region = var.aws_region
          view   = "timeSeries"
          period = local.dashboard_metric_period_seconds
          metrics = [
            [local.metric_namespace, "P50ProxyDecisionLatencyMs", "InstanceId", aws_instance.proxy.id, "metric_type", "gauge", { label = "p50", stat = "Average" }],
            [".", "P95ProxyDecisionLatencyMs", ".", ".", ".", ".", { label = "p95", stat = "Average" }],
            [".", "P99ProxyDecisionLatencyMs", ".", ".", ".", ".", { label = "p99", stat = "Average" }],
          ]
          yAxis = {
            left = {
              label = "Milliseconds"
            }
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Upstream Connect Latency"
          region = var.aws_region
          view   = "timeSeries"
          period = local.dashboard_metric_period_seconds
          metrics = [
            [local.metric_namespace, "P50UpstreamConnectLatencyMs", "InstanceId", aws_instance.proxy.id, "metric_type", "gauge", { label = "p50", stat = "Average" }],
            [".", "P95UpstreamConnectLatencyMs", ".", ".", ".", ".", { label = "p95", stat = "Average" }],
            [".", "P99UpstreamConnectLatencyMs", ".", ".", ".", ".", { label = "p99", stat = "Average" }],
          ]
          yAxis = {
            left = {
              label = "Milliseconds"
            }
          }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "Host Saturation"
          region = var.aws_region
          view   = "timeSeries"
          period = local.dashboard_metric_period_seconds
          metrics = [
            [local.metric_namespace, "CPUUtilization", "InstanceId", aws_instance.proxy.id, { label = "CPU", stat = "Average" }],
            [".", "MemoryUtilization", ".", ".", { label = "Memory", stat = "Average" }],
          ]
          yAxis = {
            left = {
              label = "Percent"
              max   = 100
              min   = 0
            }
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "Network Throughput"
          region = var.aws_region
          view   = "timeSeries"
          period = local.dashboard_metric_period_seconds
          metrics = [
            ["AWS/EC2", "NetworkIn", "InstanceId", aws_instance.proxy.id, { label = "NetworkIn", stat = "Sum" }],
            [".", "NetworkOut", ".", ".", { label = "NetworkOut", stat = "Sum" }],
          ]
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 18
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
