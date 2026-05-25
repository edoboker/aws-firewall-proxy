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
  lambda_ip_fallback_rule_group_arns = var.enable_lambda_ip_fallback ? [aws_networkfirewall_rule_group.lambda_ip_fallback[0].arn] : []

  public_dns_rules = join("\n", flatten([
    for idx, resolver in var.proxy_public_dns_resolvers : [
      "pass udp ${var.proxy_subnet_cidr} any -> ${resolver} 53 (msg:\"allow proxy DNS UDP to ${resolver}\"; sid:${9000 + (idx * 2)}; rev:1;)",
      "pass tcp ${var.proxy_subnet_cidr} any -> ${resolver} 53 (msg:\"allow proxy DNS TCP to ${resolver}\"; sid:${9001 + (idx * 2)}; rev:1;)"
    ]
  ]))

  # dotprefix prepends "." to the SNI buffer before matching, so:
  #   content:".google.com"; endswith  matches google.com and *.google.com
  #   but NOT evilgoogle.com (becomes .evilgoogle.com, no suffix match)
  fqdn_rules = join("\n", [
    for idx, fqdn in var.allowed_fqdns :
    "pass tls ${var.vpc_cidr} any -> $EXTERNAL_NET 443 (tls.sni; dotprefix; content:\".${fqdn}\"; endswith; nocase; msg:\"allow ${fqdn}\"; sid:${1000 + idx}; rev:1;)"
  ])

  # Experimental HTTP cleartext path for the prototype HTTP Host/original-dst
  # guard. The proxy preserves the Host header while forwarding to the resolved
  # IP, so ANF can still enforce the same domain suffix allowlist on port 80.
  http_fqdn_rules = join("\n", [
    for idx, fqdn in var.allowed_fqdns :
    "pass http ${var.vpc_cidr} any -> $EXTERNAL_NET 80 (http.host; dotprefix; content:\".${fqdn}\"; endswith; nocase; msg:\"allow http ${fqdn}\"; sid:${2000 + idx}; rev:1;)"
  ])

  # Close the off-path resolver side channels (docs/shared-dns-cache.md §5.1,
  # docs/bypass-vectors.md "block, not bypass"): drop DNS-over-TLS (TCP/853) and
  # DNS-over-QUIC (UDP/853) so the workload cannot resolve names without traversing
  # .2 → the Resolver forwarding rule → BIND9. Port-based drops (not the `tls`
  # keyword) so the block does not depend on TLS-handshake detection. Clients fall
  # back to Do53, which the egress path controls. DoH (HTTPS/443) is not a separate
  # rule — it is contained by the SNI allowlist + drop_no_sni path (§5.1). `drop`
  # actions also surface in the ANF alert log, giving visibility into attempts.
  off_path_resolver_rules = join("\n", [
    "drop tcp ${var.vpc_cidr} any -> $EXTERNAL_NET 853 (msg:\"drop DoT off-path resolver (TCP/853)\"; sid:8000; rev:1;)",
    "drop udp ${var.vpc_cidr} any -> $EXTERNAL_NET 853 (msg:\"drop DoQ off-path resolver (UDP/853)\"; sid:8001; rev:1;)"
  ])

  stateful_rules = join("\n", compact([
    local.public_dns_rules,
    local.fqdn_rules,
    local.http_fqdn_rules,
    local.off_path_resolver_rules
  ]))

  # Extract the ANF endpoint ID for the single AZ deployment
  anf_endpoint_id = [
    for ss in aws_networkfirewall_firewall.main.firewall_status[0].sync_states :
    ss.attachment[0].endpoint_id
    if ss.availability_zone == var.availability_zone
  ][0]
}

resource "aws_networkfirewall_rule_group" "fqdn_allowlist" {
  name     = "${local.name}-fqdn-allowlist"
  type     = "STATEFUL"
  capacity = 100

  rule_group {
    rules_source {
      rules_string = local.stateful_rules
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

    dynamic "stateful_rule_group_reference" {
      for_each = local.lambda_ip_fallback_rule_group_arns

      content {
        resource_arn = stateful_rule_group_reference.value
        priority     = 2
      }
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
