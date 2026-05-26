# workload_bench

Sweeps increasing load against the transparent SNI nginx proxy and shows how
its throughput and latency hold up as concurrency grows. For each concurrency
step it runs `hey` against an allowed HTTPS FQDN and records requests/sec and
p50/p95/p99 latency, then plots the sweep.

## Scope

This benchmark is deliberately small and partial. Its job is to demonstrate
methodology and produce representative numbers, not to exhaustively
characterize nginx-stream throughput, the ANF data plane, or NAT Gateway.

Each run holds the following constant by default:

- 1 target FQDN, 1 AZ, 1 proxy instance, 1 client instance
- HEAD requests only
- 5 s per step, concurrency swept over 25, 50, 100, 200, 400, 800
- Estimated data through ANF+NAT stays well under a dollar per run (the script
  prints the estimate)

A production-grade benchmark would expand every one of those dimensions
(longer durations, multiple AZs, multiple FQDNs, mixed payload sizes, and a
hot/cold cache split). That work is intentionally deferred in this repo to keep
the benchmark cheap to run.

## What it measures

The path is always `workload -> nginx proxy -> ANF -> NAT -> internet`. The only
variable that changes between steps is concurrency (`hey -c`), with the duration
fixed, so each step pushes more concurrent requests and more total traffic than
the last. For every step the script records:

- `rps` — sustained requests/sec
- `p50_ms`, `p95_ms`, `p99_ms` — latency percentiles
- `total_requests`

## How it works

`run.py` runs on the operator workstation. It:

1. Loads `terraform output -json` via the shared helper in `common/`.
2. Verifies that `hey` is already baked into the workload AMI.
3. For each concurrency step, runs `hey -m HEAD -z <duration>s -c <step>` on the
   workload through SSM Run Command and parses the result.
4. Writes `results/<UTC-timestamp>/{raw.json,summary.md,load.png}` in UTF-8.

No route swapping is involved — the proxy stays in path throughout.

## Prerequisites

- `terraform apply` in `../../terraform/` has succeeded, and the workload
  instance is running the workload golden AMI with `hey` baked in. Build that
  AMI once:
  ```bash
  cd packer/workload
  packer init .
  packer build -var "git_sha=$(git rev-parse --short HEAD)" .
  cd ../../terraform
  terraform apply
  ```
- AWS credentials with `ssm:SendCommand` and `ssm:GetCommandInvocation`.
- Python deps from the repo root: `pip install -e .` (installs `boto3` and the
  shared `common` package), plus `matplotlib` for the plot
  (`pip install -e ".[benchmark]"`). Without matplotlib the run still writes
  `raw.json` and `summary.md`, just no PNG.

## Run

```bash
python benchmark/workload_bench/run.py
python benchmark/workload_bench/run.py --steps 10,50,100 --duration 10
python benchmark/workload_bench/run.py --fqdn google.com --results-dir ./out
```

Flags:

- `--steps` — comma-separated concurrency levels to sweep (default
  `25,50,100,200,400,800`).
- `--duration` — seconds `hey` runs per step (default `5`).
- `--fqdn` — target FQDN; must be in `allowed_fqdns`. Defaults to the first
  allowed FQDN from the terraform outputs.
- `--results-dir` — where to write `results/<UTC-timestamp>/`.

## Outputs

Results land in `benchmark/workload_bench/results/<UTC-timestamp>/`:

- `raw.json` — per-step rps, latency percentiles, request counts, cost estimate
- `summary.md` — table of concurrency vs rps/latency
- `load.png` — throughput and p50/p95/p99 latency vs concurrency

## Files

- `run.py`: orchestrator
- `results/.gitignore`: ignores generated benchmark runs
- `results/sample/`: small example of the report format (`summary.md` + `load.png`)
