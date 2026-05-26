"""Proxy load-sweep benchmark.

Drives `hey` on the workload EC2 via SSM Run Command against the in-path
nginx proxy, repeating the run at increasing concurrency. Each step holds the
duration fixed and raises the number of concurrent clients, so every step
pushes more in-flight requests (and more total traffic) than the last. The
output shows how the proxy's throughput and latency hold up as load grows.

This is deliberately small (cost cap; see benchmark/README.md). It is meant
to demonstrate methodology, not exhaustively characterize the proxy.

Outputs land in results/<UTC-timestamp>/{raw.json,summary.md,load.png}.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path

import boto3

from common.ssm import ssm_exec
from common.tf_outputs import load as load_tf_outputs

RESULTS_DIR = Path(__file__).resolve().parent / "results"

# Concurrency steps swept in order, smallest to largest. Duration is fixed so
# the only growing dimension is the number of concurrent clients. The ceiling
# is deliberately high to push the single-AZ proxy toward saturation.
DEFAULT_STEPS = [25, 50, 100, 200, 400, 800]
DEFAULT_DURATION_S = 5

# Per-GB data-processing prices used to estimate the run's $ cost. Rough public
# pricing for a ballpark only, not a billing source of truth.
ANF_USD_PER_GB = 0.065
NAT_USD_PER_GB = 0.045
# HEAD requests carry no body, so hey can't report wire bytes. Estimate ~8 KB
# each way (TCP+TLS handshake + headers) crossing ANF + NAT in both directions.
BYTES_PER_REQUEST = 8 * 1024 * 2


@dataclass
class StepResult:
    concurrency: int
    rps: float
    p50_ms: float
    p95_ms: float
    p99_ms: float
    total_requests: int
    total_bytes: int


def format_ms(value: float) -> str:
    return "nan ms" if math.isnan(value) else f"{value:.1f} ms"


def json_safe(value: object) -> object:
    if isinstance(value, float) and math.isnan(value):
        return "NaN"
    if isinstance(value, dict):
        return {key: json_safe(item) for key, item in value.items()}
    if isinstance(value, list):
        return [json_safe(item) for item in value]
    return value


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


def parse_hey(raw: str, concurrency: int) -> StepResult:
    rps = float(_RPS_RE.search(raw).group(1))
    # HEAD requests have no body, so hey omits "Total data:"; treat as 0.
    bytes_m = _BYTES_RE.search(raw)
    total_bytes = int(bytes_m.group(1)) if bytes_m else 0
    pcts = {int(m.group(1)): float(m.group(2)) * 1000 for m in _PCT_RE.finditer(raw)}
    total_requests = sum(int(m.group(2)) for m in _STATUS_RE.finditer(raw))
    return StepResult(
        concurrency=concurrency,
        rps=rps,
        p50_ms=pcts.get(50, float("nan")),
        p95_ms=pcts.get(95, float("nan")),
        p99_ms=pcts.get(99, float("nan")),
        total_requests=total_requests,
        total_bytes=total_bytes,
    )


def run_step(
    *,
    instance_id: str,
    region: str,
    fqdn: str,
    duration_s: int,
    concurrency: int,
) -> StepResult:
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
    return parse_hey(result.stdout, concurrency)


# Reporting


def estimate_cost_usd(steps: list[StepResult]) -> float:
    total_requests = sum(step.total_requests for step in steps)
    gb = (total_requests * BYTES_PER_REQUEST) / (1024**3)
    return gb * (ANF_USD_PER_GB + NAT_USD_PER_GB)


def write_report(out_dir: Path, steps: list[StepResult], fqdn: str, duration_s: int) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    cost = estimate_cost_usd(steps)

    raw = {
        "fqdn": fqdn,
        "duration_s": duration_s,
        "concurrency_steps": [step.concurrency for step in steps],
        "steps": [asdict(step) for step in steps],
        "estimated_cost_usd": cost,
    }
    (out_dir / "raw.json").write_text(
        json.dumps(json_safe(raw), indent=2, ensure_ascii=False, allow_nan=False),
        encoding="utf-8",
    )

    lines = [
        "# Proxy load-sweep benchmark",
        "",
        f"- Target: `https://{fqdn}` (HEAD), through the in-path nginx proxy",
        f"- Per-step duration: {duration_s}s; concurrency swept over "
        f"{[step.concurrency for step in steps]}",
        f"- Estimated data-processing cost this run: **${cost:.4f}** "
        f"(ANF ${ANF_USD_PER_GB}/GB + NAT ${NAT_USD_PER_GB}/GB)",
        "",
        "| concurrency | rps | p50 ms | p95 ms | p99 ms | requests |",
        "|---:|---:|---:|---:|---:|---:|",
    ]
    for step in steps:
        lines.append(
            f"| {step.concurrency} | {step.rps:.1f} | {step.p50_ms:.1f} | "
            f"{step.p95_ms:.1f} | {step.p99_ms:.1f} | {step.total_requests} |"
        )
    (out_dir / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

    _plot(out_dir, steps)


def _plot(out_dir: Path, steps: list[StepResult]) -> None:
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print(
            "matplotlib not installed; skipping plot. "
            "Install with `pip install -e \".[benchmark]\"` and re-run, "
            "or plot raw.json yourself."
        )
        return

    xs = [step.concurrency for step in steps]
    fig, (ax_rps, ax_lat) = plt.subplots(2, 1, figsize=(8, 8), sharex=True)

    ax_rps.plot(xs, [step.rps for step in steps], marker="o", color="tab:blue")
    ax_rps.set_ylabel("Throughput (req/s)")
    ax_rps.set_title("nginx proxy under increasing load")
    ax_rps.grid(True, alpha=0.3)

    for pct, color in (("p50", "tab:green"), ("p95", "tab:orange"), ("p99", "tab:red")):
        ax_lat.plot(
            xs,
            [getattr(step, f"{pct}_ms") for step in steps],
            marker="o",
            color=color,
            label=pct,
        )
    ax_lat.set_xlabel("Concurrent clients")
    ax_lat.set_ylabel("Latency (ms)")
    ax_lat.legend()
    ax_lat.grid(True, alpha=0.3)

    fig.tight_layout()
    fig.savefig(out_dir / "load.png", dpi=120)
    plt.close(fig)


def parse_steps(raw: str) -> list[int]:
    steps = [int(p) for p in raw.split(",") if p.strip()]
    if not steps or any(s <= 0 for s in steps):
        raise ValueError("--steps must be a comma-separated list of positive integers")
    return steps


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--steps",
        type=parse_steps,
        default=DEFAULT_STEPS,
        help="Comma-separated concurrency levels to sweep (default: 25,50,100,200,400,800).",
    )
    parser.add_argument(
        "--duration",
        type=int,
        default=DEFAULT_DURATION_S,
        help=f"Seconds hey runs per step (default: {DEFAULT_DURATION_S}).",
    )
    parser.add_argument(
        "--fqdn",
        help="Target FQDN (must be in allowed_fqdns). Defaults to the first allowed FQDN.",
    )
    parser.add_argument("--results-dir", type=Path, default=RESULTS_DIR)
    args = parser.parse_args()

    if args.duration <= 0:
        print("ERROR: --duration must be a positive integer.", file=sys.stderr)
        return 2

    outputs = load_tf_outputs()
    region = outputs["aws_region"]
    instance_id = outputs["workload_instance_id"]
    fqdn = args.fqdn or outputs["allowed_fqdns"][0]

    # Sanity-check hey is baked into the AMI. Do not try to install at runtime.
    probe = ssm_exec(instance_id, "command -v hey", region=region, timeout_seconds=30)
    if probe.exit_code != 0:
        print(
            "ERROR: `hey` not found on workload. Rebuild the AMI: "
            "`cd packer/workload && packer build .`, then `terraform apply`.",
            file=sys.stderr,
        )
        return 2

    print(f"Target: https://{fqdn}  (region {region}, workload {instance_id})")
    print(f"Sweeping concurrency {args.steps} at {args.duration}s each")

    steps: list[StepResult] = []
    for concurrency in args.steps:
        print(f"  c={concurrency} ({args.duration}s)...")
        step = run_step(
            instance_id=instance_id,
            region=region,
            fqdn=fqdn,
            duration_s=args.duration,
            concurrency=concurrency,
        )
        steps.append(step)
        print(
            f"    rps={step.rps:.1f} p50={format_ms(step.p50_ms)} "
            f"p95={format_ms(step.p95_ms)} p99={format_ms(step.p99_ms)}"
        )

    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_dir = args.results_dir / ts
    write_report(out_dir, steps, fqdn, args.duration)
    print(f"\nWrote {out_dir / 'summary.md'}")
    print(f"      {out_dir / 'load.png'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
