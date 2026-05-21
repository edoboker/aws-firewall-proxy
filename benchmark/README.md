# benchmark

Measures **added latency** introduced by the transparent SNI proxy and the
**max sustained RPS** the current single-AZ nginx proxy can serve for an
allowed HTTPS FQDN.

## Scope (read this first)

This benchmark is **deliberately small and partial.** Its purpose is to
showcase methodology and produce a representative number — not to
exhaustively characterize nginx-stream throughput, the ANF data plane,
or NAT GW. The narrow scope is a **cost decision**, not a technical one.

Concretely, each run holds the following constant:

- 1 target FQDN, 1 AZ, 1 proxy instance, 1 client instance
- HEAD requests only (headers-only payloads ≈ a few hundred bytes each)
- 20 s latency probe at c=4, plus 30 s max-RPS run at c=50
- Estimated data through ANF+NAT per run: under ~200 MB → < $0.03 in
  data-processing charges (excludes EC2 instance-hours, which exist
  whether or not the benchmark runs)

A production-grade benchmark would expand every one of those dimensions
(longer durations, multiple AZs, multiple target FQDNs, mixed payload
sizes, hot/cold cache split — see `steering/production-grade-plan.md` §3).
That work is intentionally deferred to keep total spend per run under ~$0.10
in this take-home environment.

## What it measures

Two scenarios, run back to back against the same target:

1. `proxy` — current routing: workload → nginx proxy → ANF → NAT → internet
2. `baseline` — workload's default route is repointed at the ANF VPC
   endpoint directly, removing the proxy hop: workload → ANF → NAT →
   internet

`added_latency = proxy.latency − baseline.latency` (reported at p50/p95/p99).
`max_rps_proxy` is the second scenario's high-concurrency throughput number.

## How it works

`run.py` runs on the operator's laptop. It:

1. Loads `terraform output -json` via the shared helper in `common/`.
2. Sanity-checks that `hey` is on the workload (it's baked into the
   `aws-firewall-proxy-workload` AMI). Fails fast if missing.
3. Runs `hey -m HEAD -z … -c …` on the workload via SSM Run Command.
4. Calls `ec2:ReplaceRoute` to swap the workload default route from the
   proxy ENI to the ANF VPC endpoint. **Polls** `describe-route-tables`
   until the change is reflected — no fixed sleeps.
5. Reruns `hey` for the baseline scenario.
6. Restores the route to the proxy ENI in a `try/finally`. If the restore
   fails for any reason, prints the exact `aws ec2 replace-route` command
   needed for manual recovery.
7. Writes `results/<UTC-timestamp>/raw.json` and `summary.md`.

## Prerequisites

- `terraform apply` in `../terraform/` has succeeded, and the `workload`
  instance is running the workload golden AMI (with `hey` baked in).
  Build that AMI once:
  ```bash
  cd packer/workload
  packer init . && packer build -var "git_sha=$(git rev-parse --short HEAD)" .
  cd ../../terraform && terraform apply
  ```
- AWS credentials with `ssm:SendCommand`, `ssm:GetCommandInvocation`,
  `ec2:DescribeRouteTables`, `ec2:ReplaceRoute`.
- Python deps from the repo root: `pip install -e .` (installs the
  `common` package plus `boto3`).

## Run

```bash
python benchmark/run.py
# or: python benchmark/run.py --fqdn google.com --results-dir ./out
```

Results land in `benchmark/results/<UTC-timestamp>/{raw.json,summary.md}`.

## Recovery — if the script crashes mid-run

The `try/finally` should always restore the route. If it doesn't (e.g. the
process is killed between the swap and the restore), the workload will have
no egress through the proxy. Restore manually:

```bash
aws ec2 replace-route \
  --region "$(terraform -chdir=terraform output -raw aws_region)" \
  --route-table-id "$(terraform -chdir=terraform output -raw workload_route_table_id)" \
  --destination-cidr-block 0.0.0.0/0 \
  --network-interface-id "$(terraform -chdir=terraform output -raw proxy_eni_id)"
```

## Files

- `run.py` — orchestrator
- `results/.gitignore` — ignore generated runs; sample is committed
- `results/sample/summary.md` — small example of the report format
