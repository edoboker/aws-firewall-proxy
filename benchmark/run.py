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
import re
import sys
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path

import boto3
from botocore.exceptions import ClientError

from common.ssm import ssm_exec
from common.tf_outputs import load as load_tf_outputs

# ── Knobs ────────────────────────────────────────────────────────────────────
# Both phases use `hey -m HEAD` so per-request bytes are headers-only
# (~few hundred bytes). With the defaults below, total bytes through ANF+NAT
# per run stay well under 200 MB → < $0.03 in data-processing charges.
LATENCY_DURATION_S = 20
LATENCY_CONCURRENCY = 4
RPS_DURATION_S = 30
RPS_CONCURRENCY = 50

# Per-GB data-processing prices used to estimate the run's $ cost. These are
# rough public-pricing constants for cost ballpark only — not a billing source
# of truth. Update if AWS changes prices.
ANF_USD_PER_GB = 0.065
NAT_USD_PER_GB = 0.045

ROUTE_SWAP_TIMEOUT_S = 30
ROUTE_POLL_INTERVAL_S = 1.0


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


# ── hey output parsing ───────────────────────────────────────────────────────
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
    # HEAD requests have no body, so hey omits "Total data:" — treat as 0.
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


# ── hey driver ───────────────────────────────────────────────────────────────


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
    *, name: str, instance_id: str, region: str, fqdn: str
) -> ScenarioResult:
    print(f"  [{name}] latency probe ({LATENCY_DURATION_S}s, c={LATENCY_CONCURRENCY})...")
    latency = _run_hey(
        instance_id=instance_id,
        region=region,
        fqdn=fqdn,
        duration_s=LATENCY_DURATION_S,
        concurrency=LATENCY_CONCURRENCY,
    )
    print(
        f"    p50={latency.p50_ms:.1f}ms p95={latency.p95_ms:.1f}ms "
        f"p99={latency.p99_ms:.1f}ms rps={latency.rps:.1f}"
    )
    print(f"  [{name}] max-RPS ({RPS_DURATION_S}s, c={RPS_CONCURRENCY})...")
    max_rps = _run_hey(
        instance_id=instance_id,
        region=region,
        fqdn=fqdn,
        duration_s=RPS_DURATION_S,
        concurrency=RPS_CONCURRENCY,
    )
    print(
        f"    rps={max_rps.rps:.1f} p95={max_rps.p95_ms:.1f}ms "
        f"p99={max_rps.p99_ms:.1f}ms"
    )
    return ScenarioResult(name=name, latency=latency, max_rps=max_rps)


# ── route swap (poll, don't sleep) ───────────────────────────────────────────


def _current_default_route(ec2, rt_id: str) -> dict:
    rt = ec2.describe_route_tables(RouteTableIds=[rt_id])["RouteTables"][0]
    for r in rt["Routes"]:
        if r.get("DestinationCidrBlock") == "0.0.0.0/0":
            return r
    raise RuntimeError(f"no 0.0.0.0/0 route in {rt_id}")


def _route_matches(route: dict, *, eni_id: str | None, vpce_id: str | None) -> bool:
    if eni_id is not None and route.get("NetworkInterfaceId") == eni_id:
        return True
    if vpce_id is not None and route.get("GatewayId") == vpce_id:
        # ANF endpoints surface as GatewayId="vpce-..." in describe_route_tables
        return True
    if vpce_id is not None and route.get("VpcEndpointId") == vpce_id:
        return True
    return False


def _swap_to_vpce(ec2, rt_id: str, vpce_id: str) -> None:
    ec2.replace_route(
        RouteTableId=rt_id,
        DestinationCidrBlock="0.0.0.0/0",
        VpcEndpointId=vpce_id,
    )
    _poll_until(ec2, rt_id, vpce_id=vpce_id, eni_id=None)


def _swap_to_eni(ec2, rt_id: str, eni_id: str) -> None:
    ec2.replace_route(
        RouteTableId=rt_id,
        DestinationCidrBlock="0.0.0.0/0",
        NetworkInterfaceId=eni_id,
    )
    _poll_until(ec2, rt_id, vpce_id=None, eni_id=eni_id)


def _poll_until(ec2, rt_id: str, *, eni_id: str | None, vpce_id: str | None) -> None:
    deadline = time.monotonic() + ROUTE_SWAP_TIMEOUT_S
    last = None
    while time.monotonic() < deadline:
        route = _current_default_route(ec2, rt_id)
        last = route
        if _route_matches(route, eni_id=eni_id, vpce_id=vpce_id):
            return
        time.sleep(ROUTE_POLL_INTERVAL_S)
    raise TimeoutError(
        f"route on {rt_id} did not reflect swap within {ROUTE_SWAP_TIMEOUT_S}s "
        f"(last seen: {last!r})"
    )


# ── reporting ────────────────────────────────────────────────────────────────


# HEAD requests have no response body, so hey's `Total data:` is absent
# (parsed as 0) and we can't sum actual wire bytes. Estimate from request
# count instead: each request triggers a TCP+TLS handshake + request/response
# headers ≈ ~8 KB on the wire, both inbound and outbound, crossing ANF + NAT
# in each direction. This is a rough ballpark — fine for "did the run stay
# under a dollar?" but not for billing.
BYTES_PER_REQUEST = 8 * 1024 * 2  # ~8 KB each way


def estimate_cost_usd(scenarios: list[ScenarioResult]) -> float:
    total_requests = sum(
        s.latency.total_requests + s.max_rps.total_requests for s in scenarios
    )
    gb = (total_requests * BYTES_PER_REQUEST) / (1024**3)
    return gb * (ANF_USD_PER_GB + NAT_USD_PER_GB)


def write_report(out_dir: Path, scenarios: list[ScenarioResult], fqdn: str) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    raw = {
        "fqdn": fqdn,
        "scenarios": [
            {
                "name": s.name,
                "latency": asdict(s.latency),
                "max_rps": asdict(s.max_rps),
            }
            for s in scenarios
        ],
        "estimated_cost_usd": estimate_cost_usd(scenarios),
    }
    (out_dir / "raw.json").write_text(json.dumps(raw, indent=2))

    by_name = {s.name: s for s in scenarios}
    proxy = by_name.get("proxy")
    baseline = by_name.get("baseline")
    added_p50 = added_p95 = added_p99 = float("nan")
    if proxy and baseline:
        added_p50 = proxy.latency.p50_ms - baseline.latency.p50_ms
        added_p95 = proxy.latency.p95_ms - baseline.latency.p95_ms
        added_p99 = proxy.latency.p99_ms - baseline.latency.p99_ms

    cost = estimate_cost_usd(scenarios)
    lines = [
        f"# Benchmark summary",
        "",
        f"- Target: `https://{fqdn}` (HEAD)",
        f"- Estimated data-processing cost this run: **${cost:.4f}** "
        f"(ANF ${ANF_USD_PER_GB}/GB + NAT ${NAT_USD_PER_GB}/GB)",
        "",
        "## Latency probe (low concurrency)",
        "",
        "| scenario | p50 ms | p95 ms | p99 ms | rps |",
        "|---|---:|---:|---:|---:|",
    ]
    for s in scenarios:
        lines.append(
            f"| {s.name} | {s.latency.p50_ms:.1f} | {s.latency.p95_ms:.1f} | "
            f"{s.latency.p99_ms:.1f} | {s.latency.rps:.1f} |"
        )
    lines += [
        "",
        f"**Added latency (proxy − baseline):** p50 {added_p50:+.1f} ms, "
        f"p95 {added_p95:+.1f} ms, p99 {added_p99:+.1f} ms",
        "",
        "## Max RPS (high concurrency)",
        "",
        "| scenario | rps | p95 ms | p99 ms |",
        "|---|---:|---:|---:|",
    ]
    for s in scenarios:
        lines.append(
            f"| {s.name} | {s.max_rps.rps:.1f} | "
            f"{s.max_rps.p95_ms:.1f} | {s.max_rps.p99_ms:.1f} |"
        )
    (out_dir / "summary.md").write_text("\n".join(lines) + "\n")


# ── entrypoint ───────────────────────────────────────────────────────────────


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--fqdn",
        help="Target FQDN (must be in allowed_fqdns). Defaults to first entry.",
    )
    parser.add_argument(
        "--results-dir",
        type=Path,
        default=Path(__file__).parent / "results",
        help="Where to write results/<UTC-timestamp>/.",
    )
    args = parser.parse_args()

    outputs = load_tf_outputs()
    region = outputs["aws_region"]
    workload_id = outputs["workload_instance_id"]
    rt_id = outputs["workload_route_table_id"]
    proxy_eni = outputs["proxy_eni_id"]
    anf_vpce = outputs["anf_endpoint_id"]
    fqdn = args.fqdn or outputs["allowed_fqdns"][0]

    ec2 = boto3.client("ec2", region_name=region)

    # Sanity-check hey is baked into the AMI. Don't try to install at runtime.
    probe = ssm_exec(workload_id, "command -v hey", region=region, timeout_seconds=30)
    if probe.exit_code != 0:
        print(
            "ERROR: `hey` not found on workload. Rebuild the AMI: "
            "`cd packer/workload && packer build .`, then `terraform apply`.",
            file=sys.stderr,
        )
        return 2

    print(f"Target: https://{fqdn}  (region {region}, workload {workload_id})")

    scenarios: list[ScenarioResult] = []

    print("Scenario 1/2: proxy in path")
    scenarios.append(
        run_scenario(name="proxy", instance_id=workload_id, region=region, fqdn=fqdn)
    )

    print("Swapping workload default route to ANF endpoint (no-proxy baseline)...")
    original_route = _current_default_route(ec2, rt_id)
    try:
        _swap_to_vpce(ec2, rt_id, anf_vpce)
        print("Scenario 2/2: baseline (no proxy)")
        scenarios.append(
            run_scenario(
                name="baseline", instance_id=workload_id, region=region, fqdn=fqdn
            )
        )
    finally:
        print("Restoring workload default route to proxy ENI...")
        try:
            _swap_to_eni(ec2, rt_id, proxy_eni)
        except (ClientError, TimeoutError) as e:
            print(
                f"\nFAILED to restore route automatically: {e!r}\n"
                f"Run this manually to recover:\n"
                f"  aws ec2 replace-route --region {region} "
                f"--route-table-id {rt_id} "
                f"--destination-cidr-block 0.0.0.0/0 "
                f"--network-interface-id {proxy_eni}\n"
                f"Original route was: {original_route!r}",
                file=sys.stderr,
            )
            raise

    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_dir = args.results_dir / ts
    write_report(out_dir, scenarios, fqdn)
    print(f"\nWrote {out_dir / 'summary.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
