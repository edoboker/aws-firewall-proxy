# ── EC2 Instance Connect Endpoint (shared — grants SSH to proxy and workload) ─

resource "aws_security_group" "eic_endpoint" {
  name        = "${local.name}-eic-sg"
  description = "EC2 Instance Connect Endpoint - outbound SSH to proxy"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "SSH to proxy EC2"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.proxy_subnet_cidr]
  }

  egress {
    description = "SSH to workload EC2"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.workload_subnet_cidr]
  }
}

resource "aws_ec2_instance_connect_endpoint" "proxy" {
  subnet_id          = aws_subnet.proxy.id
  security_group_ids = [aws_security_group.eic_endpoint.id]
  preserve_client_ip = false

  tags = { Name = "${local.name}-eic-endpoint" }
}

# ── nginx Proxy — EC2 with nginx stream module on host ────────────────────────

resource "aws_security_group" "proxy" {
  name        = "${local.name}-nginx-sg"
  description = "Proxy EC2 - nginx transparent proxy"
  vpc_id      = aws_vpc.main.id

  # SG is evaluated before iptables REDIRECT, so allow TCP 443 (not 8443) from workload
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.workload_subnet_cidr]
  }

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

resource "aws_instance" "proxy" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.proxy_instance_type
  subnet_id              = aws_subnet.proxy.id
  vpc_security_group_ids = [aws_security_group.proxy.id]
  source_dest_check              = false
  associate_public_ip_address    = false

  user_data_base64 = base64encode(<<-EOF
    #!/bin/bash
    set -e

    # IP forwarding required for transparent proxy
    echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.d/99-proxy.conf
    sysctl -p /etc/sysctl.d/99-proxy.conf

    # Install nginx + stream module (separate package on AL2023)
    dnf install -y nginx nginx-mod-stream iptables-services

    # Write nginx config
    cat > /etc/nginx/nginx.conf << 'NGINXCONF'
${file("${path.module}/configs/nginx.conf")}
NGINXCONF

    # iptables: redirect inbound TCP:443 to nginx
    iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8443

    systemctl enable nginx
    systemctl start nginx
  EOF
  )

  tags = { Name = "${local.name}-nginx-proxy-ec2" }
}
