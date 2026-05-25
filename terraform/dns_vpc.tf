# ── Shared-DNS: dedicated DNS VPC ─────────────────────────────────────────────
# Hosts the BIND9 recursive resolver that the workload and proxy will share
# (see docs/shared-dns-cache.md). It lives in its own VPC, not the workload VPC,
# because the Route 53 Resolver forwarding rule added in T3/T4 is VPC-scoped and
# would otherwise capture BIND9's own upstream queries and loop them back to it.
#
# No IGW / NAT / public subnet: BIND9 does not recurse to the internet itself.
# It forwards cache-misses to this VPC's Route 53 Resolver (169.254.169.253),
# which is VPC infrastructure reachable without any internet gateway and does the
# actual recursion. (Requires T1's named.conf to use that forwarder.)
#
# The whole stack is gated by var.enable_shared_dns (default false) so the
# existing single-VPC deployment is unaffected until the feature is switched on.

locals {
  dns_enabled = var.enable_shared_dns ? 1 : 0
}

resource "aws_vpc" "dns" {
  count                = local.dns_enabled
  cidr_block           = var.dns_vpc_cidr
  enable_dns_support   = true # serves the .2 / 169.254.169.253 resolver BIND forwards to
  enable_dns_hostnames = true
  tags                 = { Name = "${local.name}-dns-vpc" }
}

# Private subnet for BIND9 — no public IP. Reached from the workload VPC over VPC
# peering (added in T3).
resource "aws_subnet" "dns_private" {
  count             = local.dns_enabled
  vpc_id            = aws_vpc.dns[0].id
  cidr_block        = var.dns_private_subnet_cidr
  availability_zone = var.availability_zone
  tags              = { Name = "${local.name}-dns-private" }
}

# Dedicated route table (local routes only for now). T3 adds the route back to
# the workload VPC over VPC peering here.
resource "aws_route_table" "dns_private" {
  count  = local.dns_enabled
  vpc_id = aws_vpc.dns[0].id
  tags   = { Name = "${local.name}-dns-private-rt" }
}

resource "aws_route_table_association" "dns_private" {
  count          = local.dns_enabled
  subnet_id      = aws_subnet.dns_private[0].id
  route_table_id = aws_route_table.dns_private[0].id
}
