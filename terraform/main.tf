locals {
  name = "${var.environment}-proxy"
}

# ── Data Sources ──────────────────────────────────────────────────────────────

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# Golden AMI built by packer/nginx-proxy. Most-recent self-owned image tagged
# Name=aws-firewall-proxy-nginx.
data "aws_ami" "nginx_proxy" {
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "tag:Name"
    values = ["aws-firewall-proxy-nginx"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}
