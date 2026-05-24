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

# ── nginx Proxy — EC2 with OpenResty, the original-dst module, and Lua guard ─

resource "aws_security_group" "proxy" {
  name        = "${local.name}-nginx-sg"
  description = "Proxy EC2 - nginx transparent proxy"
  vpc_id      = aws_vpc.main.id

  # SG is evaluated before iptables REDIRECT, so allow TCP 443 (not 8443) from workload
  ingress {
    description = "TLS from workload subnet"
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
  ami                         = data.aws_ami.nginx_proxy.id
  instance_type               = var.proxy_instance_type
  subnet_id                   = aws_subnet.proxy.id
  vpc_security_group_ids      = [aws_security_group.proxy.id]
  iam_instance_profile        = aws_iam_instance_profile.proxy.name
  source_dest_check           = false
  associate_public_ip_address = false

  # AMI bakes in OpenResty, the original-dst module, Lua policy, the AppConfig
  # Agent, and the runtime policy sync service.
  # User_data injects the env-specific AppConfig coordinates plus local runtime
  # env vars, then starts the agent and sync before nginx. We intentionally
  # keep the metrics publish interval out of AppConfig in this MVP so telemetry
  # cadence changes do not also imply hot-reloading the CloudWatch agent path.
  user_data_base64 = base64encode(<<-EOF
    #!/bin/bash
    set -e
    cat > /etc/sysconfig/aws-firewall-proxy-runtime <<CONF
    PROXY_DEBUG=0
    METRICS_PUBLISH_INTERVAL_SECONDS=${var.proxy_metrics_publish_interval_seconds}
    CONF
    cat > /etc/sysconfig/aws-appconfig-agent <<CONF
    SERVICE_REGION=${var.aws_region}
    PREFETCH_LIST=${aws_appconfig_application.proxy.name}:${aws_appconfig_environment.proxy.name}:${aws_appconfig_configuration_profile.proxy_runtime_policy.name}
    CONF
    cat > /etc/sysconfig/proxy-runtime-sync <<CONF
    APPCONFIG_APPLICATION=${aws_appconfig_application.proxy.name}
    APPCONFIG_ENVIRONMENT=${aws_appconfig_environment.proxy.name}
    APPCONFIG_CONFIGURATION_PROFILE=${aws_appconfig_configuration_profile.proxy_runtime_policy.name}
    APPCONFIG_AGENT_HOST=localhost
    APPCONFIG_AGENT_PORT=2772
    CONF
    systemctl restart render-cloudwatch-agent-config.service
    systemctl start aws-appconfig-agent
    systemctl restart amazon-cloudwatch-agent
    systemctl start refresh-proxy-runtime-policy.service
    systemctl start nginx
  EOF
  )

  tags = { Name = "${local.name}-nginx-proxy-ec2" }
}
