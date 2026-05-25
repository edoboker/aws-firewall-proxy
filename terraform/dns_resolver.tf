# Shared-DNS T4: Route 53 Resolver forwarding path.
#
# Workload/proxy instances keep using the VPC resolver (.2 / 169.254.169.253).
# For forwarded domains, Resolver sends queries through this outbound endpoint to
# the BIND9 cache in the DNS VPC. DNS Firewall remains associated with the
# workload VPC in dns_firewall.tf.

locals {
  shared_dns_forwarded_domains = var.enable_shared_dns ? toset([
    for fqdn in(length(var.forwarded_domains) > 0 ? var.forwarded_domains : var.allowed_fqdns) :
    trimsuffix(lower(fqdn), ".")
  ]) : toset([])
}

resource "aws_security_group" "resolver_outbound" {
  count       = local.dns_enabled
  name        = "${local.name}-resolver-outbound-sg"
  description = "Route 53 Resolver outbound endpoint - DNS to BIND9"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "DNS to BIND9 resolver (UDP)"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [var.dns_private_subnet_cidr]
  }

  egress {
    description = "DNS to BIND9 resolver (TCP)"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = [var.dns_private_subnet_cidr]
  }
}

resource "aws_route53_resolver_endpoint" "shared_dns_outbound" {
  count              = local.dns_enabled
  name               = "${local.name}-shared-dns-outbound"
  direction          = "OUTBOUND"
  security_group_ids = [aws_security_group.resolver_outbound[0].id]

  # Resolver endpoints require at least two IP addresses. This single-AZ demo
  # places them in the workload and proxy subnets; the two-AZ design should move
  # these to per-AZ subnets for real HA.
  ip_address {
    subnet_id = aws_subnet.workload.id
  }

  ip_address {
    subnet_id = aws_subnet.proxy.id
  }

  tags = { Name = "${local.name}-shared-dns-outbound" }
}

resource "aws_route53_resolver_rule" "shared_dns_forward" {
  for_each             = local.shared_dns_forwarded_domains
  name                 = "${local.name}-forward-${replace(each.key, ".", "-")}"
  domain_name          = each.key
  rule_type            = "FORWARD"
  resolver_endpoint_id = aws_route53_resolver_endpoint.shared_dns_outbound[0].id

  target_ip {
    ip   = aws_instance.bind[0].private_ip
    port = 53
  }

  tags = { Name = "${local.name}-forward-${each.key}" }
}

resource "aws_route53_resolver_rule_association" "shared_dns_forward" {
  for_each         = aws_route53_resolver_rule.shared_dns_forward
  name             = "${local.name}-forward-${replace(each.key, ".", "-")}"
  resolver_rule_id = each.value.id
  vpc_id           = aws_vpc.main.id
}
