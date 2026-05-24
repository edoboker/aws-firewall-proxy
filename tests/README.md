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

Shared SSM, CloudWatch, and Terraform-output helpers live under `common/` at the repo root so the benchmark suite can reuse them. The live tests below read the deployed stack's Terraform outputs via the session `outputs` fixture in `conftest.py`; if those outputs are unavailable (no stack deployed, or the working dir is not `terraform init`-ed), every live test skips with a clear reason rather than erroring.

### Offline tests (no AWS, safe in CI)

- **`test_appconfig_policy_schema.py`** - validates the proxy runtime-policy JSON schema (`terraform/appconfig-policies/proxy_runtime_policy.schema.json`), the contract AppConfig enforces at deploy time and `check_sni.lua` re-checks on the host. It asserts the schema is well-formed, accepts a representative valid policy, and rejects nine malformed ones (bad `mode`, out-of-range `queries_per_sni`, missing/extra keys). Needs `jsonschema` (in the `test` extra); runs in well under a second.
- **`test_terraform_static.py`** - runs `terraform fmt -check -recursive` and `terraform validate` against `terraform/` so formatting drift or invalid HCL fails fast. It skips the whole module if the `terraform` binary is not on `PATH`, and skips `validate` alone if the working dir has not been initialized.

### Live tests (need a deployed stack reachable via SSM + AWS credentials)

- **`test_proxy_up.py`** - the original liveness check: `systemctl is-active nginx` on the proxy instance returns `active`. Fast (one SSM round-trip).
- **`test_proxy_runtime.py`** - runtime smoke test of the full transparent-proxy wiring: `nginx -t` passes, `iptables-save` shows the `:443 -> :8443` PREROUTING REDIRECT, and the effective config (`nginx -T`) references the Lua guard (`preread_by_lua_file`, `check_sni.lua`) and the original-dst C module. Proves the data path exists before any enforcement test relies on it.
- **`test_workload_baseline.py`** - the happy path: `curl https://<allowed-fqdn>` from the workload returns 2xx/3xx, confirming allowed traffic flows through the proxy. The FQDN comes from the shared `baseline_fqdn` fixture in `conftest.py`.
- **`test_proxy_metrics.py`** - verifies the proxy's direct CloudWatch metrics path end to end. It generates allowed, blocked, and spoofed traffic from the workload, then waits for the `Requests`, `AcceptedConnections`, `BlockedConnections`, and `SniMismatchCount` metrics to increase in the `AwsFirewallProxy/Nginx` namespace for the proxy instance. Its timing depends on `proxy_metrics_publish_interval_seconds` (now `20` by default), and the assertions intentionally allow several publish windows plus extra retries for delayed CloudWatch visibility.
- **`test_policy_enforcement.py`** - proves the proxy drops what it should. It curls a non-allowlisted SNI (expects `deny_allowlist`) and an IP-literal URL with no SNI (expects `drop_no_sni`), then asserts the matching line appears in the `policy-denied` log group and the `RequestsBlocked` metric increments. Important: the deny-allowlist case uses `curl --resolve` to pin the IP and skip DNS - a plain `curl https://example.org` would be NXDOMAIN'd by the Route 53 DNS Firewall (`dns_firewall.tf`) and never reach the proxy, so there would be no SNI to deny. Timing: the log-line check returns within seconds, but the metric is derived by a CloudWatch metric filter that can lag the source log line by a minute or two, so the metric assertion now waits longer and polls more frequently than before.
- **`test_sni_spoofing.py`** - the core attack test: an allowlisted SNI pointed at a wrong IP via `curl --resolve`. It asserts the `sni-spoofing` log group records `decision="mismatch"` (with the SNI and spoofed `dst_ip`), the `SpoofingDetected` metric increments, and the spoof line does not leak into the error log. Timing: same as above - the metric-filter-backed CloudWatch datapoint can lag, so the test now gives it a longer polling window. The client-side "connection reset" assertion only applies in `strict` enforcement mode (the `proxy_enforcement_mode` fixture); in `audit` mode the line is still logged but the connection succeeds.

The three CloudWatch-backed tests are the slow ones. `test_proxy_metrics.py` waits on the direct metrics publish interval, while `test_policy_enforcement.py` and `test_sni_spoofing.py` also wait on slower metric-filter evaluation. If a CloudWatch datapoint legitimately lags past the polling window, the metric assertion can fail even though the log-line assertion passed - bump the relevant timeout at the helper call site if you hit that.
