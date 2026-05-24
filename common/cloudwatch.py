from __future__ import annotations

import time
from datetime import UTC, datetime, timedelta

import boto3


def metric_sum(
    *,
    region: str,
    namespace: str,
    metric_name: str,
    dimensions: dict[str, str],
    period_seconds: int,
    lookback_seconds: int,
) -> float:
    cloudwatch = boto3.client("cloudwatch", region_name=region)
    now = datetime.now(UTC)
    response = cloudwatch.get_metric_statistics(
        Namespace=namespace,
        MetricName=metric_name,
        Dimensions=[
            {"Name": key, "Value": value} for key, value in sorted(dimensions.items())
        ],
        StartTime=now - timedelta(seconds=lookback_seconds),
        EndTime=now,
        Period=period_seconds,
        Statistics=["Sum"],
    )
    return sum(datapoint.get("Sum", 0.0) for datapoint in response["Datapoints"])


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
