import pytest

from common import tf_outputs


@pytest.fixture(scope="session")
def outputs() -> dict:
    return tf_outputs.load()


@pytest.fixture(scope="session")
def aws_region(outputs) -> str:
    # Prefer the deployed stack's region from Terraform output so the tests do
    # not accidentally target a different region from the one holding the EC2s.
    import os

    return outputs.get("aws_region") or os.environ.get("AWS_REGION", "eu-north-1")
