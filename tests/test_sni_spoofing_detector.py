from __future__ import annotations

import base64
import gzip
import importlib.util
import json
from pathlib import Path


HANDLER_PATH = (
    Path(__file__).resolve().parents[1]
    / "lambda"
    / "sni_spoofing_detector"
    / "handler.py"
)


def load_handler():
    spec = importlib.util.spec_from_file_location("sni_spoofing_detector_handler", HANDLER_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class FakeCloudWatch:
    def __init__(self):
        self.requests = []

    def put_metric_data(self, **kwargs):
        self.requests.append(kwargs)


def cloudwatch_event(payload: dict) -> dict:
    encoded = base64.b64encode(gzip.compress(json.dumps(payload).encode("utf-8"))).decode("ascii")
    return {"awslogs": {"data": encoded}}


def observation(**overrides):
    event = {
        "timestamp": "2026-05-26T00:00:00+00:00",
        "source_ip": "10.0.1.10",
        "source_port": "44444",
        "sni": "Example.COM.",
        "original_destination_ip": "203.0.113.10",
        "original_destination_port": "443",
        "upstream_host_used": "Example.COM.",
    }
    event.update(overrides)
    return event


def test_decode_cloudwatch_logs_subscription_payload():
    handler = load_handler()
    payload = {
        "messageType": "DATA_MESSAGE",
        "logGroup": "/aws/firewall-proxy/nginx/override-observations",
        "logStream": "i-1234567890abcdef0",
        "logEvents": [{"id": "1", "message": json.dumps(observation())}],
    }

    assert handler.decode_cloudwatch_logs_event(cloudwatch_event(payload)) == payload


def test_malformed_event_is_skipped_without_failing_batch(monkeypatch):
    handler = load_handler()
    fake_cw = FakeCloudWatch()
    monkeypatch.setattr(handler, "cloudwatch_client", lambda: fake_cw)
    monkeypatch.setattr(handler, "resolve_a_records", lambda sni: ({"203.0.113.10"}, None))
    payload = {
        "messageType": "DATA_MESSAGE",
        "logGroup": "/aws/firewall-proxy/nginx/override-observations",
        "logStream": "i-1234567890abcdef0",
        "logEvents": [
            {"id": "bad", "message": "not-json"},
            {"id": "good", "message": json.dumps(observation())},
        ],
    }

    result = handler.lambda_handler(cloudwatch_event(payload), None)

    assert result == {"processed": 1, "alerts": 0, "skipped": 1}
    assert fake_cw.requests == []


def test_metric_is_published_only_when_original_destination_mismatches(monkeypatch):
    handler = load_handler()
    fake_cw = FakeCloudWatch()
    monkeypatch.setattr(handler, "cloudwatch_client", lambda: fake_cw)
    monkeypatch.setattr(handler, "resolve_a_records", lambda sni: ({"198.51.100.20"}, None))
    payload = {
        "messageType": "DATA_MESSAGE",
        "logGroup": "/aws/firewall-proxy/nginx/override-observations",
        "logStream": "i-1234567890abcdef0",
        "logEvents": [{"id": "mismatch", "message": json.dumps(observation())}],
    }

    result = handler.lambda_handler(cloudwatch_event(payload), None)

    assert result == {"processed": 0, "alerts": 1, "skipped": 0}
    assert fake_cw.requests == [
        {
            "Namespace": "AwsFirewallProxy",
            "MetricData": [
                {
                    "MetricName": "SuspectedSniSpoofing",
                    "Value": 1,
                    "Unit": "Count",
                }
            ],
        }
    ]


def test_matching_original_destination_does_not_publish_metric(monkeypatch):
    handler = load_handler()
    fake_cw = FakeCloudWatch()
    monkeypatch.setattr(handler, "cloudwatch_client", lambda: fake_cw)
    monkeypatch.setattr(handler, "resolve_a_records", lambda sni: ({"203.0.113.10"}, None))
    payload = {
        "messageType": "DATA_MESSAGE",
        "logGroup": "/aws/firewall-proxy/nginx/override-observations",
        "logStream": "i-1234567890abcdef0",
        "logEvents": [{"id": "match", "message": json.dumps(observation())}],
    }

    result = handler.lambda_handler(cloudwatch_event(payload), None)

    assert result == {"processed": 1, "alerts": 0, "skipped": 0}
    assert fake_cw.requests == []
