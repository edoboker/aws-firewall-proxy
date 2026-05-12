locals {
  name = "${var.environment}-proxy"
}

# ── Data Sources ──────────────────────────────────────────────────────────────

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}


data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# ── VPC ───────────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.name}-vpc" }
}

resource "aws_subnet" "workload" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.workload_subnet_cidr
  availability_zone = var.availability_zone
  tags              = { Name = "${local.name}-workload" }
}

resource "aws_subnet" "proxy" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.proxy_subnet_cidr
  availability_zone = var.availability_zone
  tags              = { Name = "${local.name}-proxy" }
}

# Firewall subnet: ANF endpoint lives here.
# RT routes to NAT GW so that ANF-forwarded traffic (with private source IPs)
# can reach the internet via NAT — not directly via IGW.
resource "aws_subnet" "firewall" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.firewall_subnet_cidr
  availability_zone = var.availability_zone
  tags              = { Name = "${local.name}-firewall" }
}

# Public subnet: NAT GW only.
# RT routes to IGW so NAT GW can reach the internet.
resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidr
  availability_zone = var.availability_zone
  tags              = { Name = "${local.name}-public" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-igw" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${local.name}-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags          = { Name = "${local.name}-nat" }
  depends_on    = [aws_internet_gateway.main]
}

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

# RT-2: Proxy → ANF endpoint (firewall stays in path; proxy subnet has a pass-all ANF rule)
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

# RT-3: Firewall subnet → NAT GW
# After ANF inspects traffic, it forwards via this RT. NAT GW translates
# the private source IP before sending to the internet.
resource "aws_route_table" "firewall" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${local.name}-firewall-rt" }
}

resource "aws_route_table_association" "firewall" {
  subnet_id      = aws_subnet.firewall.id
  route_table_id = aws_route_table.firewall.id
}

# RT-4: Public subnet → IGW (NAT GW egress)
# Return traffic destined for workload/proxy subnets is steered back through ANF
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  route {
    cidr_block      = var.workload_subnet_cidr
    vpc_endpoint_id = local.anf_endpoint_id
  }

  route {
    cidr_block      = var.proxy_subnet_cidr
    vpc_endpoint_id = local.anf_endpoint_id
  }

  tags = { Name = "${local.name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# RT-5: IGW ingress edge — not needed (no instances have public IPs)
# resource "aws_route_table" "igw_ingress" {
#   vpc_id = aws_vpc.main.id
#   tags   = { Name = "${local.name}-igw-ingress-rt" }
# }
#
# resource "aws_route_table_association" "igw" {
#   gateway_id     = aws_internet_gateway.main.id
#   route_table_id = aws_route_table.igw_ingress.id
# }
#
# resource "aws_route" "igw_ingress_workload" {
#   route_table_id         = aws_route_table.igw_ingress.id
#   destination_cidr_block = var.workload_subnet_cidr
#   vpc_endpoint_id        = local.anf_endpoint_id
# }
#
# resource "aws_route" "igw_ingress_proxy" {
#   route_table_id         = aws_route_table.igw_ingress.id
#   destination_cidr_block = var.proxy_subnet_cidr
#   vpc_endpoint_id        = local.anf_endpoint_id
# }



# ── AWS Network Firewall ──────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "anf_alert" {
  name              = "/aws/network-firewall/${local.name}/alert"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "anf_flow" {
  name              = "/aws/network-firewall/${local.name}/flow"
  retention_in_days = 7
}

locals {
  fqdn_rules = join("\n", [
    for idx, fqdn in var.allowed_fqdns :
    "pass tls ${var.vpc_cidr} any -> $EXTERNAL_NET 443 (tls.sni; content:\"${fqdn}\"; endswith; nocase; msg:\"allow ${fqdn}\"; sid:${1000 + idx}; rev:1;)"
  ])
}

resource "aws_networkfirewall_rule_group" "fqdn_allowlist" {
  name     = "${local.name}-fqdn-allowlist"
  type     = "STATEFUL"
  capacity = 100

  rule_group {
    rules_source {
      rules_string = local.fqdn_rules
    }

    stateful_rule_options {
      rule_order = "STRICT_ORDER"
    }
  }
}

resource "aws_networkfirewall_firewall_policy" "main" {
  name = "${local.name}-policy"

  firewall_policy {
    stateless_default_actions          = ["aws:forward_to_sfe"]
    stateless_fragment_default_actions = ["aws:forward_to_sfe"]

    stateful_engine_options {
      rule_order = "STRICT_ORDER"
    }

    stateful_rule_group_reference {
      resource_arn = aws_networkfirewall_rule_group.fqdn_allowlist.arn
      priority     = 1
    }

    stateful_default_actions = ["aws:drop_established"]
  }
}

resource "aws_networkfirewall_firewall" "main" {
  name                = "${local.name}-anf"
  vpc_id              = aws_vpc.main.id
  firewall_policy_arn = aws_networkfirewall_firewall_policy.main.arn

  subnet_mapping {
    subnet_id = aws_subnet.firewall.id
  }
}

resource "aws_networkfirewall_logging_configuration" "main" {
  firewall_arn = aws_networkfirewall_firewall.main.arn

  logging_configuration {
    log_destination_config {
      log_type             = "ALERT"
      log_destination_type = "CloudWatchLogs"
      log_destination      = { logGroup = aws_cloudwatch_log_group.anf_alert.name }
    }

    log_destination_config {
      log_type             = "FLOW"
      log_destination_type = "CloudWatchLogs"
      log_destination      = { logGroup = aws_cloudwatch_log_group.anf_flow.name }
    }
  }
}

locals {
  anf_endpoint_id = [
    for ss in aws_networkfirewall_firewall.main.firewall_status[0].sync_states :
    ss.attachment[0].endpoint_id
    if ss.availability_zone == var.availability_zone
  ][0]
}

# ── Proxy — EC2 with nginx on host ───────────────────────────────────────────

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

resource "aws_security_group" "proxy" {
  name        = "${local.name}-sg"
  description = "Proxy EC2 - nginx transparent proxy"
  vpc_id      = aws_vpc.main.id

  # AWS SG is evaluated before iptables, so allow TCP 443 (not 8443) from workload
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
  source_dest_check      = false

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
load_module /usr/lib64/nginx/modules/ngx_stream_module.so;

user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

stream {
    resolver 169.254.169.253 valid=30s ipv6=off;
    resolver_timeout 5s;

    log_format proxy '$remote_addr [$time_local] $protocol $status '
                     '$bytes_sent $bytes_received $session_time '
                     '"$ssl_preread_server_name"';
    access_log /var/log/nginx/access.log proxy;

    server {
        listen 8443;
        ssl_preread on;
        proxy_pass $ssl_preread_server_name:443;
        proxy_connect_timeout 10s;
        proxy_timeout 600s;
    }
}
NGINXCONF

    # iptables: redirect inbound TCP:443 to nginx, exclude nginx's own outbound
    NGINX_UID=$(id -u nginx)
    iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8443
    iptables -t nat -A OUTPUT -p tcp --dport 443 -m owner --uid-owner $NGINX_UID -j RETURN

    systemctl enable nginx
    systemctl start nginx
  EOF
  )

  tags = { Name = "${local.name}-proxy-ec2" }
}

# ── Workload ──────────────────────────────────────────────────────────────────

resource "aws_iam_role" "workload" {
  name = "${local.name}-workload-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "workload_ssm" {
  role       = aws_iam_role.workload.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "workload" {
  name = "${local.name}-workload-profile"
  role = aws_iam_role.workload.name
}

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
