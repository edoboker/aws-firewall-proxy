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

All commands below are from the **repo root**. The shared `common` package
(SSM + terraform-output helpers) lives there and must be installed first;
the test suite depends on it.

```
python -m venv .venv
source .venv/bin/activate          # Windows cmd: .venv\Scripts\activate.bat
                                   # Windows PowerShell: .venv\Scripts\Activate.ps1
pip install -e .                   # shared `common` package + boto3
pip install -e ./tests             # this suite + pytest
pytest -v tests
```

If you skip the first `pip install -e .` you will get
`ModuleNotFoundError: No module named 'common'` from `conftest.py`.

Set `AWS_REGION` if you deployed to anything other than the default `eu-north-1`.

## Layout

- Shared SSM / terraform-output helpers live at the repo root under `common/`
  so the `benchmark/` suite can reuse them.
- `test_proxy_up.py` — proxy daemon is `active`.
- `test_workload_baseline.py` — `curl https://<allowed-fqdn>` from the workload returns 2xx/3xx.
