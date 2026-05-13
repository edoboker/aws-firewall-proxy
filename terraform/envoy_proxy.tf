# ── Envoy Proxy — EC2 in the proxy subnet ────────────────────────────────────
# Alternative proxy implementation using Envoy's SNI dynamic forward proxy.
# To activate, update the workload route table to point to this instance's ENI
# instead of the nginx proxy. Only one proxy should be routed at a time.

resource "aws_security_group" "envoy" {
  name        = "${local.name}-envoy-sg"
  description = "Envoy proxy EC2 - transparent TLS proxy"
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

resource "aws_instance" "envoy" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.envoy_instance_type
  subnet_id              = aws_subnet.proxy.id
  vpc_security_group_ids = [aws_security_group.envoy.id]
  source_dest_check              = false
  associate_public_ip_address    = false

  user_data_base64 = base64encode(<<-EOF
    #!/bin/bash
    set -e

    # IP forwarding required for transparent proxy
    echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.d/99-proxy.conf
    sysctl -p /etc/sysctl.d/99-proxy.conf

    # Install envoy
    dnf install -y curl iptables-services
    ENVOY_VERSION="1.32.2"
    curl -fL -o /usr/local/bin/envoy \
      "https://github.com/envoyproxy/envoy/releases/download/v$${ENVOY_VERSION}/envoy-$${ENVOY_VERSION}-linux-x86_64"
    chmod +x /usr/local/bin/envoy

    mkdir -p /etc/envoy /var/log/envoy

    cat > /etc/envoy/envoy.yaml << 'ENVOYCONF'
${file("${path.module}/configs/envoy.yaml")}
ENVOYCONF

    # Dedicated user for least-privilege service execution
    useradd -r -s /sbin/nologin envoy
    chown -R envoy:envoy /etc/envoy /var/log/envoy

    # systemd service
    cat > /etc/systemd/system/envoy.service << 'SERVICE'
[Unit]
Description=Envoy Proxy
After=network.target

[Service]
User=envoy
ExecStart=/usr/local/bin/envoy -c /etc/envoy/envoy.yaml
Restart=on-failure

[Install]
WantedBy=multi-user.target
SERVICE

    # iptables: redirect inbound TCP:443 to envoy
    # No OUTPUT rule needed — PREROUTING does not affect locally-generated traffic
    iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8443

    systemctl daemon-reload
    systemctl enable envoy
    systemctl start envoy
  EOF
  )

  tags = { Name = "${local.name}-envoy-proxy-ec2" }
}
