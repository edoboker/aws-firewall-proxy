# Lambda ruleset generator MVP.
#
# The main Terraform state owns the parallel ruleset-generator Lambda, managed
# prefix lists, and a separate AWS Network Firewall stateful rule group. The
# rule group remains behaviorally isolated from the normal SNI/FQDN rule group,
# but both are attached by the same firewall policy when the feature is enabled.

locals {
  ruleset_generator_enabled = var.enable_ruleset_generator ? 1 : 0
  ruleset_generator_fqdns = [
    for fqdn in var.ruleset_generator_fqdns :
    trimsuffix(lower(fqdn), ".")
  ]
  ruleset_generator_allowed_fqdns = [
    for fqdn in var.allowed_fqdns :
    trimsuffix(lower(fqdn), ".")
  ]
  ruleset_generator_fqdn_allowlist_overlap = setintersection(
    toset(local.ruleset_generator_fqdns),
    toset(local.ruleset_generator_allowed_fqdns)
  )
  ruleset_generator_ip_set_keys = {
    for idx, fqdn in local.ruleset_generator_fqdns :
    fqdn => "RG_${idx}"
  }
  ruleset_generator_source_cidrs = [var.proxy_subnet_cidr, var.direct_workload_subnet_cidr]
  ruleset_generator_rules = flatten([
    for source_idx, source_cidr in local.ruleset_generator_source_cidrs : [
      for fqdn_idx, fqdn in local.ruleset_generator_fqdns :
      "pass tls ${source_cidr} any -> @${local.ruleset_generator_ip_set_keys[fqdn]} 443 (flow:to_server, established; ssl_state:client_hello; tls.sni; content:\"${fqdn}\"; startswith; endswith; nocase; msg:\"allow exact SNI ${fqdn} from ${source_cidr} to generated IPs\"; sid:${7000 + (source_idx * 1000) + fqdn_idx}; rev:1;)"
    ]
  ])
}

data "archive_file" "ruleset_generator" {
  count       = local.ruleset_generator_enabled
  type        = "zip"
  source_file = "${path.module}/../lambda/ruleset_generator/handler.py"
  output_path = "${path.module}/.terraform/lambda-ruleset-generator.zip"
}

resource "aws_cloudwatch_log_group" "ruleset_generator" {
  count             = local.ruleset_generator_enabled
  name              = "/aws/lambda/${local.name}-ruleset-generator"
  retention_in_days = 7
}

resource "aws_ec2_managed_prefix_list" "ruleset_generator" {
  for_each       = var.enable_ruleset_generator ? toset(local.ruleset_generator_fqdns) : toset([])
  name           = "${local.name}-ruleset-generator-${replace(each.value, ".", "-")}"
  address_family = "IPv4"
  max_entries    = var.ruleset_generator_max_addresses_per_fqdn

  tags = {
    Name = "${local.name}-ruleset-generator-${replace(each.value, ".", "-")}"
    FQDN = each.value
  }
}

data "aws_iam_policy_document" "ruleset_generator_assume" {
  count = local.ruleset_generator_enabled

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ruleset_generator" {
  count              = local.ruleset_generator_enabled
  name               = "${local.name}-ruleset-generator"
  assume_role_policy = data.aws_iam_policy_document.ruleset_generator_assume[0].json
}

data "aws_iam_policy_document" "ruleset_generator" {
  count = local.ruleset_generator_enabled

  statement {
    sid = "WriteLambdaLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.ruleset_generator[0].arn}:*"]
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

resource "aws_iam_role_policy" "ruleset_generator" {
  count  = local.ruleset_generator_enabled
  name   = "${local.name}-ruleset-generator"
  role   = aws_iam_role.ruleset_generator[0].id
  policy = data.aws_iam_policy_document.ruleset_generator[0].json
}

resource "aws_lambda_function" "ruleset_generator" {
  count            = local.ruleset_generator_enabled
  function_name    = "${local.name}-ruleset-generator"
  role             = aws_iam_role.ruleset_generator[0].arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.ruleset_generator[0].output_path
  source_code_hash = data.archive_file.ruleset_generator[0].output_base64sha256
  timeout          = var.ruleset_generator_timeout_seconds

  environment {
    variables = {
      FQDNS                  = jsonencode(local.ruleset_generator_fqdns)
      FQDN_PREFIX_LIST_IDS   = jsonencode({ for fqdn, prefix_list in aws_ec2_managed_prefix_list.ruleset_generator : fqdn => prefix_list.id })
      MAX_ADDRESSES_PER_FQDN = tostring(var.ruleset_generator_max_addresses_per_fqdn)
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.ruleset_generator,
    aws_iam_role_policy.ruleset_generator,
  ]
}

resource "aws_cloudwatch_event_rule" "ruleset_generator" {
  count               = var.enable_ruleset_generator && var.enable_ruleset_generator_schedule ? 1 : 0
  name                = "${local.name}-ruleset-generator"
  description         = "Scheduled refresh for the parallel ruleset-generator prefix lists"
  schedule_expression = var.ruleset_generator_schedule_expression
}

resource "aws_cloudwatch_event_target" "ruleset_generator" {
  count     = var.enable_ruleset_generator && var.enable_ruleset_generator_schedule ? 1 : 0
  rule      = aws_cloudwatch_event_rule.ruleset_generator[0].name
  target_id = "ruleset-generator"
  arn       = aws_lambda_function.ruleset_generator[0].arn
}

resource "aws_lambda_permission" "ruleset_generator_events" {
  count         = var.enable_ruleset_generator && var.enable_ruleset_generator_schedule ? 1 : 0
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ruleset_generator[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ruleset_generator[0].arn
}

resource "aws_networkfirewall_rule_group" "ruleset_generator" {
  count    = local.ruleset_generator_enabled
  name     = "${local.name}-ruleset-generator"
  type     = "STATEFUL"
  capacity = max(100, length(local.ruleset_generator_rules) * 5)

  lifecycle {
    precondition {
      condition     = length(local.ruleset_generator_fqdn_allowlist_overlap) == 0
      error_message = "ruleset_generator_fqdns must not overlap allowed_fqdns. The broad SNI-only allowlist would bypass generated SNI+IP binding."
    }
  }

  rule_group {
    rules_source {
      rules_string = join("\n", local.ruleset_generator_rules)
    }

    reference_sets {
      dynamic "ip_set_references" {
        for_each = aws_ec2_managed_prefix_list.ruleset_generator

        content {
          key = local.ruleset_generator_ip_set_keys[ip_set_references.key]
          ip_set_reference {
            reference_arn = ip_set_references.value.arn
          }
        }
      }
    }

    stateful_rule_options {
      rule_order = "STRICT_ORDER"
    }
  }
}
