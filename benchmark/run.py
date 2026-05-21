"""Proxy added-latency + max-RPS benchmark.

Drives `hey` on the workload EC2 via SSM Run Command, once with the
workload's default route pointing through the nginx proxy (current state),
once with it repointed directly at the ANF endpoint. The delta is the
latency added by the proxy hop.

This is deliberately small (cost cap; see benchmark/README.md). It is meant
to demonstrate methodology, not exhaustively characterize the proxy.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
import time
from dataclasses import asdict, dataclass, replace
from datetime import datetime, timezone
from pathlib import Path

import boto3
from botocore.exceptions import ClientError
import yaml

from common.ssm import ssm_exec
from common.tf_outputs import load as load_tf_outputs

# Knobs
# Both phases use `hey -m HEAD` so per-request bytes are headers-only
# (~few hundred bytes). With the defaults below, total bytes through ANF+NAT
# per run stay well under 200 MB -> < $0.03 in data-processing charges.
DEFAULT_LATENCY_DURATION_S = 5
DEFAULT_LATENCY_CONCURRENCY = 2
DEFAULT_RPS_DURATION_S = 5
DEFAULT_RPS_CONCURRENCY = 50

# Per-GB data-processing prices used to estimate the run's $ cost. These are
# rough public-pricing constants for cost ballpark only, not a billing source
# of truth. Update if AWS changes prices.
ANF_USD_PER_GB = 0.065
NAT_USD_PER_GB = 0.045

DEFAULT_ROUTE_SWAP_TIMEOUT_S = 30
DEFAULT_ROUTE_POLL_INTERVAL_S = 1.0
DEFAULT_RESULTS_DIR = Path(__file__).parent / "results"


@dataclass(frozen=True)
class RuntimeConfig:
    fqdn: str | None
    results_dir: Path
    latency_duration_s: int
    latency_concurrency: int
    rps_duration_s: int
    rps_concurrency: int
    route_swap_timeout_s: int
    route_poll_interval_s: float


@dataclass
class HeyResult:
    rps: float
    p50_ms: float
    p95_ms: float
    p99_ms: float
    total_requests: int
    total_bytes: int
    raw: str


@dataclass
class ScenarioResult:
    name: str
    latency: HeyResult
    max_rps: HeyResult


def read_positive_int(raw: object, *, name: str, default: int) -> int:
    if raw is None:
        return default
    if isinstance(raw, bool):
        raise ValueError(f"{name} must be a positive integer")
    try:
        value = int(raw)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{name} must be a positive integer") from exc
    if value <= 0:
        raise ValueError(f"{name} must be a positive integer")
    return value


def read_positive_float(raw: object, *, name: str, default: float) -> float:
    if raw is None:
        return default
    if isinstance(raw, bool):
        raise ValueError(f"{name} must be a positive number")
    try:
        value = float(raw)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{name} must be a positive number") from exc
    if not math.isfinite(value) or value <= 0:
        raise ValueError(f"{name} must be a positive number")
    return value


def format_ms(value: float, *, signed: bool = False) -> str:
    if math.isnan(value):
        return "nan ms"
    if signed:
        return f"{value:+.1f} ms"
    return f"{value:.1f} ms"


def json_safe(value: object) -> object:
    if isinstance(value, float) and math.isnan(value):
        return "NaN"
    if isinstance(value, dict):
        return {key: json_safe(item) for key, item in value.items()}
    if isinstance(value, list):
        return [json_safe(item) for item in value]
    return value


def load_config(path: Path | None) -> RuntimeConfig:
    raw: dict[str, object] = {}
    if path is not None:
        try:
            loaded = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        except yaml.YAMLError as exc:
            raise ValueError(f"invalid YAML in {path}: {exc}") from exc
        if not isinstance(loaded, dict):
            raise ValueError(f"{path} must contain a top-level mapping")
        raw = loaded

    fqdn = raw.get("fqdn")
    if fqdn is not None:
        if not isinstance(fqdn, str) or not fqdn.strip():
            raise ValueError("fqdn in the YAML config must be a non-empty string")
        fqdn = fqdn.strip()

    results_dir = raw.get("results_dir")
    if results_dir is None:
        results_dir_path = DEFAULT_RESULTS_DIR
    else:
        if not isinstance(results_dir, str) or not results_dir.strip():
            raise ValueError("results_dir in the YAML config must be a non-empty string")
        results_dir_path = Path(results_dir)
        if path is not None and not results_dir_path.is_absolute():
            results_dir_path = path.parent / results_dir_path

    latency = raw.get("latency") or {}
    rps = raw.get("rps") or {}
    route_swap = raw.get("route_swap") or {}
    if not isinstance(latency, dict):
        raise ValueError("latency in the YAML config must be a mapping")
    if not isinstance(rps, dict):
        raise ValueError("rps in the YAML config must be a mapping")
    if not isinstance(route_swap, dict):
        raise ValueError("route_swap in the YAML config must be a mapping")

    return RuntimeConfig(
        fqdn=fqdn,
        results_dir=results_dir_path,
        latency_duration_s=read_positive_int(
            latency.get("duration_s"),
            name="latency.duration_s",
            default=DEFAULT_LATENCY_DURATION_S,
        ),
        latency_concurrency=read_positive_int(
            latency.get("concurrency"),
            name="latency.concurrency",
            default=DEFAULT_LATENCY_CONCURRENCY,
        ),
        rps_duration_s=read_positive_int(
            rps.get("duration_s"),
            name="rps.duration_s",
            default=DEFAULT_RPS_DURATION_S,
        ),
        rps_concurrency=read_positive_int(
            rps.get("concurrency"),
            name="rps.concurrency",
            default=DEFAULT_RPS_CONCURRENCY,
        ),
        route_swap_timeout_s=read_positive_int(
            route_swap.get("timeout_s"),
            name="route_swap.timeout_s",
            default=DEFAULT_ROUTE_SWAP_TIMEOUT_S,
        ),
        route_poll_interval_s=read_positive_float(
            route_swap.get("poll_interval_s"),
            name="route_swap.poll_interval_s",
            default=DEFAULT_ROUTE_POLL_INTERVAL_S,
        ),
    )


# hey output parsing
# Example fragments from `hey` text output:
#   Requests/sec:   1234.5678
#   Total data:     1234567 bytes
#   Latency distribution:
#     50% in 0.0012 secs
#     95% in 0.0034 secs
#     99% in 0.0056 secs
#   [200] 1000 responses

_RPS_RE = re.compile(r"Requests/sec:\s+([\d.]+)")
_BYTES_RE = re.compile(r"Total data:\s+(\d+)\s+bytes")
# Some hey builds print `10%% in 0.0499 secs` (literal double-%); accept 1+.
_PCT_RE = re.compile(r"^\s+(\d+)%+\s+in\s+([\d.]+)\s+secs", re.MULTILINE)
_STATUS_RE = re.compile(r"^\s*\[(\d+)\]\s+(\d+)\s+responses", re.MULTILINE)


def parse_hey(raw: str) -> HeyResult:
    rps = float(_RPS_RE.search(raw).group(1))
    # HEAD requests have no body, so hey omits "Total data:"; treat as 0.
    bytes_m = _BYTES_RE.search(raw)
    total_bytes = int(bytes_m.group(1)) if bytes_m else 0
    pcts = {int(m.group(1)): float(m.group(2)) * 1000 for m in _PCT_RE.finditer(raw)}
    total_requests = sum(int(m.group(2)) for m in _STATUS_RE.finditer(raw))
    return HeyResult(
        rps=rps,
        p50_ms=pcts.get(50, float("nan")),
        p95_ms=pcts.get(95, float("nan")),
        p99_ms=pcts.get(99, float("nan")),
        total_requests=total_requests,
        total_bytes=total_bytes,
        raw=raw,
    )


# hey driver


def _run_hey(
    *,
    instance_id: str,
    region: str,
    fqdn: str,
    duration_s: int,
    concurrency: int,
) -> HeyResult:
    cmd = (
        f"/usr/local/bin/hey -m HEAD -disable-keepalive=false "
        f"-z {duration_s}s -c {concurrency} https://{fqdn}"
    )
    # SSM timeout: hey duration + generous overhead for connect/teardown.
    result = ssm_exec(
        instance_id,
        cmd,
        region=region,
        timeout_seconds=duration_s + 60,
    )
    if result.exit_code != 0:
        raise RuntimeError(
            f"hey failed (exit {result.exit_code}):\nstdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    return parse_hey(result.stdout)


def run_scenario(
    *,
    name: str,
    instance_id: str,
    region: str,
    config: RuntimeConfig,
) -> ScenarioResult:
    if config.fqdn is None:
        raise RuntimeError("benchmark target FQDN is not set")

    print(
        f"  [{name}] latency probe "
        f"({config.latency_duration_s}s, c={config.latency_concurrency})..."
    )
    latency = _run_hey(
        instance_id=instance_id,
        region=region,
        fqdn=config.fqdn,
        duration_s=config.latency_duration_s,
        concurrency=config.latency_concurrency,
    )
    print(
        f"    p50={format_ms(latency.p50_ms)} "
        f"p95={format_ms(latency.p95_ms)} "
        f"p99={format_ms(latency.p99_ms)} "
        f"rps={latency.rps:.1f}"
    )

    print(f"  [{name}] max-RPS ({config.rps_duration_s}s, c={config.rps_concurrency})...")
    max_rps = _run_hey(
        instance_id=instance_id,
        region=region,
        fqdn=config.fqdn,
        duration_s=config.rps_duration_s,
        concurrency=config.rps_concurrency,
    )
    print(
        f"    rps={max_rps.rps:.1f} "
        f"p95={format_ms(max_rps.p95_ms)} "
        f"p99={format_ms(max_rps.p99_ms)}"
    )
    return ScenarioResult(name=name, latency=latency, max_rps=max_rps)


# Route swap (poll, do not sleep a fixed duration)


def _current_default_route(ec2, rt_id: str) -> dict:
    rt = ec2.describe_route_tables(RouteTableIds=[rt_id])["RouteTables"][0]
    for route in rt["Routes"]:
        if route.get("DestinationCidrBlock") == "0.0.0.0/0":
            return route
    raise RuntimeError(f"no 0.0.0.0/0 route in {rt_id}")


def _route_matches(route: dict, *, eni_id: str | None, vpce_id: str | None) -> bool:
    if eni_id is not None and route.get("NetworkInterfaceId") == eni_id:
        return True
    if vpce_id is not None and route.get("GatewayId") == vpce_id:
        # ANF endpoints can surface as GatewayId="vpce-..." here.
        return True
    if vpce_id is not None and route.get("VpcEndpointId") == vpce_id:
        return True
    return False


def _swap_to_vpce(ec2, rt_id: str, vpce_id: str, *, config: RuntimeConfig) -> None:
    ec2.replace_route(
        RouteTableId=rt_id,
        DestinationCidrBlock="0.0.0.0/0",
        VpcEndpointId=vpce_id,
    )
    _poll_until(ec2, rt_id, vpce_id=vpce_id, eni_id=None, config=config)


def _swap_to_eni(ec2, rt_id: str, eni_id: str, *, config: RuntimeConfig) -> None:
    ec2.replace_route(
        RouteTableId=rt_id,
        DestinationCidrBlock="0.0.0.0/0",
        NetworkInterfaceId=eni_id,
    )
    _poll_until(ec2, rt_id, vpce_id=None, eni_id=eni_id, config=config)


def _poll_until(
    ec2,
    rt_id: str,
    *,
    eni_id: str | None,
    vpce_id: str | None,
    config: RuntimeConfig,
) -> None:
    deadline = time.monotonic() + config.route_swap_timeout_s
    last = None
    while time.monotonic() < deadline:
        route = _current_default_route(ec2, rt_id)
        last = route
        if _route_matches(route, eni_id=eni_id, vpce_id=vpce_id):
            return
        time.sleep(config.route_poll_interval_s)
    raise TimeoutError(
        f"route on {rt_id} did not reflect swap within {config.route_swap_timeout_s}s "
        f"(last seen: {last!r})"
    )


# Reporting


# HEAD requests have no response body, so hey's `Total data:` is absent
# (parsed as 0) and we cannot sum actual wire bytes. Estimate from request
# count instead: each request triggers a TCP+TLS handshake + request/response
# headers, about 8 KB on the wire, both inbound and outbound, crossing ANF + NAT
# in each direction. This is a rough ballpark: fine for "did the run stay
# under a dollar?" but not for billing.
BYTES_PER_REQUEST = 8 * 1024 * 2  # ~8 KB each way


def estimate_cost_usd(scenarios: list[ScenarioResult]) -> float:
    total_requests = sum(
        scenario.latency.total_requests + scenario.max_rps.total_requests
        for scenario in scenarios
    )
    gb = (total_requests * BYTES_PER_REQUEST) / (1024**3)
    return gb * (ANF_USD_PER_GB + NAT_USD_PER_GB)


def write_report(out_dir: Path, scenarios: list[ScenarioResult], config: RuntimeConfig) -> None:
    if config.fqdn is None:
        raise RuntimeError("benchmark target FQDN is not set")

    out_dir.mkdir(parents=True, exist_ok=True)
    raw = {
        "fqdn": config.fqdn,
        "config": {
            "latency": {
                "duration_s": config.latency_duration_s,
                "concurrency": config.latency_concurrency,
            },
            "rps": {
                "duration_s": config.rps_duration_s,
                "concurrency": config.rps_concurrency,
            },
            "route_swap": {
                "timeout_s": config.route_swap_timeout_s,
                "poll_interval_s": config.route_poll_interval_s,
            },
        },
        "scenarios": [
            {
                "name": scenario.name,
                "latency": asdict(scenario.latency),
                "max_rps": asdict(scenario.max_rps),
            }
            for scenario in scenarios
        ],
        "estimated_cost_usd": estimate_cost_usd(scenarios),
    }
    (out_dir / "raw.json").write_text(
        json.dumps(json_safe(raw), indent=2, ensure_ascii=False, allow_nan=False),
        encoding="utf-8",
    )

    by_name = {scenario.name: scenario for scenario in scenarios}
    proxy = by_name.get("proxy")
    baseline = by_name.get("baseline")
    added_p50 = added_p95 = added_p99 = float("nan")
    if proxy and baseline:
        added_p50 = proxy.latency.p50_ms - baseline.latency.p50_ms
        added_p95 = proxy.latency.p95_ms - baseline.latency.p95_ms
        added_p99 = proxy.latency.p99_ms - baseline.latency.p99_ms

    cost = estimate_cost_usd(scenarios)
    lines = [
        "# Benchmark summary",
        "",
        f"- Target: `https://{config.fqdn}` (HEAD)",
        f"- Latency probe: {config.latency_duration_s}s at c={config.latency_concurrency}",
        f"- Max RPS probe: {config.rps_duration_s}s at c={config.rps_concurrency}",
        f"- Estimated data-processing cost this run: **${cost:.4f}** "
        f"(ANF ${ANF_USD_PER_GB}/GB + NAT ${NAT_USD_PER_GB}/GB)",
        "",
        "## Latency probe (low concurrency)",
        "",
        "| scenario | p50 ms | p95 ms | p99 ms | rps |",
        "|---|---:|---:|---:|---:|",
    ]
    for scenario in scenarios:
        lines.append(
            f"| {scenario.name} | {scenario.latency.p50_ms:.1f} | "
            f"{scenario.latency.p95_ms:.1f} | {scenario.latency.p99_ms:.1f} | "
            f"{scenario.latency.rps:.1f} |"
        )
    lines += [
        "",
        f"**Added latency (proxy - baseline):** p50 {format_ms(added_p50, signed=True)}, "
        f"p95 {format_ms(added_p95, signed=True)}, "
        f"p99 {format_ms(added_p99, signed=True)}",
        "",
        "## Max RPS (high concurrency)",
        "",
        "| scenario | rps | p95 ms | p99 ms |",
        "|---|---:|---:|---:|",
    ]
    for scenario in scenarios:
        lines.append(
            f"| {scenario.name} | {scenario.max_rps.rps:.1f} | "
            f"{scenario.max_rps.p95_ms:.1f} | {scenario.max_rps.p99_ms:.1f} |"
        )
    (out_dir / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--config",
        type=Path,
        help="Optional UTF-8 YAML file with benchmark settings.",
    )
    parser.add_argument(
        "--fqdn",
        help="Target FQDN (must be in allowed_fqdns). Overrides fqdn in --config.",
    )
    parser.add_argument(
        "--results-dir",
        type=Path,
        help="Where to write results/<UTC-timestamp>/. Overrides results_dir in --config.",
    )
    args = parser.parse_args()

    try:
        config = load_config(args.config)
    except (OSError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    outputs = load_tf_outputs()
    config = replace(
        config,
        fqdn=args.fqdn or config.fqdn or outputs["allowed_fqdns"][0],
        results_dir=args.results_dir or config.results_dir,
    )

    ec2 = boto3.client("ec2", region_name=outputs["aws_region"])

    # Sanity-check hey is baked into the AMI. Do not try to install at runtime.
    probe = ssm_exec(
        outputs["workload_instance_id"],
        "command -v hey",
        region=outputs["aws_region"],
        timeout_seconds=30,
    )
    if probe.exit_code != 0:
        print(
            "ERROR: `hey` not found on workload. Rebuild the AMI: "
            "`cd packer/workload && packer build .`, then `terraform apply`.",
            file=sys.stderr,
        )
        return 2

    print(
        f"Target: https://{config.fqdn}  "
        f"(region {outputs['aws_region']}, workload {outputs['workload_instance_id']})"
    )

    scenarios: list[ScenarioResult] = []

    print("Scenario 1/2: proxy in path")
    scenarios.append(
        run_scenario(
            name="proxy",
            instance_id=outputs["workload_instance_id"],
            region=outputs["aws_region"],
            config=config,
        )
    )

    print("Swapping workload default route to ANF endpoint (no-proxy baseline)...")
    original_route = _current_default_route(ec2, outputs["workload_route_table_id"])
    try:
        _swap_to_vpce(
            ec2,
            outputs["workload_route_table_id"],
            outputs["anf_endpoint_id"],
            config=config,
        )
        print("Scenario 2/2: baseline (no proxy)")
        scenarios.append(
            run_scenario(
                name="baseline",
                instance_id=outputs["workload_instance_id"],
                region=outputs["aws_region"],
                config=config,
            )
        )
    finally:
        print("Restoring workload default route to proxy ENI...")
        try:
            _swap_to_eni(
                ec2,
                outputs["workload_route_table_id"],
                outputs["proxy_eni_id"],
                config=config,
            )
        except (ClientError, TimeoutError) as exc:
            print(
                f"\nFAILED to restore route automatically: {exc!r}\n"
                f"Run this manually to recover:\n"
                f"  aws ec2 replace-route --region {outputs['aws_region']} "
                f"--route-table-id {outputs['workload_route_table_id']} "
                f"--destination-cidr-block 0.0.0.0/0 "
                f"--network-interface-id {outputs['proxy_eni_id']}\n"
                f"Original route was: {original_route!r}",
                file=sys.stderr,
            )
            raise

    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_dir = config.results_dir / ts
    write_report(out_dir, scenarios, config)
    print(f"\nWrote {out_dir / 'summary.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
