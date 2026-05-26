import re
import shutil
import subprocess
from pathlib import Path

import pytest

TF_DIR = Path(__file__).resolve().parents[1] / "terraform"

pytestmark = pytest.mark.skipif(
    shutil.which("terraform") is None, reason="terraform not on PATH"
)


def _terraform(*args) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["terraform", f"-chdir={TF_DIR}", *args],
        capture_output=True,
        text=True,
    )


def test_terraform_fmt():
    result = _terraform("fmt", "-check", "-recursive")
    assert result.returncode == 0, (
        "terraform fmt would reformat these files:\n" + result.stdout
    )


def test_terraform_validate():
    if not (TF_DIR / ".terraform").exists():
        pytest.skip("terraform not initialized (run 'terraform init')")
    result = _terraform("validate")
    assert result.returncode == 0, (
        f"terraform validate failed:\n{result.stdout}\n{result.stderr}"
    )


def _read_tf(name: str) -> str:
    return (TF_DIR / name).read_text(encoding="utf-8")


def _variable_block(source: str, name: str) -> str:
    block = source.split(f'variable "{name}"', 1)[1]
    return block.split("\nvariable ", 1)[0]


def test_bind_deployment_terraform_removed():
    for removed in (
        "dns_vpc.tf",
        "dns_server.tf",
        "dns_resolver.tf",
        "peering.tf",
    ):
        assert not (TF_DIR / removed).exists(), f"{removed} should not deploy BIND/shared DNS"

    terraform_sources = "\n".join(
        path.read_text(encoding="utf-8")
        for path in TF_DIR.glob("*.tf")
        if path.name != "lambda_ruleset_generator.tf"
    )
    for forbidden in (
        'aws_instance" "bind"',
        'aws_route53_resolver_endpoint" "shared_dns_outbound"',
        'aws_vpc_peering_connection" "workload_dns"',
        'aws_vpc" "dns"',
        "enable_shared_dns",
        "dns_vpc_cidr",
    ):
        assert forbidden not in terraform_sources


def test_off_path_resolver_ports_dropped():
    firewall = _read_tf("firewall.tf")
    assert re.search(r"drop\s+tcp\b.*\b853\b", firewall), "missing DoT (TCP/853) drop rule"
    assert re.search(r"drop\s+udp\b.*\b853\b", firewall), "missing DoQ (UDP/853) drop rule"
    assert "local.off_path_resolver_rules" in firewall, (
        "off-path resolver rules not wired into stateful_rules"
    )


def test_ruleset_generator_rule_group_can_attach_to_firewall_policy():
    variables = _read_tf("variables.tf")
    firewall = _read_tf("firewall.tf")
    assert 'variable "enable_ruleset_generator"' in variables
    assert "local.ruleset_generator_rule_group_arns" in firewall
    assert "aws_networkfirewall_rule_group.ruleset_generator[0].arn" in firewall
    assert re.search(r"priority\s*=\s*2", firewall), (
        "ruleset-generator rule group should evaluate after the primary FQDN/SNI group"
    )


def test_dashboard_uses_statsd_metric_type_dimension():
    observability = _read_tf("observability.tf")
    assert '"Requests", "InstanceId", aws_instance.proxy.id, "metric_type", "counter"' in observability
    assert '"ActiveConnections", "InstanceId", aws_instance.proxy.id, "metric_type", "gauge"' in observability


def test_override_observation_log_is_collected_and_tls_path_uses_ssl_preread():
    nginx = (TF_DIR.parent / "packer" / "nginx-proxy" / "assets" / "nginx" / "conf" / "nginx.conf.template").read_text(encoding="utf-8")
    cloudwatch_agent = (TF_DIR.parent / "packer" / "nginx-proxy" / "assets" / "cloudwatch" / "amazon-cloudwatch-agent.json").read_text(encoding="utf-8")

    tls_server = nginx.split("listen 8443;", 1)[1].split("\n    server {", 1)[0]
    assert "ssl_preread on;" in tls_server
    assert "proxy_pass $ssl_preread_server_name:443;" in tls_server
    assert "preread_by_lua_file /etc/nginx/lua/check_sni.lua;" not in tls_server
    assert "log_by_lua_file" not in tls_server

    assert "log_format override_observation escape=json" in nginx
    assert "/var/log/nginx/override_observations.log" in nginx
    assert '"proxy_instance_id"' not in nginx
    assert "/var/log/nginx/override_observations.log" in cloudwatch_agent
    assert "/aws/firewall-proxy/nginx/override-observations" in cloudwatch_agent
    assert '"log_stream_name": "{instance_id}"' in cloudwatch_agent


def test_async_sni_spoofing_detector_terraform_resources():
    detector = _read_tf("sni_spoofing_detector.tf")

    for marker in (
        'resource "aws_lambda_function" "sni_spoofing_detector"',
        'resource "aws_cloudwatch_log_group" "proxy_override_observations"',
        'resource "aws_cloudwatch_log_subscription_filter" "sni_spoofing_detector"',
        'resource "aws_lambda_permission" "sni_spoofing_detector_logs"',
        'resource "aws_cloudwatch_metric_alarm" "suspected_sni_spoofing"',
    ):
        assert marker in detector

    assert "/aws/firewall-proxy/nginx/override-observations" in detector
    assert 'runtime          = "python3.12"' in detector
    assert 'principal      = "logs.${var.aws_region}.amazonaws.com"' in detector
    assert 'actions   = ["cloudwatch:PutMetricData"]' in detector
    assert 'variable = "cloudwatch:namespace"' in detector
    assert 'sni_spoofing_detector_metric_namespace   = "AwsFirewallProxy"' in detector
    assert 'sni_spoofing_detector_metric_name        = "SuspectedSniSpoofing"' in detector


def test_ruleset_generator_defaults_off():
    variables = _read_tf("variables.tf")
    block = _variable_block(variables, "enable_ruleset_generator")
    assert re.search(r"default\s*=\s*false", block)


def test_ruleset_generator_mvp_fqdns():
    variables = _read_tf("variables.tf")
    block = _variable_block(variables, "ruleset_generator_fqdns")
    assert "login.microsoftonline.com" in block
    assert "wiz.io" in block


def test_ruleset_generator_resources_are_gated():
    ruleset_generator = _read_tf("lambda_ruleset_generator.tf")
    for marker in (
        'resource "aws_lambda_function" "ruleset_generator"',
        'resource "aws_ec2_managed_prefix_list" "ruleset_generator"',
        'resource "aws_networkfirewall_rule_group" "ruleset_generator"',
    ):
        assert marker in ruleset_generator

    for resource_name in (
        "aws_cloudwatch_log_group",
        "aws_ec2_managed_prefix_list",
        "aws_iam_role",
        "aws_iam_role_policy",
        "aws_lambda_function",
        "aws_networkfirewall_rule_group",
    ):
        pattern = rf'resource "{resource_name}" "ruleset_generator" \{{(?P<body>.*?)^}}'
        match = re.search(pattern, ruleset_generator, re.MULTILINE | re.DOTALL)
        assert match, f"missing {resource_name}.ruleset_generator"
        assert (
            "count" in match.group("body")
            or "for_each" in match.group("body")
        )
        assert (
            "local.ruleset_generator_enabled" in match.group("body")
            or "var.enable_ruleset_generator" in match.group("body")
        )


def test_ruleset_generator_does_not_require_shared_dns_or_nginx_changes():
    ruleset_generator = _read_tf("lambda_ruleset_generator.tf")
    assert "aws_instance.proxy" not in ruleset_generator
    assert "aws_appconfig" not in ruleset_generator
    assert "aws_instance.bind" not in ruleset_generator


def test_ruleset_generator_rule_group_uses_tls_ip_set_destination():
    ruleset_generator = _read_tf("lambda_ruleset_generator.tf")
    assert "local.ruleset_generator_source_cidrs" in ruleset_generator
    assert 'tls.sni; content:\\"${fqdn}\\"; startswith; endswith; nocase' in ruleset_generator
    assert "@${local.ruleset_generator_ip_set_keys[fqdn]}" in ruleset_generator
    assert "dynamic \"ip_set_references\"" in ruleset_generator
    assert "for_each = aws_ec2_managed_prefix_list.ruleset_generator" in ruleset_generator
    assert "key = local.ruleset_generator_ip_set_keys[ip_set_references.key]" in ruleset_generator
    assert "reference_arn = ip_set_references.value.arn" in ruleset_generator
    assert "ruleset_generator_fqdn_allowlist_overlap" in ruleset_generator
    assert "ruleset_generator_fqdns must not overlap allowed_fqdns" in ruleset_generator


def test_direct_workload_bypasses_nginx_and_routes_through_firewall():
    vpc = _read_tf("vpc.tf")
    workload = _read_tf("workload.tf")
    routes = _read_tf("routes.tf")
    outputs = _read_tf("outputs.tf")

    assert 'resource "aws_subnet" "direct_workload"' in vpc
    assert 'resource "aws_instance" "direct_workload"' in workload

    direct_route = routes.split('resource "aws_route" "direct_workload_to_firewall"', 1)[1]
    direct_route = direct_route.split("\nresource ", 1)[0]
    assert "vpc_endpoint_id        = local.anf_endpoint_id" in direct_route
    assert "network_interface_id" not in direct_route
    assert "aws_instance.proxy" not in direct_route

    assert 'resource "aws_route" "public_return_direct_workload"' in routes
    assert 'output "direct_workload_instance_id"' in outputs
