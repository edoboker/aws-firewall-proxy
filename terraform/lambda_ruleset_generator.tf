# Lambda ruleset generator MVP.
#
# The main Terraform state owns the parallel ruleset-generator Lambda, managed
# prefix lists, and a separate AWS Network Firewall stateful rule group. The
# rule group remains behaviorally isolated from the normal SNI/FQDN rule group,
# but both are attached by the same firewall policy when the feature is enabled.

locals {
  lambda_ip_fallback_enabled = var.enable_lambda_ip_fallback ? 1 : 0
  lambda_ip_fallback_fqdns = [
    for fqdn in var.lambda_ip_fallback_fqdns :
    trimsuffix(lower(fqdn), ".")
  ]
  lambda_ip_fallback_required_entries = length(local.lambda_ip_fallback_fqdns) * var.lambda_ip_fallback_max_addresses_per_fqdn
  lambda_ip_fallback_prefix_list_count = var.enable_lambda_ip_fallback ? max(1, ceil(local.lambda_ip_fallback_required_entries / var.lambda_ip_fallback_prefix_list_max_entries)) : 0
  lambda_ip_fallback_source_cidrs      = [var.proxy_subnet_cidr, var.direct_workload_subnet_cidr]
  lambda_ip_fallback_rules = flatten([
    for source_idx, source_cidr in local.lambda_ip_fallback_source_cidrs : [
      for prefix_idx in range(local.lambda_ip_fallback_prefix_list_count) :
      "pass tls ${source_cidr} any -> @LAMBDA_IP_FALLBACK_TARGETS_${prefix_idx} 443 (flow:to_server; msg:\"allow TLS from ${source_cidr} to Lambda IP fallback targets ${prefix_idx + 1}\"; sid:${7000 + (source_idx * 100) + prefix_idx}; rev:1;)"
    ]
  ])
}

data "archive_file" "lambda_ip_fallback" {
  count       = local.lambda_ip_fallback_enabled
  type        = "zip"
  source_file = "${path.module}/../lambda/ruleset_generator/handler.py"
  output_path = "${path.module}/.terraform/lambda-ruleset-generator.zip"
}

resource "aws_cloudwatch_log_group" "lambda_ip_fallback" {
  count             = local.lambda_ip_fallback_enabled
  name              = "/aws/lambda/${local.name}-ruleset-generator"
  retention_in_days = 7
}

resource "aws_ec2_managed_prefix_list" "lambda_ip_fallback" {
  count          = local.lambda_ip_fallback_prefix_list_count
  name           = count.index == 0 ? "${local.name}-ruleset-generator" : "${local.name}-ruleset-generator-${count.index + 1}"
  address_family = "IPv4"
  max_entries    = var.lambda_ip_fallback_prefix_list_max_entries

  tags = {
    Name = count.index == 0 ? "${local.name}-ruleset-generator" : "${local.name}-ruleset-generator-${count.index + 1}"
  }
}

data "aws_iam_policy_document" "lambda_ip_fallback_assume" {
  count = local.lambda_ip_fallback_enabled

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_ip_fallback" {
  count              = local.lambda_ip_fallback_enabled
  name               = "${local.name}-ruleset-generator"
  assume_role_policy = data.aws_iam_policy_document.lambda_ip_fallback_assume[0].json
}

data "aws_iam_policy_document" "lambda_ip_fallback" {
  count = local.lambda_ip_fallback_enabled

  statement {
    sid = "WriteLambdaLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.lambda_ip_fallback[0].arn}:*"]
  }

  statement {
    sid = "ReadAndUpdateRulesetGeneratorPrefixList"
    actions = [
      "ec2:DescribeManagedPrefixLists",
      "ec2:GetManagedPrefixListEntries",
      "ec2:ModifyManagedPrefixList",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "lambda_ip_fallback" {
  count  = local.lambda_ip_fallback_enabled
  name   = "${local.name}-ruleset-generator"
  role   = aws_iam_role.lambda_ip_fallback[0].id
  policy = data.aws_iam_policy_document.lambda_ip_fallback[0].json
}

resource "aws_lambda_function" "lambda_ip_fallback" {
  count            = local.lambda_ip_fallback_enabled
  function_name    = "${local.name}-ruleset-generator"
  role             = aws_iam_role.lambda_ip_fallback[0].arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_ip_fallback[0].output_path
  source_code_hash = data.archive_file.lambda_ip_fallback[0].output_base64sha256
  timeout          = var.lambda_ip_fallback_timeout_seconds

  environment {
    variables = {
      FQDNS                  = jsonencode(local.lambda_ip_fallback_fqdns)
      MAX_ADDRESSES_PER_FQDN = tostring(var.lambda_ip_fallback_max_addresses_per_fqdn)
      PREFIX_LIST_ID         = aws_ec2_managed_prefix_list.lambda_ip_fallback[0].id
      PREFIX_LIST_IDS        = jsonencode(aws_ec2_managed_prefix_list.lambda_ip_fallback[*].id)
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda_ip_fallback,
    aws_iam_role_policy.lambda_ip_fallback,
  ]
}

resource "aws_cloudwatch_event_rule" "lambda_ip_fallback" {
  count               = var.enable_lambda_ip_fallback && var.enable_lambda_ip_fallback_schedule ? 1 : 0
  name                = "${local.name}-ruleset-generator"
  description         = "Scheduled refresh for the parallel ruleset-generator prefix lists"
  schedule_expression = var.lambda_ip_fallback_schedule_expression
}

resource "aws_cloudwatch_event_target" "lambda_ip_fallback" {
  count     = var.enable_lambda_ip_fallback && var.enable_lambda_ip_fallback_schedule ? 1 : 0
  rule      = aws_cloudwatch_event_rule.lambda_ip_fallback[0].name
  target_id = "ruleset-generator"
  arn       = aws_lambda_function.lambda_ip_fallback[0].arn
}

resource "aws_lambda_permission" "lambda_ip_fallback_events" {
  count         = var.enable_lambda_ip_fallback && var.enable_lambda_ip_fallback_schedule ? 1 : 0
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_ip_fallback[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.lambda_ip_fallback[0].arn
}

resource "aws_networkfirewall_rule_group" "lambda_ip_fallback" {
  count    = local.lambda_ip_fallback_enabled
  name     = "${local.name}-ruleset-generator"
  type     = "STATEFUL"
  capacity = max(100, length(local.lambda_ip_fallback_rules) * 5)

  rule_group {
    rules_source {
      rules_string = join("\n", local.lambda_ip_fallback_rules)
    }

    reference_sets {
      dynamic "ip_set_references" {
        for_each = range(local.lambda_ip_fallback_prefix_list_count)

        content {
          key = "LAMBDA_IP_FALLBACK_TARGETS_${ip_set_references.value}"
          ip_set_reference {
            reference_arn = aws_ec2_managed_prefix_list.lambda_ip_fallback[ip_set_references.value].arn
          }
        }
      }
    }

    stateful_rule_options {
      rule_order = "STRICT_ORDER"
    }
  }
}
