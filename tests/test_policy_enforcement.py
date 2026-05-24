"""Live policy-enforcement tests.

Proves the proxy *drops* traffic it should drop and records it, covering the two
policy-denied decisions that the baseline test never exercises:

  * deny_allowlist - an SNI that is not in the allowlist
  * drop_no_sni    - a TLS ClientHello with no SNI (an IP-literal request)

Both land in the policy-denied log group and bump the RequestsBlocked metric.
Log-line assertions are the primary signal (mode-independent); the client-side
failure is only asserted in strict mode.
"""

from datetime import datetime, timezone

from common.cloudwatch import now_ms, wait_for_log_event, wait_for_metric_sum
from common.ssm import ssm_exec

POLICY_DENIED_GROUP = "/aws/firewall-proxy/nginx/policy-denied"
METRIC_NAMESPACE = "AwsFirewallProxy/Nginx"
DENIED_FQDN = "example.org"  # deliberately not in the allowlist


def _curl(outputs, aws_region, target: str, *, resolve_to: str | None = None):
    # resolve_to pins the destination IP and skips DNS entirely (curl --resolve),
    # which lets us send an SNI the DNS Firewall would otherwise NXDOMAIN before
    # any connection reaches the proxy.
    resolve = f"--resolve {target}:443:{resolve_to} " if resolve_to else ""
    cmd = f"curl -sk -o /dev/null --max-time 10 {resolve}https://{target}"
    return ssm_exec(
        outputs["workload_instance_id"],
        cmd,
        region=aws_region,
        timeout_seconds=30,
    )


def test_non_allowlisted_sni_is_denied(
    outputs, aws_region, proxy_enforcement_mode
):
    start_ms = now_ms()
    start = datetime.now(timezone.utc)

    # example.org is not in the DNS Firewall allowlist, so a plain request would
    # fail at resolution and never reach the proxy. Pin the IP to bypass DNS and
    # force the ClientHello (SNI=example.org) onto the proxy, where the on-host
    # allowlist denies it. The IP is irrelevant - the guard denies before resolving.
    result = _curl(outputs, aws_region, DENIED_FQDN, resolve_to="1.1.1.1")

    if proxy_enforcement_mode == "strict":
        assert result.exit_code != 0, (
            f"curl to non-allowlisted {DENIED_FQDN} should fail in strict mode: {result!r}"
        )

    line = wait_for_log_event(
        POLICY_DENIED_GROUP,
        region=aws_region,
        contains=['decision="deny_allowlist"', f'sni="{DENIED_FQDN}"'],
        start_ms=start_ms,
    )
    assert line is not None, (
        f"no deny_allowlist line for {DENIED_FQDN} in {POLICY_DENIED_GROUP}"
    )

    assert wait_for_metric_sum(
        METRIC_NAMESPACE, "RequestsBlocked", region=aws_region, start=start
    ), "RequestsBlocked metric did not increment"


def test_request_without_sni_is_dropped(outputs, aws_region):
    # An IP-literal HTTPS request sends no SNI in the ClientHello, so the guard
    # drops it as drop_no_sni regardless of allowlist contents.
    start_ms = now_ms()

    _curl(outputs, aws_region, "1.1.1.1")

    line = wait_for_log_event(
        POLICY_DENIED_GROUP,
        region=aws_region,
        contains='decision="drop_no_sni"',
        start_ms=start_ms,
    )
    assert line is not None, (
        f"no drop_no_sni line in {POLICY_DENIED_GROUP} after IP-literal request"
    )
