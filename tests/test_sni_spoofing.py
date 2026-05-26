"""Live SNI-spoofing detection test.

The core attack the proxy exists to stop: an allowlisted SNI pointed at an IP
that is not among that SNI's resolved A records. The guard must record a
`mismatch` in the dedicated sni-spoofing log (and bump SpoofingDetected) while
keeping the error log clean, and - in strict mode - reset the connection.
"""

from datetime import datetime, timezone

import pytest

from common.cloudwatch import now_ms, wait_for_log_event, wait_for_metric_sum
from common.ssm import ssm_exec

pytestmark = pytest.mark.skip(
    reason="live async spoofing-detector coverage is deferred for the override-proxy architecture"
)

SNI_SPOOFING_GROUP = "/aws/firewall-proxy/nginx/sni-spoofing"
ERROR_GROUP = "/aws/firewall-proxy/nginx/error"
METRIC_NAMESPACE = "AwsFirewallProxy/Nginx"
SPOOF_IP = "1.1.1.1"  # not an A record of the allowlisted FQDN


def test_sni_spoofing_detected(
    outputs, aws_region, baseline_fqdn, proxy_enforcement_mode
):
    start_ms = now_ms()
    start = datetime.now(timezone.utc)

    cmd = (
        f"curl -sk -o /dev/null --max-time 10 "
        f"--resolve {baseline_fqdn}:443:{SPOOF_IP} https://{baseline_fqdn}"
    )
    result = ssm_exec(
        outputs["workload_instance_id"],
        cmd,
        region=aws_region,
        timeout_seconds=30,
    )

    if proxy_enforcement_mode == "strict":
        assert result.exit_code != 0, (
            f"spoofed connection should be reset in strict mode: {result!r}"
        )

    line = wait_for_log_event(
        SNI_SPOOFING_GROUP,
        region=aws_region,
        contains=[
            'decision="mismatch"',
            f'sni="{baseline_fqdn}"',
            f'dst_ip="{SPOOF_IP}"',
        ],
        start_ms=start_ms,
    )
    assert line is not None, f"no mismatch line in {SNI_SPOOFING_GROUP}"

    assert wait_for_metric_sum(
        METRIC_NAMESPACE,
        "SpoofingDetected",
        region=aws_region,
        start=start,
        timeout_seconds=180,
        poll_interval=10.0,
    ), "SpoofingDetected metric did not increment"

    # The spoof signal must stay out of the error log (it must not be counted as
    # a Failure). Short window: if it were going to leak, it already has.
    leaked = wait_for_log_event(
        ERROR_GROUP,
        region=aws_region,
        contains="mismatch",
        start_ms=start_ms,
        timeout_seconds=15,
    )
    assert leaked is None, f"spoof line leaked into the error log: {leaked!r}"
