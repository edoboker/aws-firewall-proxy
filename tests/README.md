# tests

Integration tests for the transparent SNI proxy. Each test executes commands on the deployed EC2 instances via AWS SSM Run Command.

## Prerequisites

- `terraform apply` has succeeded in `../terraform/`
- both the workload and proxy EC2s appear in `aws ssm describe-instance-information`
- your AWS credentials can call `ssm:SendCommand` and `ssm:GetCommandInvocation`
- Python 3.10+

Give SSM about a minute after boot to register the instances.

## Run

All commands below are from the repo root. The shared `common` package lives there and must be installed first.

```bash
python -m venv .venv
source .venv/bin/activate          # Windows PowerShell: .venv\Scripts\Activate.ps1
pip install -e .
pip install -e ./tests
pytest -v tests
```

If you skip `pip install -e .`, `conftest.py` will fail with `ModuleNotFoundError: No module named 'common'`.

Set `AWS_REGION` if you deployed outside the default `eu-north-1`.

## Layout

Shared SSM, CloudWatch, and Terraform-output helpers live under `common/` so the
benchmark suite can reuse them.

**Offline** (no AWS; safe to run anywhere, including CI):

- `test_appconfig_policy_schema.py` validates the runtime-policy JSON schema — it accepts a good policy and rejects malformed ones. Needs `jsonschema` (in the `test` extra).
- `test_terraform_static.py` runs `terraform fmt -check` and `terraform validate`. Skips if `terraform` is missing or the working dir is not initialized.

**Live** (require a deployed stack reachable via SSM, plus AWS credentials):

- `test_proxy_up.py` / `test_proxy_runtime.py` check the proxy daemon is active, `nginx -t` passes, the iptables `:443 → :8443` REDIRECT is present, and the Lua/C-module guard is wired into the effective config.
- `test_workload_baseline.py` checks that `curl https://<allowed-fqdn>` from the workload succeeds.
- `test_policy_enforcement.py` checks that a non-allowlisted SNI (`deny_allowlist`) and an SNI-less request (`drop_no_sni`) are dropped, logged to the policy-denied group, and counted by `RequestsBlocked`.
- `test_sni_spoofing.py` checks that an allowlisted SNI pointed at a wrong IP is detected as `mismatch`, logged to the sni-spoofing group, counted by `SpoofingDetected`, and kept out of the error log (implements `sni-spoofing-placeholder.md`).

Log-line assertions fire within seconds. The `RequestsBlocked` / `SpoofingDetected`
metric assertions poll for up to a few minutes because metric-filter datapoints
lag behind the source log lines.
