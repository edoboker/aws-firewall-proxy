"""Ruleset-generator Lambda scaling benchmark.

Measures how long the ruleset-generator Lambda
(terraform/lambda_ruleset_generator.tf) takes to resolve a growing set of FQDNs
and republish managed prefix lists.

For each step in --steps (default 10, 50, 100, 150, 200, 250, 300):

  1. Update the lambda's `FQDNS` environment variable to the first N curated
     domains (via UpdateFunctionConfiguration -- no terraform, no tfvars edit).
  2. Invoke the lambda synchronously and record its execution time, taken from
     the CloudWatch `REPORT ... Duration:` line (falls back to client wall
     clock if that can't be parsed).

The lambda's original configuration (env vars + timeout) is captured up front
and restored in a `finally`, including one final invoke so the live firewall
prefix list returns to its original allow-set.

Outputs land in results/<UTC-timestamp>/{raw.json,summary.md,scaling.png}.

Sizing / cost notes:
- Each FQDN publishes at most --addresses-per-fqdn IPv4 /32s (default 1), so
  the prefix list stays small and well under AWS limits. The list's max_entries
  is raised once if needed and never shrunk mid-run.
- The lambda timeout is raised to 300s for the run (300 FQDNs resolved
  sequentially exceed the 30s default).
"""

from __future__ import annotations

import argparse
import base64
import json
import re
import sys
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path

import boto3
from botocore.exceptions import ClientError

# Make `common` and the sibling `domains` module importable when run as a
# script from anywhere.
REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from common.tf_outputs import load as load_tf_outputs  # noqa: E402
from domains import DOMAINS  # noqa: E402

RESULTS_DIR = Path(__file__).resolve().parent / "results"

DEFAULT_STEPS = [10, 50, 100, 150, 200, 250, 300]
DEFAULT_ADDRESSES_PER_FQDN = 1
BENCH_LAMBDA_TIMEOUT_S = 300  # well above the 30s default; 300 FQDNs are slow

# AWS default Service Quota for entries in a single managed prefix list. It is
# adjustable on request; above it you need an increase, so we only *warn*.
DEFAULT_MAX_ENTRIES = 1000
# The lambda slices ips[:MAX_ADDRESSES_PER_FQDN]; terraform validates this var
# to 1..64, so 64 effectively means "every A-record the resolver returns".
MAX_ADDRESSES_CAP = 64

_REPORT_DURATION_RE = re.compile(r"\bDuration:\s+([\d.]+)\s+ms")


@dataclass
class StepResult:
    n_fqdns: int
    invoke_wall_s: float
    lambda_report_ms: float | None
    entry_count: int | None
    ok: bool
    error: str | None


def unique_domains() -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for d in DOMAINS:
        d = d.strip().lower().rstrip(".")
        if d and d not in seen:
            seen.add(d)
            out.append(d)
    return out


def set_env(lambda_client, fn_name: str, variables: dict[str, str]) -> None:
    """Replace the lambda env vars and block until the update settles."""
    lambda_client.update_function_configuration(
        FunctionName=fn_name,
        Environment={"Variables": variables},
    )
    lambda_client.get_waiter("function_updated").wait(FunctionName=fn_name)


def set_timeout(lambda_client, fn_name: str, timeout_s: int) -> None:
    lambda_client.update_function_configuration(FunctionName=fn_name, Timeout=timeout_s)
    lambda_client.get_waiter("function_updated").wait(FunctionName=fn_name)


def _describe_prefix_list(ec2, prefix_list_id: str) -> dict:
    return ec2.describe_managed_prefix_lists(PrefixListIds=[prefix_list_id])["PrefixLists"][0]


def wait_prefix_list_stable(ec2, prefix_list_id: str, after_version: int | None = None, timeout_s: int = 120) -> int:
    """Block until the managed prefix list is `-complete`, returning its Version.

    Each modify puts the list into `modify-in-progress`; AWS rejects the next
    ModifyManagedPrefixList until it settles. We use a *scratch* list that
    nothing references, so this settles in seconds (a list wired into the ANF
    rule group instead stays in-progress for minutes while the firewall
    re-consumes it).

    `State` is eventually consistent and can briefly still report the *prior*
    `-complete` before a just-issued modify flips it to in-progress. So when
    `after_version` is given, we also require Version > after_version, which
    only advances once the modify has actually been accepted -- this closes the
    race where a stale `-complete` lets the next modify start too early.
    """
    deadline = time.monotonic() + timeout_s
    while True:
        pl = _describe_prefix_list(ec2, prefix_list_id)
        state, version = pl["State"], pl["Version"]
        settled = state.endswith("-complete") and (after_version is None or version > after_version)
        if settled:
            return version
        if state.endswith("-failed"):
            raise RuntimeError(f"prefix list {prefix_list_id} entered state {state}")
        if time.monotonic() >= deadline:
            raise TimeoutError(
                f"prefix list {prefix_list_id} not settled after {timeout_s}s "
                f"(state={state}, version={version}, waiting for > {after_version})"
            )
        time.sleep(2)


def create_scratch_prefix_list(ec2, name: str, max_entries: int) -> str:
    """Create an empty, unreferenced IPv4 prefix list for the benchmark."""
    pl = ec2.create_managed_prefix_list(
        PrefixListName=name,
        MaxEntries=max_entries,
        AddressFamily="IPv4",
        TagSpecifications=[{"ResourceType": "prefix-list", "Tags": [{"Key": "purpose", "Value": "ruleset_generator_bench"}]}],
    )["PrefixList"]
    prefix_list_id = pl["PrefixListId"]
    wait_prefix_list_stable(ec2, prefix_list_id)
    return prefix_list_id


def delete_scratch_prefix_list(ec2, prefix_list_id: str) -> None:
    wait_prefix_list_stable(ec2, prefix_list_id)
    ec2.delete_managed_prefix_list(PrefixListId=prefix_list_id)


def parse_report_ms(log_b64: str | None) -> float | None:
    if not log_b64:
        return None
    text = base64.b64decode(log_b64).decode("utf-8", errors="replace")
    matches = _REPORT_DURATION_RE.findall(text)
    return float(matches[-1]) if matches else None


def invoke_and_time(lambda_client, fn_name: str) -> tuple[float, float | None, int | None, str | None]:
    """Synchronous invoke. Returns (wall_s, report_ms, entry_count, error)."""
    start = time.monotonic()
    resp = lambda_client.invoke(
        FunctionName=fn_name,
        InvocationType="RequestResponse",
        LogType="Tail",
    )
    wall_s = time.monotonic() - start

    report_ms = parse_report_ms(resp.get("LogResult"))
    raw_payload = resp["Payload"].read().decode("utf-8", errors="replace")

    if resp.get("FunctionError"):
        msg = raw_payload
        try:
            msg = json.loads(raw_payload).get("errorMessage", raw_payload)
        except json.JSONDecodeError:
            pass
        return wall_s, report_ms, None, msg

    entry_count = None
    try:
        entry_count = json.loads(raw_payload).get("entry_count")
    except json.JSONDecodeError:
        pass
    return wall_s, report_ms, entry_count, None


def run_step(lambda_client, ec2, prefix_list_id: str, fn_name: str, base_vars: dict[str, str], n: int) -> StepResult:
    fqdns = unique_domains()[:n]
    print(f"\n=== {n} FQDNs ===")
    variables = dict(base_vars)
    variables["FQDNS"] = json.dumps(fqdns)
    set_env(lambda_client, fn_name, variables)

    # The scratch list must be settled before the lambda's ModifyManagedPrefixList.
    # Capture the version so we can confirm the lambda's modify actually landed.
    version = wait_prefix_list_stable(ec2, prefix_list_id)
    wall_s, report_ms, entry_count, error = invoke_and_time(lambda_client, fn_name)
    if not error:
        version = wait_prefix_list_stable(ec2, prefix_list_id, after_version=version)
    else:
        # One cheap retry for a transient hiccup. Wait for the list to settle
        # first, in case the failure left a modify in progress.
        print(f"  invoke error: {error.strip()[:200]} -- retrying once")
        version = wait_prefix_list_stable(ec2, prefix_list_id)
        wall_s, report_ms, entry_count, error = invoke_and_time(lambda_client, fn_name)
        if not error:
            wait_prefix_list_stable(ec2, prefix_list_id, after_version=version)

    if error:
        print(f"  FAILED: {error.strip()[:200]}")
    else:
        shown = f"{report_ms:.0f} ms (lambda)" if report_ms is not None else f"{wall_s * 1000:.0f} ms (wall)"
        print(f"  ok: {shown}, {entry_count} prefix-list entries")

    return StepResult(
        n_fqdns=n,
        invoke_wall_s=round(wall_s, 3),
        lambda_report_ms=round(report_ms, 1) if report_ms is not None else None,
        entry_count=entry_count,
        ok=error is None,
        error=error.strip() if error else None,
    )


def write_outputs(out_dir: Path, results: list[StepResult], addr: int) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)

    (out_dir / "raw.json").write_text(
        json.dumps(
            {
                "addresses_per_fqdn": addr,
                "lambda_timeout_s": BENCH_LAMBDA_TIMEOUT_S,
                "steps": [asdict(r) for r in results],
            },
            indent=2,
        ),
        encoding="utf-8",
    )

    lines = [
        "# Ruleset-generator Lambda scaling benchmark",
        "",
        f"- Addresses published per FQDN: {addr}",
        f"- Lambda timeout during benchmark: {BENCH_LAMBDA_TIMEOUT_S}s",
        "",
        "| FQDNs | lambda duration | invoke wall | entries | status |",
        "|---:|---:|---:|---:|:--|",
    ]
    for r in results:
        dur = f"{r.lambda_report_ms:.0f} ms" if r.lambda_report_ms is not None else "n/a"
        entries = str(r.entry_count) if r.entry_count is not None else "-"
        status = "ok" if r.ok else f"FAIL: {(r.error or '')[:60]}"
        lines.append(
            f"| {r.n_fqdns} | {dur} | {r.invoke_wall_s * 1000:.0f} ms | {entries} | {status} |"
        )
    (out_dir / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

    _plot(out_dir, results)


def _plot(out_dir: Path, results: list[StepResult]) -> None:
    ok = [r for r in results if r.ok]
    if not ok:
        print("No successful steps to plot.")
        return
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print(
            "matplotlib not installed; skipping plot. "
            "Install with `pip install matplotlib` and re-run, or plot raw.json yourself."
        )
        return

    xs = [r.n_fqdns for r in ok]
    # Prefer lambda-reported ms; fall back to wall clock where missing.
    ys = [
        r.lambda_report_ms if r.lambda_report_ms is not None else r.invoke_wall_s * 1000
        for r in ok
    ]

    fig, ax = plt.subplots(figsize=(8, 5))
    ax.plot(xs, ys, marker="o")
    ax.set_xlabel("Number of FQDNs")
    ax.set_ylabel("Lambda execution time (ms)")
    ax.set_title("Ruleset-generator lambda: resolve + publish time vs FQDN count")
    ax.grid(True, alpha=0.3)
    for x, y in zip(xs, ys):
        ax.annotate(f"{y:.0f}", (x, y), textcoords="offset points", xytext=(0, 8), ha="center", fontsize=8)
    fig.tight_layout()
    fig.savefig(out_dir / "scaling.png", dpi=120)
    plt.close(fig)


def parse_steps(raw: str) -> list[int]:
    steps = [int(p) for p in raw.split(",") if p.strip()]
    if not steps or any(s <= 0 for s in steps):
        raise ValueError("--steps must be a comma-separated list of positive integers")
    return steps


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--steps",
        type=parse_steps,
        default=DEFAULT_STEPS,
        help="Comma-separated FQDN counts to benchmark (default: 10,50,100,150,200,250,300).",
    )
    parser.add_argument(
        "--addresses-per-fqdn",
        type=int,
        default=DEFAULT_ADDRESSES_PER_FQDN,
        help=(
            "Max IPv4 /32s published per FQDN (default: 1, which makes prefix-list "
            f"entries == FQDN count so the curve isolates FQDN count; up to {MAX_ADDRESSES_CAP} "
            "= every A-record the resolver returns)."
        ),
    )
    parser.add_argument(
        "--max-entries",
        type=int,
        default=DEFAULT_MAX_ENTRIES,
        help=(
            f"MaxEntries for the scratch prefix list (default: {DEFAULT_MAX_ENTRIES}, the AWS "
            "per-list quota). Raise only if you've been granted a Service Quotas increase."
        ),
    )
    parser.add_argument("--results-dir", type=Path, default=RESULTS_DIR)
    args = parser.parse_args()

    steps = args.steps
    addr = args.addresses_per_fqdn
    max_step = max(steps)

    if not 1 <= addr <= MAX_ADDRESSES_CAP:
        print(f"ERROR: --addresses-per-fqdn must be 1..{MAX_ADDRESSES_CAP}.", file=sys.stderr)
        return 2

    domains = unique_domains()
    if len(domains) < max_step:
        print(
            f"ERROR: only {len(domains)} unique domains available but the largest "
            f"step needs {max_step}. Add more to domains.py.",
            file=sys.stderr,
        )
        return 2

    # Worst case: every FQDN yields the full --addresses-per-fqdn. The prefix
    # list must be able to hold that, or the lambda's modify fails mid-run.
    needed_entries = max_step * addr
    if needed_entries > args.max_entries:
        print(
            f"ERROR: {max_step} FQDNs x up to {addr} addresses = up to {needed_entries} "
            f"entries, over --max-entries ({args.max_entries}). Lower --addresses-per-fqdn "
            f"or the largest step, or raise --max-entries (needs a Service Quotas increase "
            f"above {DEFAULT_MAX_ENTRIES}).",
            file=sys.stderr,
        )
        return 2
    if args.max_entries > DEFAULT_MAX_ENTRIES:
        print(
            f"NOTE: --max-entries {args.max_entries} exceeds the default per-list quota of "
            f"{DEFAULT_MAX_ENTRIES}; the create will fail unless your account quota was raised."
        )

    outputs = load_tf_outputs()
    fn_name = outputs.get("ruleset_generator_function_name")
    region = outputs.get("aws_region")
    if not fn_name:
        print(
            "ERROR: ruleset_generator_function_name output is null. "
            "Set enable_ruleset_generator = true and `terraform apply` first.",
            file=sys.stderr,
        )
        return 2

    lambda_client = boto3.client("lambda", region_name=region)
    ec2 = boto3.client("ec2", region_name=region)

    print(f"Function: {fn_name}  (region {region})")
    print(f"Steps: {steps}  addresses/fqdn: {addr}")

    # Capture the deployed config so we can put it back exactly as it was.
    cfg = lambda_client.get_function_configuration(FunctionName=fn_name)
    original_vars = dict(cfg.get("Environment", {}).get("Variables", {}))
    original_timeout = cfg["Timeout"]

    # Point the lambda at a throwaway prefix list that nothing references, so
    # each modify settles in seconds instead of waiting minutes on the ANF rule
    # group to re-consume the firewall-attached list. The real list is never
    # touched.
    scratch_name = f"ruleset-generator-bench-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}"
    print(f"Creating scratch prefix list {scratch_name} (max {needed_entries} entries)...")
    scratch_id = create_scratch_prefix_list(ec2, scratch_name, needed_entries)
    print(f"  {scratch_id}")

    # The deployed handler reads PREFIX_LIST_IDS (plural JSON array) and only
    # falls back to the singular PREFIX_LIST_ID when that's empty. Override both
    # so the lambda writes the scratch list regardless of which is in effect --
    # otherwise it keeps hitting the real, firewall-attached list.
    bench_vars = dict(original_vars)
    bench_vars["PREFIX_LIST_IDS"] = json.dumps([scratch_id])
    bench_vars["PREFIX_LIST_ID"] = scratch_id
    bench_vars["MAX_ADDRESSES_PER_FQDN"] = str(addr)

    set_timeout(lambda_client, fn_name, BENCH_LAMBDA_TIMEOUT_S)

    results: list[StepResult] = []
    try:
        for n in steps:
            results.append(run_step(lambda_client, ec2, scratch_id, fn_name, bench_vars, n))
    except (ClientError, RuntimeError, KeyboardInterrupt) as exc:
        print(f"\nAborting after error: {exc!r}", file=sys.stderr)
    finally:
        print("\nRestoring lambda configuration and deleting scratch list...")
        try:
            set_env(lambda_client, fn_name, original_vars)
            set_timeout(lambda_client, fn_name, original_timeout)
            print("  lambda env + timeout restored.")
        except ClientError as exc:
            print(f"  WARNING: could not restore lambda config: {exc!r}", file=sys.stderr)
        try:
            delete_scratch_prefix_list(ec2, scratch_id)
            print(f"  deleted {scratch_id}.")
        except (ClientError, RuntimeError, TimeoutError) as exc:
            print(
                f"  WARNING: could not delete scratch list {scratch_id}: {exc!r}\n"
                f"  Delete it manually: aws ec2 delete-managed-prefix-list "
                f"--prefix-list-id {scratch_id} --region {region}",
                file=sys.stderr,
            )

    if not results:
        return 1

    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_dir = args.results_dir / ts
    write_outputs(out_dir, results, addr)
    print(f"\nWrote {out_dir / 'summary.md'}")
    print(f"      {out_dir / 'scaling.png'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
