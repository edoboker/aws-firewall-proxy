locals {
  name = "${var.environment}-proxy"
}

# ── Data Sources ──────────────────────────────────────────────────────────────

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

# Golden AMI built by packer/workload. Bakes in `hey` for the benchmark suite.
data "aws_ami" "workload" {
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "tag:Name"
    values = ["aws-firewall-proxy-workload"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}
