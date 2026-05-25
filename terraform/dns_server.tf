# ── Shared-DNS: BIND9 recursive resolver ──────────────────────────────────────
# A single EC2 instance running the BIND9 AMI built by packer/bind-dns (T1).
# Gated by var.enable_shared_dns via local.dns_enabled (see dns_vpc.tf).

# EC2 Instance Connect Endpoint — keyless SSH to BIND9 for debugging, matching
# how the proxy/workload are accessed (no SSH keys, no SSM).
resource "aws_security_group" "dns_eic_endpoint" {
  count       = local.dns_enabled
  name        = "${local.name}-dns-eic-sg"
  description = "EC2 Instance Connect Endpoint - outbound SSH to BIND9"
  vpc_id      = aws_vpc.dns[0].id

  egress {
    description = "SSH to BIND9 EC2"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.dns_private_subnet_cidr]
  }
}

resource "aws_ec2_instance_connect_endpoint" "dns" {
  count              = local.dns_enabled
  subnet_id          = aws_subnet.dns_private[0].id
  security_group_ids = [aws_security_group.dns_eic_endpoint[0].id]
  preserve_client_ip = false

  tags = { Name = "${local.name}-dns-eic-endpoint" }
}

resource "aws_security_group" "bind" {
  count       = local.dns_enabled
  name        = "${local.name}-bind-sg"
  description = "BIND9 recursive resolver"
  vpc_id      = aws_vpc.dns[0].id

  # DNS from the workload VPC. The peering path that makes this reachable is
  # added in T3; opening it here is harmless until then.
  ingress {
    description = "DNS (UDP) from workload VPC"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "DNS (TCP) from workload VPC"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description     = "SSH from EC2 Instance Connect Endpoint"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.dns_eic_endpoint[0].id]
  }

  # No internet egress. BIND forwards cache-misses to the VPC Route 53 Resolver
  # at 169.254.169.253 (reachable without IGW/NAT); it does the recursion. T1's
  # named.conf must use this address as its forwarder.
  egress {
    description = "DNS to the VPC Route 53 Resolver (UDP)"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["169.254.169.253/32"]
  }

  egress {
    description = "DNS to the VPC Route 53 Resolver (TCP)"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["169.254.169.253/32"]
  }
}

resource "aws_instance" "bind" {
  count                       = local.dns_enabled
  ami                         = data.aws_ami.bind_dns[0].id
  instance_type               = var.bind_instance_type
  subnet_id                   = aws_subnet.dns_private[0].id
  vpc_security_group_ids      = [aws_security_group.bind[0].id]
  associate_public_ip_address = false

  # The AMI (packer/bind-dns, T1) bakes `named` and a base named.conf. user_data
  # passes only the environment-specific cache-TTL floor; the AMI's startup is
  # expected to read /etc/sysconfig/bind-tuning (MIN_CACHE_TTL). Confirm this key
  # with whoever builds T1 — if the AMI ignores it, named still boots on its
  # baked defaults, so this is a safe coupling.
  user_data_base64 = base64encode(<<-EOF
    #!/bin/bash
    set -e
    cat > /etc/sysconfig/bind-tuning <<CONF
    MIN_CACHE_TTL=${var.bind_min_cache_ttl}
    CONF
    systemctl restart named
  EOF
  )

  tags = { Name = "${local.name}-bind-resolver" }
}
