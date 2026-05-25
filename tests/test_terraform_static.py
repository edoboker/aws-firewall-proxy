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


def test_dns_firewall_association_can_be_temporarily_disabled():
    variables = _read_tf("variables.tf")
    dns_firewall = _read_tf("dns_firewall.tf")
    assert 'variable "enable_dns_firewall"' in variables
    association = dns_firewall.split(
        'resource "aws_route53_resolver_firewall_rule_group_association" "main"',
        1,
    )[1]
    assert re.search(r"count\s*=\s*var\.enable_dns_firewall\s*\?\s*1\s*:\s*0", association)


def test_off_path_resolver_ports_dropped():
    firewall = _read_tf("firewall.tf")
    assert re.search(r"drop\s+tcp\b.*\b853\b", firewall), "missing DoT (TCP/853) drop rule"
    assert re.search(r"drop\s+udp\b.*\b853\b", firewall), "missing DoQ (UDP/853) drop rule"
    assert "local.off_path_resolver_rules" in firewall, (
        "off-path resolver rules not wired into stateful_rules"
    )


def test_lambda_ip_fallback_rule_group_can_attach_to_firewall_policy():
    variables = _read_tf("variables.tf")
    firewall = _read_tf("firewall.tf")
    assert 'variable "enable_lambda_ip_fallback"' in variables
    assert "local.lambda_ip_fallback_rule_group_arns" in firewall
    assert "aws_networkfirewall_rule_group.lambda_ip_fallback[0].arn" in firewall
    assert re.search(r"priority\s*=\s*2", firewall), (
        "fallback rule group should evaluate after the primary FQDN/SNI group"
    )


def test_dashboard_uses_statsd_metric_type_dimension():
    observability = _read_tf("observability.tf")
    assert '"Requests", "InstanceId", aws_instance.proxy.id, "metric_type", "counter"' in observability
    assert '"ActiveConnections", "InstanceId", aws_instance.proxy.id, "metric_type", "gauge"' in observability
    assert '"SniMismatchCount", "InstanceId", aws_instance.proxy.id, "metric_type", "counter"' in observability
    assert '"P50ProxyDecisionLatencyMs", "InstanceId", aws_instance.proxy.id, "metric_type", "gauge"' in observability


def test_lambda_ip_fallback_defaults_off():
    variables = _read_tf("variables.tf")
    block = _variable_block(variables, "enable_lambda_ip_fallback")
    assert re.search(r"default\s*=\s*false", block)


def test_lambda_ip_fallback_mvp_fqdns():
    variables = _read_tf("variables.tf")
    block = _variable_block(variables, "lambda_ip_fallback_fqdns")
    assert "login.microsoftonline.com" in block
    assert "wiz.io" in block


def test_lambda_ip_fallback_resources_are_gated():
    fallback = _read_tf("lambda_ruleset_generator.tf")
    for marker in (
        'resource "aws_lambda_function" "lambda_ip_fallback"',
        'resource "aws_ec2_managed_prefix_list" "lambda_ip_fallback"',
        'resource "aws_networkfirewall_rule_group" "lambda_ip_fallback"',
    ):
        assert marker in fallback

    for resource_name in (
        "aws_cloudwatch_log_group",
        "aws_ec2_managed_prefix_list",
        "aws_iam_role",
        "aws_iam_role_policy",
        "aws_lambda_function",
        "aws_networkfirewall_rule_group",
    ):
        pattern = rf'resource "{resource_name}" "lambda_ip_fallback" \{{(?P<body>.*?)^}}'
        match = re.search(pattern, fallback, re.MULTILINE | re.DOTALL)
        assert match, f"missing {resource_name}.lambda_ip_fallback"
        assert "count" in match.group("body")
        assert (
            "local.lambda_ip_fallback_enabled" in match.group("body")
            or "local.lambda_ip_fallback_prefix_list_count" in match.group("body")
        )


def test_lambda_ip_fallback_does_not_require_shared_dns_or_nginx_changes():
    fallback = _read_tf("lambda_ruleset_generator.tf")
    assert "aws_instance.proxy" not in fallback
    assert "aws_appconfig" not in fallback
    assert "aws_instance.bind" not in fallback


def test_lambda_ip_fallback_rule_group_uses_tls_ip_set_destination():
    fallback = _read_tf("lambda_ruleset_generator.tf")
    assert "local.lambda_ip_fallback_source_cidrs" in fallback
    assert "@LAMBDA_IP_FALLBACK_TARGETS_${prefix_idx}" in fallback
    assert "dynamic \"ip_set_references\"" in fallback
    assert "reference_arn = aws_ec2_managed_prefix_list.lambda_ip_fallback[ip_set_references.value].arn" in fallback


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
