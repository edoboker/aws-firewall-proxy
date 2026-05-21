# ── SSM Run Command plumbing (test harness uses this to exec on EC2) ──────────
#
# Adds the managed policy + VPC interface endpoints needed so `aws ssm send-command`
# can target both the workload and the proxy. The data path being tested is
# untouched.

# Proxy already has aws_iam_role.proxy + instance profile in nginx_allowlist.tf.
# Layer the managed policy on top so the agent can register and exec commands.
resource "aws_iam_role_policy_attachment" "proxy_ssm_core" {
  role       = aws_iam_role.proxy.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Workload has no role yet — give it one.
resource "aws_iam_role" "workload" {
  name               = "${local.name}-workload"
  assume_role_policy = data.aws_iam_policy_document.proxy_assume.json
}

resource "aws_iam_role_policy_attachment" "workload_ssm_core" {
  role       = aws_iam_role.workload.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "workload" {
  name = "${local.name}-workload"
  role = aws_iam_role.workload.name
}

# ── Network reachability ──────────────────────────────────────────────────────
#
# Workload's default route is the proxy ENI, and the proxy chain only forwards
# allowlisted FQDNs. SSM endpoints can't go through that path. Add VPC interface
# endpoints in the workload + proxy subnets so the agent reaches the SSM control
# plane without involving ANF.

resource "aws_security_group" "ssm_endpoints" {
  name        = "${local.name}-ssm-endpoints-sg"
  description = "SSM interface endpoints - 443 from workload and proxy subnets"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from workload subnet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.workload_subnet_cidr]
  }

  ingress {
    description = "HTTPS from proxy subnet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.proxy_subnet_cidr]
  }
}

locals {
  ssm_endpoint_services = ["ssm", "ssmmessages", "ec2messages"]
}

resource "aws_vpc_endpoint" "ssm" {
  for_each = toset(local.ssm_endpoint_services)

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.workload.id, aws_subnet.proxy.id]
  security_group_ids  = [aws_security_group.ssm_endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${local.name}-${each.key}-endpoint" }
}
