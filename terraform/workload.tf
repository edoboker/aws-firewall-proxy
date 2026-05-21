# ── Workload ──────────────────────────────────────────────────────────────────

resource "aws_security_group" "workload" {
  name        = "${local.name}-workload-sg"
  description = "Workload client EC2"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "SSH from EC2 Instance Connect Endpoint"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.eic_endpoint.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "workload" {
  ami                         = data.aws_ssm_parameter.al2023_ami.value
  instance_type               = var.workload_instance_type
  subnet_id                   = aws_subnet.workload.id
  vpc_security_group_ids      = [aws_security_group.workload.id]
  iam_instance_profile        = aws_iam_instance_profile.workload.name
  associate_public_ip_address = false
  tags                        = { Name = "${local.name}-workload" }
}
