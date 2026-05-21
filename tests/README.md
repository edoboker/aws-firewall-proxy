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
cd tests
pip install -e .
pytest -v
```

Set `AWS_REGION` if you deployed to anything other than the default `eu-north-1`.

## Layout

- `helpers/ssm.py` — wraps `send_command` + polling, returns `(status, exit_code, stdout, stderr)`.
- `helpers/tf_outputs.py` — shells out to `terraform output -json` once per session.
- `test_proxy_up.py` — proxy daemon is `active`.
- `test_workload_baseline.py` — `curl https://<allowed-fqdn>` from the workload returns 2xx/3xx.
