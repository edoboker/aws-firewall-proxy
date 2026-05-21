import pytest

from common import tf_outputs


@pytest.fixture(scope="session")
def outputs() -> dict:
    return tf_outputs.load()


@pytest.fixture(scope="session")
def aws_region(outputs) -> str:
    # Region is not currently exposed as a TF output; default to the variable
    # default. If you override aws_region in terraform.tfvars, set TF_VAR_aws_region
    # or add an `aws_region` output and read it here.
    import os

    return os.environ.get("AWS_REGION", "eu-north-1")
