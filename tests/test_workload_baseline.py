import pytest

from common.ssm import ssm_exec


@pytest.fixture(scope="session")
def baseline_fqdn(outputs) -> str:
    fqdns = outputs.get("nginx_allowed_snis") or outputs["allowed_fqdns"]
    assert fqdns, "no baseline fqdn output - check terraform/variables.tf and terraform/outputs.tf"
    if "google.com" in fqdns:
        return "www.google.com"
    return fqdns[0]


def test_workload_curl_baseline(outputs, aws_region, baseline_fqdn):
    cmd = (
        f"curl -sS -o /dev/null -w '%{{http_code}}' "
        f"--max-time 10 https://{baseline_fqdn}"
    )
    result = ssm_exec(
        outputs["workload_instance_id"],
        cmd,
        region=aws_region,
        timeout_seconds=30,
    )
    assert result.exit_code == 0, f"curl failed: {result!r}"
    code = result.stdout.strip()
    assert code and code[0] in {"2", "3"}, f"unexpected HTTP status {code!r}"
