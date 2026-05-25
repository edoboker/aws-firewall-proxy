# ── Route Tables ──────────────────────────────────────────────────────────────

# RT-1: Workload → proxy ENI (transparent proxy intercepts all egress)
resource "aws_route_table" "workload" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-workload-rt" }
}

resource "aws_route" "workload_to_proxy" {
  route_table_id         = aws_route_table.workload.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.proxy.primary_network_interface_id
}

resource "aws_route_table_association" "workload" {
  subnet_id      = aws_subnet.workload.id
  route_table_id = aws_route_table.workload.id
}

resource "aws_route" "workload_to_dns_vpc" {
  count                     = local.dns_enabled
  route_table_id            = aws_route_table.workload.id
  destination_cidr_block    = var.dns_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.workload_dns[0].id

  depends_on = [aws_vpc_peering_connection_accepter.workload_dns]
}

# RT-2: Proxy → ANF endpoint (ANF applies FQDN allowlist to all traffic)
resource "aws_route_table" "proxy" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-proxy-rt" }
}

resource "aws_route" "proxy_to_firewall" {
  route_table_id         = aws_route_table.proxy.id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = local.anf_endpoint_id
}

resource "aws_route_table_association" "proxy" {
  subnet_id      = aws_subnet.proxy.id
  route_table_id = aws_route_table.proxy.id
}

resource "aws_route" "proxy_to_dns_vpc" {
  count                     = local.dns_enabled
  route_table_id            = aws_route_table.proxy.id
  destination_cidr_block    = var.dns_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.workload_dns[0].id

  depends_on = [aws_vpc_peering_connection_accepter.workload_dns]
}

# RT-3: Firewall subnet → NAT GW
# After ANF inspects traffic, it forwards via this RT. NAT GW translates
# the private source IP before sending to the internet.
resource "aws_route_table" "firewall" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-firewall-rt" }
}

resource "aws_route" "firewall_to_nat" {
  route_table_id         = aws_route_table.firewall.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}

resource "aws_route_table_association" "firewall" {
  subnet_id      = aws_subnet.firewall.id
  route_table_id = aws_route_table.firewall.id
}

# RT-4: Public subnet → IGW (NAT GW egress)
# Return traffic destined for workload/proxy subnets is steered back through ANF
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-public-rt" }
}

resource "aws_route" "public_to_igw" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route" "public_return_workload" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = var.workload_subnet_cidr
  vpc_endpoint_id        = local.anf_endpoint_id
}

resource "aws_route" "public_return_proxy" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = var.proxy_subnet_cidr
  vpc_endpoint_id        = local.anf_endpoint_id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route" "dns_to_workload_vpc" {
  count                     = local.dns_enabled
  route_table_id            = aws_route_table.dns_private[0].id
  destination_cidr_block    = var.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.workload_dns[0].id

  depends_on = [aws_vpc_peering_connection_accepter.workload_dns]
}
