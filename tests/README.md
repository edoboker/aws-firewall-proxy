# tests

Integration tests for the transparent override proxy. Live tests execute
commands on deployed EC2 instances via AWS SSM Run Command; offline tests are
safe to run locally and in CI.

## Prerequisites

- `terraform apply` has succeeded in `../terraform/`
- the workload and proxy EC2s appear in `aws ssm describe-instance-information`
- your AWS credentials can call `ssm:SendCommand` and `ssm:GetCommandInvocation`
- Python 3.10+

## Run

```bash
python -m venv .venv
source .venv/bin/activate          # Windows PowerShell: .venv\Scripts\Activate.ps1
pip install -e .
pip install -e ./tests
pytest -v tests
```

If Terraform outputs are unavailable, live tests skip through the shared
`outputs` fixture in `conftest.py`.

## Offline tests

- **`test_appconfig_policy_schema.py`** - validates the runtime-policy JSON schema still used by the HTTP prototype path.
- **`test_terraform_static.py`** - checks Terraform formatting/validation and static wiring for the override observation log and async detector resources.
- **`test_sni_spoofing_detector.py`** - unit tests CloudWatch Logs payload decoding, malformed event isolation, and metric publishing on mocked DNS mismatches.

## Live tests

- **`test_proxy_up.py`** - checks nginx is active.
- **`test_proxy_runtime.py`** - checks `nginx -t`, iptables `:443 -> :8443` REDIRECT, the original-dst C module, `ssl_preread`, and override observation logging.
- **`test_workload_baseline.py`** - verifies a normal HTTPS request from the workload succeeds.

The old synchronous Lua SNI enforcement live tests were removed with the legacy
guard; async detector live coverage is still a future addition.
