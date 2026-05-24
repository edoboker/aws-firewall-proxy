"""CloudWatch helpers for the live test harness.

This module supports two styles of assertions:

- direct proxy metrics emitted via local StatsD and published by the CloudWatch
  agent
- sparse security-event logs that are turned into CloudWatch metrics by metric
  filters
"""

from __future__ import annotations

import time
from datetime import UTC, datetime, timedelta, timezone

import boto3


def now_ms() -> int:
    """Epoch milliseconds, useful for scoping log queries around an action."""
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
    """Poll a log group for an event at/after start_ms matching all substrings."""
    client = boto3.client("logs", region_name=region)
    needles = [contains] if isinstance(contains, str) else list(contains)
    deadline = time.monotonic() + timeout_seconds

    while True:
        try:
            paginator = client.get_paginator("filter_log_events")
            for page in paginator.paginate(logGroupName=log_group, startTime=start_ms):
                for event in page.get("events", []):
                    message = event.get("message", "")
                    if all(needle in message for needle in needles):
                        return message
        except client.exceptions.ResourceNotFoundException:
            pass

        if time.monotonic() > deadline:
            return None
        time.sleep(poll_interval)


def _metric_sum_raw(
    *,
    region: str,
    namespace: str,
    metric_name: str,
    start: datetime,
    end: datetime,
    period: int,
    dimensions: dict[str, str] | None = None,
) -> float:
    client = boto3.client("cloudwatch", region_name=region)
    response = client.get_metric_statistics(
        Namespace=namespace,
        MetricName=metric_name,
        Dimensions=[
            {"Name": key, "Value": value}
            for key, value in sorted((dimensions or {}).items())
        ],
        StartTime=start,
        EndTime=end,
        Period=period,
        Statistics=["Sum"],
    )
    return sum(datapoint.get("Sum", 0.0) for datapoint in response["Datapoints"])


def metric_sum(*args, **kwargs) -> float:
    """Return a metric sum for either a time range or a recent lookback window."""
    if len(args) == 2:
        namespace, metric_name = args
        region = kwargs.pop("region")
        start = kwargs.pop("start")
        end = kwargs.pop("end")
        period = kwargs.pop("period", 60)
        dimensions = kwargs.pop("dimensions", None)
    elif len(args) == 0:
        region = kwargs.pop("region")
        namespace = kwargs.pop("namespace")
        metric_name = kwargs.pop("metric_name", kwargs.pop("name", None))
        dimensions = kwargs.pop("dimensions", None)

        if "start" in kwargs and "end" in kwargs:
            start = kwargs.pop("start")
            end = kwargs.pop("end")
            period = kwargs.pop("period", 60)
        else:
            period = kwargs.pop("period_seconds")
            lookback_seconds = kwargs.pop("lookback_seconds")
            end = datetime.now(UTC)
            start = end - timedelta(seconds=lookback_seconds)
    else:
        raise TypeError("metric_sum accepts either 0 or 2 positional arguments")

    if kwargs:
        unexpected = ", ".join(sorted(kwargs))
        raise TypeError(f"unexpected metric_sum arguments: {unexpected}")

    if metric_name is None:
        raise TypeError("metric_sum requires metric_name/name")

    return _metric_sum_raw(
        region=region,
        namespace=namespace,
        metric_name=metric_name,
        start=start,
        end=end,
        period=period,
        dimensions=dimensions,
    )


def wait_for_metric_delta(
    *,
    region: str,
    namespace: str,
    metric_name: str,
    dimensions: dict[str, str],
    period_seconds: int,
    lookback_seconds: int,
    baseline: float,
    minimum_delta: float,
    timeout_seconds: int,
    poll_interval_seconds: int = 15,
) -> float:
    deadline = time.monotonic() + timeout_seconds

    while True:
        current = metric_sum(
            region=region,
            namespace=namespace,
            metric_name=metric_name,
            dimensions=dimensions,
            period_seconds=period_seconds,
            lookback_seconds=lookback_seconds,
        )
        if current - baseline >= minimum_delta:
            return current

        if time.monotonic() > deadline:
            raise TimeoutError(
                f"{metric_name} in {namespace} did not increase by at least "
                f"{minimum_delta}; baseline={baseline}, current={current}"
            )

        time.sleep(poll_interval_seconds)


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
    """Poll until the metric's Sum since start reaches min_value."""
    deadline = time.monotonic() + timeout_seconds

    while True:
        end = datetime.now(timezone.utc) + timedelta(minutes=1)
        if metric_sum(
            namespace,
            name,
            region=region,
            start=start,
            end=end,
        ) >= min_value:
            return True
        if time.monotonic() > deadline:
            return False
        time.sleep(poll_interval)
