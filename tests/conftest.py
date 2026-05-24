import subprocess

import pytest

from common import tf_outputs


@pytest.fixture(scope="session")
def outputs() -> dict:
    # Live tests read the deployed stack's Terraform outputs. If the working dir
    # is not initialized (S3 backend) or no stack is deployed, skip rather than
    # erroring - the offline tests don't depend on this fixture.
    try:
        return tf_outputs.load()
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        pytest.skip(f"terraform outputs unavailable (deploy + 'terraform init' first): {exc}")


@pytest.fixture(scope="session")
def aws_region(outputs) -> str:
    # Prefer the deployed stack's region from Terraform output so the tests do
    # not accidentally target a different region from the one holding the EC2s.
    import os

    return outputs.get("aws_region") or os.environ.get("AWS_REGION", "eu-north-1")


@pytest.fixture(scope="session")
def proxy_enforcement_mode(outputs) -> str:
    # strict: a denied/spoofed connection is reset, so the client curl fails too.
    # audit:  the event is still logged, but the connection may succeed.
    return outputs.get("proxy_enforcement_mode", "strict")


@pytest.fixture(scope="session")
def baseline_fqdn(outputs) -> str:
    fqdns = outputs.get("nginx_allowed_snis") or outputs["allowed_fqdns"]
    assert fqdns, "no baseline fqdn output - check terraform/variables.tf and terraform/outputs.tf"
    if "google.com" in fqdns:
        return "www.google.com"
    return fqdns[0]
