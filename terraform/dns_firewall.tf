# ── Route 53 Resolver DNS Firewall ────────────────────────────────────────────
# Restricts DNS resolution from this VPC to only the allowed FQDNs.
# This complements the network firewall by preventing DNS queries for
# unauthorized domains before any traffic is generated.

resource "aws_route53_resolver_firewall_domain_list" "allowed" {
  name    = "${local.name}-dns-allowed"
  domains = [for fqdn in var.allowed_fqdns : "*.${fqdn}"]
}

resource "aws_route53_resolver_firewall_domain_list" "allowed_exact" {
  name    = "${local.name}-dns-allowed-exact"
  domains = var.allowed_fqdns
}

resource "aws_route53_resolver_firewall_domain_list" "block_all" {
  name    = "${local.name}-dns-block-all"
  domains = ["*"]
}

resource "aws_route53_resolver_firewall_rule_group" "main" {
  name = "${local.name}-dns-firewall"
}

resource "aws_route53_resolver_firewall_rule" "allow_subdomains" {
  name                    = "allow-subdomains"
  action                  = "ALLOW"
  firewall_domain_list_id = aws_route53_resolver_firewall_domain_list.allowed.id
  firewall_rule_group_id  = aws_route53_resolver_firewall_rule_group.main.id
  priority                = 100
}

resource "aws_route53_resolver_firewall_rule" "allow_exact" {
  name                    = "allow-exact"
  action                  = "ALLOW"
  firewall_domain_list_id = aws_route53_resolver_firewall_domain_list.allowed_exact.id
  firewall_rule_group_id  = aws_route53_resolver_firewall_rule_group.main.id
  priority                = 200
}

resource "aws_route53_resolver_firewall_rule" "block_all" {
  name                    = "block-all"
  action                  = "BLOCK"
  block_response          = "NXDOMAIN"
  firewall_domain_list_id = aws_route53_resolver_firewall_domain_list.block_all.id
  firewall_rule_group_id  = aws_route53_resolver_firewall_rule_group.main.id
  priority                = 300
}

resource "aws_route53_resolver_firewall_rule_group_association" "main" {
  name                   = "${local.name}-dns-firewall"
  firewall_rule_group_id = aws_route53_resolver_firewall_rule_group.main.id
  vpc_id                 = aws_vpc.main.id
  priority               = 101
}
