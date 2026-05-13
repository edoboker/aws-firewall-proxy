# ── AWS Network Firewall ──────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "anf_alert" {
  name              = "/aws/network-firewall/${local.name}/alert"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "anf_flow" {
  name              = "/aws/network-firewall/${local.name}/flow"
  retention_in_days = 7
}

locals {
  # dotprefix prepends "." to the SNI buffer before matching, so:
  #   content:".google.com"; endswith  matches google.com and *.google.com
  #   but NOT evilgoogle.com (becomes .evilgoogle.com, no suffix match)
  fqdn_rules = join("\n", [
    for idx, fqdn in var.allowed_fqdns :
    "pass tls ${var.vpc_cidr} any -> $EXTERNAL_NET 443 (tls.sni; dotprefix; content:\".${fqdn}\"; endswith; nocase; msg:\"allow ${fqdn}\"; sid:${1000 + idx}; rev:1;)"
  ])
}

resource "aws_networkfirewall_rule_group" "fqdn_allowlist" {
  name     = "${local.name}-fqdn-allowlist"
  type     = "STATEFUL"
  capacity = 100

  rule_group {
    rules_source {
      rules_string = local.fqdn_rules
    }

    stateful_rule_options {
      rule_order = "STRICT_ORDER"
    }
  }
}

resource "aws_networkfirewall_firewall_policy" "main" {
  name = "${local.name}-policy"

  firewall_policy {
    stateless_default_actions          = ["aws:forward_to_sfe"]
    stateless_fragment_default_actions = ["aws:forward_to_sfe"]

    stateful_engine_options {
      rule_order = "STRICT_ORDER"
    }

    stateful_rule_group_reference {
      resource_arn = aws_networkfirewall_rule_group.fqdn_allowlist.arn
      priority     = 1
    }

    stateful_default_actions = ["aws:drop_established"]
  }
}

resource "aws_networkfirewall_firewall" "main" {
  name                = "${local.name}-anf"
  vpc_id              = aws_vpc.main.id
  firewall_policy_arn = aws_networkfirewall_firewall_policy.main.arn

  subnet_mapping {
    subnet_id = aws_subnet.firewall.id
  }
}

resource "aws_networkfirewall_logging_configuration" "main" {
  firewall_arn = aws_networkfirewall_firewall.main.arn

  logging_configuration {
    log_destination_config {
      log_type             = "ALERT"
      log_destination_type = "CloudWatchLogs"
      log_destination      = { logGroup = aws_cloudwatch_log_group.anf_alert.name }
    }

    log_destination_config {
      log_type             = "FLOW"
      log_destination_type = "CloudWatchLogs"
      log_destination      = { logGroup = aws_cloudwatch_log_group.anf_flow.name }
    }
  }
}

locals {
  # Extract the ANF endpoint ID for the single AZ deployment
  anf_endpoint_id = [
    for ss in aws_networkfirewall_firewall.main.firewall_status[0].sync_states :
    ss.attachment[0].endpoint_id
    if ss.availability_zone == var.availability_zone
  ][0]
}
