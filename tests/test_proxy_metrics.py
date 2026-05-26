from __future__ import annotations

import pytest

from common.cloudwatch import metric_sum, wait_for_metric_delta
from common.ssm import ssm_exec

pytestmark = pytest.mark.skip(
    reason="live proxy metrics coverage is deferred while TLS path no longer uses Lua metrics"
)


def _baseline_fqdn(outputs: dict) -> str:
    fqdns = outputs.get("nginx_allowed_snis") or outputs["allowed_fqdns"]
    assert fqdns, "no baseline fqdn output - check terraform outputs"
    if "google.com" in fqdns:
        return "www.google.com"
    return fqdns[0]


def _blocked_fqdn(outputs: dict) -> str:
    allowed = set(outputs.get("nginx_allowed_snis") or [])
    for candidate in ("example.com", "example.org", "iana.org", "github.com"):
        if candidate not in allowed:
            return candidate
    raise AssertionError("could not find a blocked fqdn candidate for the metrics test")


def _spoof_target(outputs: dict) -> str:
    allowed = outputs.get("nginx_allowed_snis") or outputs["allowed_fqdns"]
    assert allowed, "no spoof target available"
    if "google.com" in allowed:
        return "google.com"
    return allowed[0]


def test_proxy_metrics_reach_cloudwatch(outputs, aws_region):
    namespace = outputs["proxy_metric_namespace"]
    period_seconds = int(outputs["proxy_metrics_publish_interval_seconds"])
    dimensions = {"InstanceId": outputs["proxy_instance_id"]}
    baseline_fqdn = _baseline_fqdn(outputs)
    blocked_fqdn = _blocked_fqdn(outputs)
    spoof_target = _spoof_target(outputs)
    allowed_count = 4
    blocked_count = 2
    spoof_count = 1
    total_count = allowed_count + blocked_count + spoof_count
    lookback_seconds = max(period_seconds * 8, 600)

    baselines = {
        "Requests": metric_sum(
            region=aws_region,
            namespace=namespace,
            metric_name="Requests",
            dimensions=dimensions,
            period_seconds=period_seconds,
            lookback_seconds=lookback_seconds,
        ),
        "AcceptedConnections": metric_sum(
            region=aws_region,
            namespace=namespace,
            metric_name="AcceptedConnections",
            dimensions=dimensions,
            period_seconds=period_seconds,
            lookback_seconds=lookback_seconds,
        ),
        "BlockedConnections": metric_sum(
            region=aws_region,
            namespace=namespace,
            metric_name="BlockedConnections",
            dimensions=dimensions,
            period_seconds=period_seconds,
            lookback_seconds=lookback_seconds,
        ),
        "SniMismatchCount": metric_sum(
            region=aws_region,
            namespace=namespace,
            metric_name="SniMismatchCount",
            dimensions=dimensions,
            period_seconds=period_seconds,
            lookback_seconds=lookback_seconds,
        ),
    }

    command = (
        f"for i in $(seq 1 {allowed_count}); do "
        f"curl -sk --max-time 10 https://{baseline_fqdn} >/dev/null; "
        f"done; "
        f"for i in $(seq 1 {blocked_count}); do "
        f"curl -sk --max-time 10 https://{blocked_fqdn} >/dev/null || true; "
        f"done; "
        f"curl -sk --max-time 10 --resolve {spoof_target}:443:1.1.1.1 "
        f"https://{spoof_target} >/dev/null || true"
    )
    result = ssm_exec(
        outputs["workload_instance_id"],
        command,
        region=aws_region,
        timeout_seconds=120,
    )
    assert result.status == "Success", f"traffic generation failed: {result!r}"

    timeout_seconds = period_seconds * 6 + 120
    poll_interval_seconds = max(5, min(10, period_seconds // 2))
    wait_for_metric_delta(
        region=aws_region,
        namespace=namespace,
        metric_name="Requests",
        dimensions=dimensions,
        period_seconds=period_seconds,
        lookback_seconds=lookback_seconds,
        baseline=baselines["Requests"],
        minimum_delta=total_count,
        timeout_seconds=timeout_seconds,
        poll_interval_seconds=poll_interval_seconds,
    )
    wait_for_metric_delta(
        region=aws_region,
        namespace=namespace,
        metric_name="AcceptedConnections",
        dimensions=dimensions,
        period_seconds=period_seconds,
        lookback_seconds=lookback_seconds,
        baseline=baselines["AcceptedConnections"],
        minimum_delta=allowed_count,
        timeout_seconds=timeout_seconds,
        poll_interval_seconds=poll_interval_seconds,
    )
    wait_for_metric_delta(
        region=aws_region,
        namespace=namespace,
        metric_name="BlockedConnections",
        dimensions=dimensions,
        period_seconds=period_seconds,
        lookback_seconds=lookback_seconds,
        baseline=baselines["BlockedConnections"],
        minimum_delta=blocked_count,
        timeout_seconds=timeout_seconds,
        poll_interval_seconds=poll_interval_seconds,
    )
    wait_for_metric_delta(
        region=aws_region,
        namespace=namespace,
        metric_name="SniMismatchCount",
        dimensions=dimensions,
        period_seconds=period_seconds,
        lookback_seconds=lookback_seconds,
        baseline=baselines["SniMismatchCount"],
        minimum_delta=spoof_count,
        timeout_seconds=timeout_seconds,
        poll_interval_seconds=poll_interval_seconds,
    )
