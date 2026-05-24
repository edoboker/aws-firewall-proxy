locals {
  proxy_dns_resolvers = concat(
    ["169.254.169.253"],
    [for resolver in var.proxy_public_dns_resolvers : resolver if resolver != "169.254.169.253"]
  )

  # MVP choice: keep the AppConfig document focused on traffic policy
  # (`allowed_snis`, DNS behavior, enforcement mode). The metrics publish
  # interval stays Terraform-owned for now because changing it would also need
  # coordinated CloudWatch agent re-render/restart behavior and dashboard/test
  # timing updates. A future "hot-reload everything via AppConfig" design is
  # valid, but we are intentionally not taking that on in this pass.
  proxy_runtime_policy = {
    allowed_snis = var.nginx_allowed_snis
    dns = {
      resolvers       = local.proxy_dns_resolvers
      queries_per_sni = var.proxy_dns_queries_per_sni
    }
    enforcement = {
      mode = var.proxy_enforcement_mode
    }
  }
}

resource "aws_appconfig_application" "proxy" {
  name        = local.name
  description = "Runtime policy for the on-host nginx/OpenResty proxy"
}

resource "aws_appconfig_environment" "proxy" {
  application_id = aws_appconfig_application.proxy.id
  name           = var.environment
  description    = "Runtime policy environment for ${local.name}"
}

resource "aws_appconfig_configuration_profile" "proxy_runtime_policy" {
  application_id = aws_appconfig_application.proxy.id
  name           = "runtime-policy"
  description    = "Unified runtime policy for the on-host proxy"
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
