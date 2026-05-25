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


# ── Shared-DNS T2: dedicated DNS VPC + BIND9 resolver ─────────────────────────


def _read_tf(name: str) -> str:
    return (TF_DIR / name).read_text(encoding="utf-8")


def test_shared_dns_resources_present():
    dns_vpc = _read_tf("dns_vpc.tf")
    dns_server = _read_tf("dns_server.tf")
    dns_resolver = _read_tf("dns_resolver.tf")
    peering = _read_tf("peering.tf")
    routes = _read_tf("routes.tf")
    for marker in (
        'resource "aws_vpc" "dns"',
        'resource "aws_subnet" "dns_private"',
        'resource "aws_route_table" "dns_private"',
    ):
        assert marker in dns_vpc, f"missing {marker} in dns_vpc.tf"
    for marker in (
        'resource "aws_instance" "bind"',
        'resource "aws_security_group" "bind"',
    ):
        assert marker in dns_server, f"missing {marker} in dns_server.tf"
    assert 'resource "aws_vpc_peering_connection" "workload_dns"' in peering
    assert 'resource "aws_vpc_peering_connection_accepter" "workload_dns"' in peering
    for marker in (
        'resource "aws_route" "workload_to_dns_vpc"',
        'resource "aws_route" "proxy_to_dns_vpc"',
        'resource "aws_route" "dns_to_workload_vpc"',
    ):
        assert marker in routes, f"missing {marker} in routes.tf"
    for marker in (
        'resource "aws_route53_resolver_endpoint" "shared_dns_outbound"',
        'resource "aws_route53_resolver_rule" "shared_dns_forward"',
        'resource "aws_route53_resolver_rule_association" "shared_dns_forward"',
    ):
        assert marker in dns_resolver, f"missing {marker} in dns_resolver.tf"


def test_dns_vpc_has_no_internet_egress():
    """BIND forwards to the VPC Route 53 Resolver, so the DNS VPC must not grow
    a NAT GW / IGW / public subnet (docs/shared-dns-cache.md)."""
    dns_vpc = _read_tf("dns_vpc.tf")
    for forbidden in ("aws_nat_gateway", "aws_internet_gateway", "aws_eip"):
        assert forbidden not in dns_vpc, f"{forbidden} reintroduces internet egress"


def test_shared_dns_is_gated():
    """Every new resource is gated so the default deployment is unaffected."""
    dns_vpc = _read_tf("dns_vpc.tf")
    dns_server = _read_tf("dns_server.tf")
    assert re.search(
        r"dns_enabled\s*=\s*var\.enable_shared_dns\s*\?\s*1\s*:\s*0", dns_vpc
    ), "local.dns_enabled toggle missing"
    # Every shared-DNS `resource` block must carry `count = local.dns_enabled`.
    for src, name in (
        (dns_vpc, "dns_vpc.tf"),
        (dns_server, "dns_server.tf"),
        (_read_tf("dns_resolver.tf"), "dns_resolver.tf"),
        (_read_tf("peering.tf"), "peering.tf"),
    ):
        blocks = len(re.findall(r"^resource ", src, re.MULTILINE))
        gated = len(
            re.findall(r"count\s*=\s*local\.dns_enabled", src)
            + re.findall(
                r"for_each\s*=\s*(?:local\.shared_dns_forwarded_domains|aws_route53_resolver_rule\.shared_dns_forward)",
                src,
            )
        )
        assert gated >= blocks, f"ungated resource block in {name}"

    routes = _read_tf("routes.tf")
    shared_dns_route_blocks = re.findall(
        r'^resource "aws_route" "(?:workload_to_dns_vpc|proxy_to_dns_vpc|dns_to_workload_vpc)" \{(?P<body>.*?)^}',
        routes,
        re.MULTILINE | re.DOTALL,
    )
    assert len(shared_dns_route_blocks) == 3, "expected three shared-DNS peering routes"
    for body in shared_dns_route_blocks:
        assert re.search(r"count\s*=\s*local\.dns_enabled", body), (
            "ungated shared-DNS route block in routes.tf"
        )


def test_shared_dns_forwarding_rules_default_to_allowed_fqdns():
    dns_resolver = _read_tf("dns_resolver.tf")
    variables = _read_tf("variables.tf")
    assert 'variable "forwarded_domains"' in variables
    assert "var.forwarded_domains" in dns_resolver
    assert "var.allowed_fqdns" in dns_resolver
    assert 'direction          = "OUTBOUND"' in dns_resolver
    assert len(re.findall(r"ip_address\s*{", dns_resolver)) >= 2, (
        "Route 53 Resolver outbound endpoint needs at least two IP addresses"
    )
    assert "aws_instance.bind[0].private_ip" in dns_resolver


def test_dns_firewall_association_can_be_temporarily_disabled():
    variables = _read_tf("variables.tf")
    dns_firewall = _read_tf("dns_firewall.tf")
    assert 'variable "enable_dns_firewall"' in variables
    association = dns_firewall.split(
        'resource "aws_route53_resolver_firewall_rule_group_association" "main"',
        1,
    )[1]
    assert re.search(r"count\s*=\s*var\.enable_dns_firewall\s*\?\s*1\s*:\s*0", association)


def test_shared_dns_off_by_default():
    variables = _read_tf("variables.tf")
    assert 'variable "enable_shared_dns"' in variables
    block = variables.split('variable "enable_shared_dns"', 1)[1]
    block = block.split("variable ", 1)[0]
    assert re.search(r"default\s*=\s*false", block), (
        "enable_shared_dns must default to false"
    )


# ── Shared-DNS T6: block off-path resolvers (DoT/DoQ) at ANF ──────────────────


def test_off_path_resolver_ports_dropped():
    """DoT (TCP/853) and DoQ (UDP/853) are dropped so the workload cannot
    resolve off-path (shared-dns-cache.md §5.1)."""
    firewall = _read_tf("firewall.tf")
    assert re.search(r"drop\s+tcp\b.*\b853\b", firewall), "missing DoT (TCP/853) drop rule"
    assert re.search(r"drop\s+udp\b.*\b853\b", firewall), "missing DoQ (UDP/853) drop rule"
    assert "local.off_path_resolver_rules" in firewall, (
        "off-path resolver rules not wired into stateful_rules"
    )


def test_dashboard_uses_statsd_metric_type_dimension():
    """CloudWatch Agent StatsD metrics include metric_type, so dashboard series
    must query the exact same dimension set or they render empty."""
    observability = _read_tf("observability.tf")
    assert '"Requests", "InstanceId", aws_instance.proxy.id, "metric_type", "counter"' in observability
    assert '"ActiveConnections", "InstanceId", aws_instance.proxy.id, "metric_type", "gauge"' in observability
    assert '"SniMismatchCount", "InstanceId", aws_instance.proxy.id, "metric_type", "counter"' in observability
    assert '"P50ProxyDecisionLatencyMs", "InstanceId", aws_instance.proxy.id, "metric_type", "gauge"' in observability
