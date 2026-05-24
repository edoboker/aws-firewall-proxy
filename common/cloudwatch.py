"""CloudWatch helpers for the live test harness.

The proxy ships sparse event logs to dedicated log groups under
/aws/firewall-proxy/nginx/ and turns them into metrics via metric filters
(see terraform/observability.tf). These helpers let tests assert that a given
action produced the expected log line and incremented the expected metric.

Log-line assertions are the primary signal: they appear within seconds of the
CloudWatch agent flush. Metric datapoints lag by minutes (metric-filter
evaluation), so wait_for_metric_sum uses a generous timeout.
"""

import time

import boto3


def now_ms() -> int:
    """Epoch milliseconds — use just before an action to scope a log query."""
    return int(time.time() * 1000)


def wait_for_log_event(
    log_group: str,
    *,
    region: str,
    contains,
    start_ms: int,
    timeout_seconds: int = 120,
    poll_interval: float = 5.0,
) -> str | None:
    """Poll a log group for an event logged at/after start_ms whose message
    contains every substring in `contains`. Returns the matching message, or
    None if none appears before the timeout.
    """
    client = boto3.client("logs", region_name=region)
    needles = [contains] if isinstance(contains, str) else list(contains)
    deadline = time.monotonic() + timeout_seconds

    while True:
        try:
            paginator = client.get_paginator("filter_log_events")
            for page in paginator.paginate(
                logGroupName=log_group, startTime=start_ms
            ):
                for event in page.get("events", []):
                    message = event.get("message", "")
                    if all(needle in message for needle in needles):
                        return message
        except client.exceptions.ResourceNotFoundException:
            pass  # group not created yet / no streams — keep waiting

        if time.monotonic() > deadline:
            return None
        time.sleep(poll_interval)


def metric_sum(
    namespace: str,
    name: str,
    *,
    region: str,
    start,
    end,
    period: int = 60,
) -> float:
    """Sum of a metric's datapoints over [start, end] (datetimes)."""
    client = boto3.client("cloudwatch", region_name=region)
    resp = client.get_metric_statistics(
        Namespace=namespace,
        MetricName=name,
        StartTime=start,
        EndTime=end,
        Period=period,
        Statistics=["Sum"],
    )
    return sum(point["Sum"] for point in resp["Datapoints"])


def wait_for_metric_sum(
    namespace: str,
    name: str,
    *,
    region: str,
    start,
    min_value: float = 1.0,
    timeout_seconds: int = 90,
    poll_interval: float = 15.0,
) -> bool:
    """Poll until the metric's Sum since `start` (a datetime) reaches min_value.

    Returns True if it does within the timeout, else False. Metric-filter
    datapoints lag the source log line by a minute or two; the timeout trades a
    little headroom for a faster suite, so a legitimately slow datapoint can
    occasionally make this return False even though the log line was present.
    """
    from datetime import datetime, timedelta, timezone

    deadline = time.monotonic() + timeout_seconds
    while True:
        end = datetime.now(timezone.utc) + timedelta(minutes=1)
        if metric_sum(
            namespace, name, region=region, start=start, end=end
        ) >= min_value:
            return True
        if time.monotonic() > deadline:
            return False
        time.sleep(poll_interval)
