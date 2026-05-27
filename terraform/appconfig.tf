locals {
  proxy_dns_resolvers = concat(
    ["169.254.169.253"],
    [for resolver in var.proxy_public_dns_resolvers : resolver if resolver != "169.254.169.253"]
  )

  # AppConfig renders the nginx resolver include used by TLS override proxy_pass.
  # The allowlist, query count, and enforcement fields are only for the
  # experimental cleartext HTTP Host/original-dst listener.
  proxy_runtime_policy = {
    allowed_hosts = var.http_allowed_hosts
    dns = {
      resolvers        = local.proxy_dns_resolvers
      queries_per_host = var.http_dns_queries_per_host
    }
    enforcement = {
      mode = var.http_enforcement_mode
    }
  }
}

resource "aws_appconfig_application" "proxy" {
  name        = local.name
  description = "Runtime DNS and experimental HTTP policy for the proxy"
}

resource "aws_appconfig_environment" "proxy" {
  application_id = aws_appconfig_application.proxy.id
  name           = var.environment
  description    = "Runtime policy environment for ${local.name}"
}

resource "aws_appconfig_configuration_profile" "proxy_runtime_policy" {
  application_id = aws_appconfig_application.proxy.id
  name           = "runtime-policy"
  description    = "Proxy resolver and HTTP Host/original-dst guard runtime policy"
  location_uri   = "hosted"
  type           = "AWS.Freeform"

  validator {
    type    = "JSON_SCHEMA"
    content = file("${path.module}/appconfig-policies/proxy_runtime_policy.schema.json")
  }
}

resource "aws_appconfig_hosted_configuration_version" "proxy_runtime_policy" {
  application_id           = aws_appconfig_application.proxy.id
  configuration_profile_id = aws_appconfig_configuration_profile.proxy_runtime_policy.configuration_profile_id
  description              = "Terraform-managed runtime policy for ${local.name}"
  content_type             = "application/json"
  content                  = jsonencode(local.proxy_runtime_policy)
}

resource "aws_appconfig_deployment" "proxy_runtime_policy" {
  application_id           = aws_appconfig_application.proxy.id
  configuration_profile_id = aws_appconfig_configuration_profile.proxy_runtime_policy.configuration_profile_id
  configuration_version    = tostring(aws_appconfig_hosted_configuration_version.proxy_runtime_policy.version_number)
  deployment_strategy_id   = "AppConfig.AllAtOnce"
  description              = "Deploy runtime policy for ${local.name}"
  environment_id           = aws_appconfig_environment.proxy.environment_id
}

data "aws_iam_policy_document" "proxy_appconfig_read" {
  statement {
    sid = "ReadProxyRuntimePolicyFromAppConfig"
    actions = [
      "appconfig:StartConfigurationSession",
      "appconfig:GetLatestConfiguration",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "proxy_appconfig_read" {
  name   = "${local.name}-nginx-proxy-appconfig-read"
  role   = aws_iam_role.proxy.id
  policy = data.aws_iam_policy_document.proxy_appconfig_read.json
}
