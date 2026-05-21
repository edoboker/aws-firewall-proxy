# tests

Integration tests for the transparent SNI proxy. Each test executes commands on
the deployed EC2 instances via AWS SSM Run Command.

## Prerequisites

- `terraform apply` has succeeded in `../terraform/` against the AWS account you
  are pointed at.
- Both the workload and proxy EC2s appear in `aws ssm describe-instance-information`
  (give the SSM agent ~1 minute after boot to register).
- AWS credentials in the environment that can call `ssm:SendCommand` and
  `ssm:GetCommandInvocation` for those instances.
- Python 3.10+.

## Run

```
python -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -e .                   # at repo root: installs shared `common` package
pip install -e ./tests             # installs this suite + pytest
pytest -v tests
```

Set `AWS_REGION` if you deployed to anything other than the default `eu-north-1`.

## Layout

- Shared SSM / terraform-output helpers live at the repo root under `common/`
  so the `benchmark/` suite can reuse them.
- `test_proxy_up.py` — proxy daemon is `active`.
- `test_workload_baseline.py` — `curl https://<allowed-fqdn>` from the workload returns 2xx/3xx.
