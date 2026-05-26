from __future__ import annotations

import importlib.util
import json
from pathlib import Path


HANDLER_PATH = (
    Path(__file__).resolve().parents[1]
    / "lambda"
    / "ruleset_generator"
    / "handler.py"
)


def load_handler():
    spec = importlib.util.spec_from_file_location("ruleset_generator_handler", HANDLER_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class FakeEc2:
    def __init__(self):
        self.modified = []

    def describe_managed_prefix_lists(self, PrefixListIds):
        return {
            "PrefixLists": [
                {
                    "PrefixListId": PrefixListIds[0],
                    "MaxEntries": 16,
                    "Version": 1,
                }
            ]
        }

    def get_managed_prefix_list_entries(self, PrefixListId):
        return {"Entries": []}

    def modify_managed_prefix_list(self, **request):
        self.modified.append(request)


def test_ruleset_generator_updates_one_prefix_list_per_fqdn(monkeypatch):
    handler = load_handler()
    fake_ec2 = FakeEc2()

    monkeypatch.setenv("FQDNS", json.dumps(["login.microsoftonline.com", "wiz.io"]))
    monkeypatch.setenv(
        "FQDN_PREFIX_LIST_IDS",
        json.dumps({
            "login.microsoftonline.com": "pl-login",
            "wiz.io": "pl-wiz",
        }),
    )
    monkeypatch.setattr(handler.boto3, "client", lambda service: fake_ec2)
    monkeypatch.setattr(
        handler,
        "resolve_fqdn",
        lambda fqdn: {
            "login.microsoftonline.com": ["20.190.147.1", "20.190.147.2"],
            "wiz.io": ["76.76.21.21"],
        }[fqdn],
    )

    result = handler.lambda_handler({}, None)

    assert result["entry_count_by_fqdn"] == {
        "login.microsoftonline.com": 2,
        "wiz.io": 1,
    }
    assert [request["PrefixListId"] for request in fake_ec2.modified] == [
        "pl-login",
        "pl-wiz",
    ]
    assert fake_ec2.modified[0]["AddEntries"] == [
        {"Cidr": "20.190.147.1/32", "Description": "login.microsoftonline.com"},
        {"Cidr": "20.190.147.2/32", "Description": "login.microsoftonline.com"},
    ]
    assert fake_ec2.modified[1]["AddEntries"] == [
        {"Cidr": "76.76.21.21/32", "Description": "wiz.io"},
    ]
