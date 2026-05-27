# Observability for the override proxy and async SNI-spoofing detector.
#
# The TLS path emits compact override observations; the detector Lambda turns
# those observations into the AwsFirewallProxy/SuspectedSniSpoofing signal.
# The experimental HTTP listener has a small policy-denied log, but no request
# path Lua metrics are published.

locals {
  log_group_error         = "/aws/firewall-proxy/nginx/error"
  log_group_policy_denied = "/aws/firewall-proxy/nginx/policy-denied"
  nginx_metric_namespace  = "AwsFirewallProxy/Nginx"
  dashboard_period        = 300
}

resource "aws_cloudwatch_log_group" "proxy_policy_denied" {
  name              = local.log_group_policy_denied
  retention_in_days = 3
}

resource "aws_cloudwatch_log_group" "proxy_error" {
  name              = local.log_group_error
  retention_in_days = 3
}

resource "aws_iam_role_policy_attachment" "proxy_cw_agent" {
  role       = aws_iam_role.proxy.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_cloudwatch_log_metric_filter" "http_requests_blocked" {
  name           = "${local.name}-http-requests-blocked"
  log_group_name = aws_cloudwatch_log_group.proxy_policy_denied.name
  pattern        = ""

  metric_transformation {
    name          = "HttpRequestsBlocked"
    namespace     = local.nginx_metric_namespace
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_log_metric_filter" "proxy_errors" {
  name           = "${local.name}-proxy-errors"
  log_group_name = aws_cloudwatch_log_group.proxy_error.name
  pattern        = "\"[error]\""

  metric_transformation {
    name          = "ProxyErrors"
    namespace     = local.nginx_metric_namespace
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
          title  = "Async SNI Spoofing Signals"
          region = var.aws_region
          view   = "timeSeries"
          period = local.dashboard_period
          metrics = [
            [local.sni_spoofing_detector_metric_namespace, local.sni_spoofing_detector_metric_name, { label = "Suspected spoofing", stat = "Sum" }],
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
          title  = "Proxy Log-Derived Signals"
          region = var.aws_region
          view   = "timeSeries"
          period = local.dashboard_period
          metrics = [
            [local.nginx_metric_namespace, "HttpRequestsBlocked", { label = "HTTP prototype blocked", stat = "Sum" }],
            [".", "ProxyErrors", { label = "nginx errors", stat = "Sum" }],
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
          title  = "Host Saturation"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          metrics = [
            [local.nginx_metric_namespace, "CPUUtilization", "InstanceId", aws_instance.proxy.id, { label = "CPU", stat = "Average" }],
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
        x      = 0
        y      = 6
        width  = 8
        height = 6
        properties = {
          title  = "Network Throughput"
          region = var.aws_region
          view   = "timeSeries"
          period = 300
          metrics = [
            ["AWS/EC2", "NetworkIn", "InstanceId", aws_instance.proxy.id, { label = "NetworkIn", stat = "Sum" }],
            [".", "NetworkOut", ".", ".", { label = "NetworkOut", stat = "Sum" }],
          ]
        }
      },
      {
        type   = "log"
        x      = 8
        y      = 6
        width  = 8
        height = 6
        properties = {
          title  = "Recent Override Observations"
          region = var.aws_region
          query  = "SOURCE '${aws_cloudwatch_log_group.proxy_override_observations.name}' | fields @timestamp, sni, original_destination_ip, upstream_host_used, @logStream | sort @timestamp desc | limit 20"
          view   = "table"
        }
      },
      {
        type   = "log"
        x      = 16
        y      = 6
        width  = 8
        height = 6
        properties = {
          title  = "Recent Detector Alerts"
          region = var.aws_region
          query  = "SOURCE '${aws_cloudwatch_log_group.sni_spoofing_detector.name}' | fields @timestamp, event, sni, original_destination_ip, resolved_ips, proxy_instance_id | filter event = \"suspected_sni_spoofing\" | sort @timestamp desc | limit 20"
          view   = "table"
        }
      },
    ]
  })
}

output "proxy_dashboard_url" {
  description = "CloudWatch dashboard URL for proxy observability"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.proxy.dashboard_name}"
}
