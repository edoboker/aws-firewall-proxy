# Async SNI-spoofing detector.
#
# The proxy always forwards TLS to the SNI-derived upstream. This Lambda consumes
# observation logs later and emits a best-effort suspicion signal when the
# original destination IP is not in the SNI's current A-record set.

locals {
  log_group_override_observations          = "/aws/firewall-proxy/nginx/override-observations"
  sni_spoofing_detector_function_name      = "${local.name}-sni-spoofing-detector"
  sni_spoofing_detector_metric_namespace   = "AwsFirewallProxy"
  sni_spoofing_detector_metric_name        = "SuspectedSniSpoofing"
  sni_spoofing_detector_dns_resolvers      = "1.1.1.1,8.8.8.8"
  sni_spoofing_detector_alarm_period       = 300
  sni_spoofing_detector_alarm_eval_periods = 1
}

data "aws_caller_identity" "current" {}

data "archive_file" "sni_spoofing_detector" {
  type        = "zip"
  source_file = "${path.module}/../lambda/sni_spoofing_detector/handler.py"
  output_path = "${path.module}/.terraform/sni-spoofing-detector.zip"
}

resource "aws_cloudwatch_log_group" "proxy_override_observations" {
  name              = local.log_group_override_observations
  retention_in_days = 3
}

resource "aws_cloudwatch_log_group" "sni_spoofing_detector" {
  name              = "/aws/lambda/${local.sni_spoofing_detector_function_name}"
  retention_in_days = 7
}

data "aws_iam_policy_document" "sni_spoofing_detector_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sni_spoofing_detector" {
  name               = local.sni_spoofing_detector_function_name
  assume_role_policy = data.aws_iam_policy_document.sni_spoofing_detector_assume.json
}

data "aws_iam_policy_document" "sni_spoofing_detector" {
  statement {
    sid = "WriteLambdaLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.sni_spoofing_detector.arn}:*"]
  }

  statement {
    sid       = "PublishSniSpoofingMetric"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [local.sni_spoofing_detector_metric_namespace]
    }
  }
}

resource "aws_iam_role_policy" "sni_spoofing_detector" {
  name   = local.sni_spoofing_detector_function_name
  role   = aws_iam_role.sni_spoofing_detector.id
  policy = data.aws_iam_policy_document.sni_spoofing_detector.json
}

resource "aws_lambda_function" "sni_spoofing_detector" {
  function_name    = local.sni_spoofing_detector_function_name
  role             = aws_iam_role.sni_spoofing_detector.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.sni_spoofing_detector.output_path
  source_code_hash = data.archive_file.sni_spoofing_detector.output_base64sha256
  timeout          = 20

  environment {
    variables = {
      DNS_RESOLVERS    = local.sni_spoofing_detector_dns_resolvers
      MAX_CNAME_DEPTH  = "5"
      METRIC_NAME      = local.sni_spoofing_detector_metric_name
      METRIC_NAMESPACE = local.sni_spoofing_detector_metric_namespace
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.sni_spoofing_detector,
    aws_iam_role_policy.sni_spoofing_detector,
  ]
}

resource "aws_lambda_permission" "sni_spoofing_detector_logs" {
  statement_id   = "AllowExecutionFromCloudWatchLogs"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.sni_spoofing_detector.function_name
  principal      = "logs.${var.aws_region}.amazonaws.com"
  source_arn     = "${aws_cloudwatch_log_group.proxy_override_observations.arn}:*"
  source_account = data.aws_caller_identity.current.account_id
}

resource "aws_cloudwatch_log_subscription_filter" "sni_spoofing_detector" {
  name            = local.sni_spoofing_detector_function_name
  log_group_name  = aws_cloudwatch_log_group.proxy_override_observations.name
  filter_pattern  = ""
  destination_arn = aws_lambda_function.sni_spoofing_detector.arn

  depends_on = [aws_lambda_permission.sni_spoofing_detector_logs]
}

resource "aws_cloudwatch_metric_alarm" "suspected_sni_spoofing" {
  alarm_name          = "${local.name}-suspected-sni-spoofing"
  alarm_description   = "Async detector found original destination IP outside the SNI's resolved A-record set."
  namespace           = local.sni_spoofing_detector_metric_namespace
  metric_name         = local.sni_spoofing_detector_metric_name
  statistic           = "Sum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  period              = local.sni_spoofing_detector_alarm_period
  evaluation_periods  = local.sni_spoofing_detector_alarm_eval_periods
  treat_missing_data  = "notBreaching"
}
