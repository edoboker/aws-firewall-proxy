# Shared-DNS T3: VPC peering between the workload VPC and the DNS VPC.
#
resource "aws_vpc_peering_connection" "workload_dns" {
  count       = local.dns_enabled
  vpc_id      = aws_vpc.main.id
  peer_vpc_id = aws_vpc.dns[0].id

  tags = { Name = "${local.name}-workload-dns-peering" }
}

resource "aws_vpc_peering_connection_accepter" "workload_dns" {
  count                     = local.dns_enabled
  vpc_peering_connection_id = aws_vpc_peering_connection.workload_dns[0].id
  auto_accept               = true

  accepter {
    allow_remote_vpc_dns_resolution = false
  }

  requester {
    allow_remote_vpc_dns_resolution = false
  }

  tags = { Name = "${local.name}-workload-dns-peering" }
}
