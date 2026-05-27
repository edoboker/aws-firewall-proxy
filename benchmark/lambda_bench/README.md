# lambda_bench

Measures how the ruleset-generator Lambda
(`terraform/lambda_ruleset_generator.tf`) scales as the number of FQDNs it must
resolve grows. The Lambda resolves each FQDN to IPv4 answers and republishes
managed VPC prefix lists; this benchmark times that work at 10, 50, 100, 150,
200, 250, and 300 FQDNs and plots the result.

## What each step does

1. Set the lambda's `FQDNS` environment variable to the first N domains from
   `domains.py` via `UpdateFunctionConfiguration`. No terraform, no tfvars edit
   — the change reaches the deployed function in one API call.
2. Invoke the lambda synchronously and record its execution time, read from the
   CloudWatch `REPORT ... Duration:` line (falls back to client wall clock if
   that line can't be parsed).

### Scratch prefix list

The deployed prefix list is referenced by the ANF rule group, so every modify
stays in `modify-in-progress` for *minutes* while the firewall re-consumes it —
and AWS rejects the next modify until it settles, which would make the run
crawl. So the benchmark creates a throwaway, unreferenced prefix list, points
the lambda's `PREFIX_LIST_ID` at it for the run (each modify then settles in
seconds), and deletes it afterward. The real, firewall-attached list is never
touched.

The lambda's original config (env vars + timeout) is captured up front and
restored in a `finally`.

## Sizing / cost

- The hard limit is the managed prefix list's `MaxEntries`: AWS allows **1000
  entries per list by default** (a Service Quota you can raise). Total entries =
  `FQDNs × IPs-per-FQDN`, so the two knobs trade off against each other.
- `--addresses-per-fqdn` (default **1**, max **64**) caps the IPv4 /32s
  published per FQDN. The default of 1 makes prefix-list entries exactly equal
  the FQDN count, so the curve isolates *number of FQDNs to resolve* as the
  single variable instead of conflating it with each domain's (fluctuating)
  A-record count. Set it as high as 64 (= every A-record the resolver returns)
  for a more realistic publish load — but then `largest_step × addr` must stay
  under `--max-entries`. At 300 FQDNs and the default 1000-entry list that
  means up to ~3 IPs each.
- `--max-entries` (default **1000**) sizes the scratch list. Raise it only if
  you've been granted a Service Quotas increase above 1000.
- The lambda timeout is raised to 300s for the run (300 FQDNs resolved
  sequentially exceed the 30s default), then restored.
- The DNS resolution itself is the only meaningful cost; there's no data-plane
  traffic like the proxy benchmark.

## Prerequisites

- `enable_ruleset_generator = true` and a successful `terraform apply` so the
  Lambda exists (the `ruleset_generator_function_name` output is non-null).
- AWS credentials with `lambda:GetFunctionConfiguration`,
  `lambda:UpdateFunctionConfiguration`, `lambda:InvokeFunction`,
  `ec2:CreateManagedPrefixList`, `ec2:DeleteManagedPrefixList`, and
  `ec2:DescribeManagedPrefixLists`. (The lambda's own role already permits the
  modify calls against any prefix list.)
- Python deps: `pip install -e .` from the repo root, plus `matplotlib` for the
  plot (`pip install -e ".[benchmark]"`). Without matplotlib the run still
  writes `raw.json` and `summary.md`, just no PNG.

## Run

```bash
python benchmark/lambda_bench/run.py
python benchmark/lambda_bench/run.py --steps 10,50,100 --addresses-per-fqdn 1
```

Outputs land in `benchmark/lambda_bench/results/<UTC-timestamp>/`:

- `raw.json` — per-step durations, entry counts, errors
- `summary.md` — table of FQDN count vs lambda duration
- `scaling.png` — FQDN count vs lambda execution time

## After the run

The lambda's env vars and timeout are restored to what was deployed before the
run, and the scratch prefix list is deleted. The real, firewall-attached prefix
list is never modified, so there is no drift to reconcile. If the process is
killed mid-run, the scratch list may survive — the script prints the manual
`aws ec2 delete-managed-prefix-list` command to clean it up.

## Files

- `run.py` — orchestrator
- `domains.py` — curated list of ~370 reliably-resolvable FQDNs
- `results/.gitignore` — ignores generated runs
