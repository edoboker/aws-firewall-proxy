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

- Shared SSM and Terraform-output helpers live under `common/` so the benchmark suite can reuse them.
- `test_proxy_up.py` checks that the proxy daemon is active.
- `test_workload_baseline.py` checks that `curl https://<allowed-fqdn>` from the workload succeeds.
- `sni-spoofing-placeholder.md` is the placeholder plan for the live spoof-detection test.
- `proxy-runtime-placeholder.md` is the placeholder plan for the live proxy-runtime smoke test.
