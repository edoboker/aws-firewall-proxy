# benchmark

Measures the added latency introduced by the transparent SNI proxy and the
max sustained RPS the current single-AZ nginx proxy can serve for an allowed
HTTPS FQDN.

## Scope

This benchmark is deliberately small and partial. Its job is to demonstrate
methodology and produce representative numbers, not to exhaustively
characterize nginx-stream throughput, the ANF data plane, or NAT Gateway.

Each run holds the following constant by default:

- 1 target FQDN, 1 AZ, 1 proxy instance, 1 client instance
- HEAD requests only
- 5 s latency probe at c=2, plus 5 s max-RPS run at c=50
- Estimated data through ANF+NAT stays well under ~200 MB per run, which keeps data-processing charges around a few cents

A production-grade benchmark would expand every one of those dimensions
(longer durations, multiple AZs, multiple FQDNs, mixed payload sizes, and a
hot/cold cache split). That work is intentionally deferred in this repo to
keep the benchmark cheap to run.

## What it measures

Two scenarios run back to back against the same target:

1. `proxy`: workload -> nginx proxy -> ANF -> NAT -> internet
2. `baseline`: workload -> ANF -> NAT -> internet

The script reports `added_latency = proxy.latency - baseline.latency` at
p50/p95/p99 and also records the high-concurrency RPS numbers for each
scenario.

## How it works

`run.py` runs on the operator workstation. It:

1. Loads `terraform output -json` via the shared helper in `common/`.
2. Verifies that `hey` is already baked into the workload AMI.
3. Runs `hey -m HEAD -z ... -c ...` on the workload through SSM Run Command.
4. Swaps the workload default route from the proxy ENI to the ANF VPC endpoint.
5. Polls `describe-route-tables` until the route change is visible.
6. Reruns `hey` for the no-proxy baseline.
7. Restores the route to the proxy ENI in a `try/finally`.
8. Writes `results/<UTC-timestamp>/raw.json` and `summary.md` in UTF-8.

## Prerequisites

- `terraform apply` in `../terraform/` has succeeded, and the workload
  instance is running the workload golden AMI with `hey` baked in. Build
  that AMI once:
  ```bash
  cd packer/workload
  packer init .
  packer build -var "git_sha=$(git rev-parse --short HEAD)" .
  cd ../../terraform
  terraform apply
  ```
- AWS credentials with `ssm:SendCommand`, `ssm:GetCommandInvocation`,
  `ec2:DescribeRouteTables`, and `ec2:ReplaceRoute`.
- Python deps from the repo root: `pip install -e .` (installs `boto3`,
  `PyYAML`, and the shared `common` package).

## YAML config

`run.py` accepts an optional UTF-8 YAML file for benchmark knobs and target
selection. Start from the example:

```bash
cp benchmark/config.example.yaml benchmark/config.yaml
```

Supported keys:

- `fqdn`
- `results_dir`
- `latency.duration_s`
- `latency.concurrency`
- `rps.duration_s`
- `rps.concurrency`
- `route_swap.timeout_s`
- `route_swap.poll_interval_s`

CLI flags override YAML values. If `results_dir` is relative in the YAML file,
it is resolved relative to the YAML file's directory.

## Run

```bash
python benchmark/run.py
python benchmark/run.py --config benchmark/config.yaml
python benchmark/run.py --config benchmark/config.yaml --fqdn google.com --results-dir ./out
```

Results land in `benchmark/results/<UTC-timestamp>/{raw.json,summary.md}` by
default.

## Recovery

The `try/finally` should restore the route automatically. If the process is
killed between the swap and the restore, recover manually:

```bash
aws ec2 replace-route \
  --region "$(terraform -chdir=terraform output -raw aws_region)" \
  --route-table-id "$(terraform -chdir=terraform output -raw workload_route_table_id)" \
  --destination-cidr-block 0.0.0.0/0 \
  --network-interface-id "$(terraform -chdir=terraform output -raw proxy_eni_id)"
```

## Files

- `run.py`: orchestrator
- `config.example.yaml`: sample config for benchmark knobs
- `results/.gitignore`: ignores generated benchmark runs
- `results/sample/summary.md`: small example of the report format
