# ── nginx SNI allowlist (defense-in-depth, independent of the ANF rule group) ─
#
# Terraform seeds the parameter from var.nginx_allowed_snis. The proxy EC2
# pulls it from SSM every 60s via refresh-sni-allowlist.timer (baked into the
# AMI). §11 will later transfer write ownership away from Terraform; at that
# point this resource gains lifecycle { ignore_changes = [value] }.

resource "aws_ssm_parameter" "nginx_sni_allowlist" {
  name        = "/${local.name}/nginx-sni-allowlist"
  description = "Legacy compatibility fallback for SNIs allowed by the on-host nginx gate."
  type        = "StringList"
  value       = join(",", var.nginx_allowed_snis)
  tier        = "Standard"
}

# ── IAM: proxy EC2 reads the parameter, nothing else ─────────────────────────

data "aws_iam_policy_document" "proxy_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "proxy" {
  name               = "${local.name}-nginx-proxy"
  assume_role_policy = data.aws_iam_policy_document.proxy_assume.json
}

data "aws_iam_policy_document" "proxy_ssm_read" {
  statement {
    sid       = "ReadNginxSniAllowlist"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.nginx_sni_allowlist.arn]
  }
}

resource "aws_iam_role_policy" "proxy_ssm_read" {
  name   = "${local.name}-nginx-proxy-ssm-read"
  role   = aws_iam_role.proxy.id
  policy = data.aws_iam_policy_document.proxy_ssm_read.json
}

resource "aws_iam_instance_profile" "proxy" {
  name = "${local.name}-nginx-proxy"
  role = aws_iam_role.proxy.name
}
