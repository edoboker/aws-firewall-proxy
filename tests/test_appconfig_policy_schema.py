import json
from pathlib import Path

import pytest
from jsonschema import Draft4Validator

# The deploy-time + runtime contract for the proxy runtime policy. AppConfig
# validates submitted policies against this schema (terraform/appconfig.tf), and
# the runtime policy renderer consumes the same shape on the host.
SCHEMA_PATH = (
    Path(__file__).resolve().parents[1]
    / "terraform"
    / "appconfig-policies"
    / "proxy_runtime_policy.schema.json"
)


@pytest.fixture(scope="module")
def schema() -> dict:
    return json.loads(SCHEMA_PATH.read_text())


@pytest.fixture(scope="module")
def validator(schema) -> Draft4Validator:
    Draft4Validator.check_schema(schema)
    return Draft4Validator(schema)


def _valid_policy() -> dict:
    return {
        "allowed_snis": ["google.com", "amazonaws.com"],
        "dns": {"resolvers": ["169.254.169.253", "1.1.1.1"], "queries_per_sni": 3},
        "enforcement": {"mode": "strict"},
    }


def test_schema_is_well_formed(validator):
    # check_schema() in the fixture raises if the schema itself is malformed.
    assert validator is not None


def test_representative_policy_is_accepted(validator):
    assert list(validator.iter_errors(_valid_policy())) == []


def _without(key):
    def mutate(policy):
        policy.pop(key)

    return mutate


def _set(path, value):
    def mutate(policy):
        target = policy
        for key in path[:-1]:
            target = target[key]
        target[path[-1]] = value

    return mutate


# Each entry corrupts the valid policy in one way the schema must reject. The
# numeric/enum bounds document the contract the runtime policy renderer expects.
INVALID_CASES = {
    "missing allowed_snis": _without("allowed_snis"),
    "missing dns": _without("dns"),
    "missing enforcement": _without("enforcement"),
    "mode not in enum": _set(["enforcement", "mode"], "monitor"),
    "queries_per_sni below min": _set(["dns", "queries_per_sni"], 0),
    "queries_per_sni above max": _set(["dns", "queries_per_sni"], 17),
    "queries_per_sni not integer": _set(["dns", "queries_per_sni"], 2.5),
    "no resolvers": _set(["dns", "resolvers"], []),
    "unknown top-level key": _set(["extra"], 1),
}


@pytest.mark.parametrize("mutate", INVALID_CASES.values(), ids=list(INVALID_CASES))
def test_invalid_policies_are_rejected(validator, mutate):
    policy = _valid_policy()
    mutate(policy)
    assert list(validator.iter_errors(policy)), "schema should have rejected this policy"
