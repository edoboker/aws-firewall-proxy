from __future__ import annotations

import base64
import gzip
import json
import os
import random
import socket
import struct
from ipaddress import ip_address

import boto3


METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "AwsFirewallProxy")
METRIC_NAME = os.environ.get("METRIC_NAME", "SuspectedSniSpoofing")
DNS_TIMEOUT_SECONDS = float(os.environ.get("DNS_TIMEOUT_SECONDS", "1.5"))
MAX_CNAME_DEPTH = int(os.environ.get("MAX_CNAME_DEPTH", "5"))
DNS_RESOLVERS = [
    resolver.strip()
    for resolver in os.environ.get("DNS_RESOLVERS", "1.1.1.1,8.8.8.8").split(",")
    if resolver.strip()
]

_cloudwatch = None


def lambda_handler(event, context):
    payload = decode_cloudwatch_logs_event(event)
    if payload.get("messageType") == "CONTROL_MESSAGE":
        return {"processed": 0, "alerts": 0, "skipped": 0, "control": True}

    cloudwatch = cloudwatch_client()
    counts = {"processed": 0, "alerts": 0, "skipped": 0}
    for log_event in payload.get("logEvents", []):
        outcome = process_log_event(log_event, payload, cloudwatch)
        counts[outcome] += 1

    return counts


def cloudwatch_client():
    global _cloudwatch
    if _cloudwatch is None:
        _cloudwatch = boto3.client("cloudwatch")
    return _cloudwatch


def decode_cloudwatch_logs_event(event):
    data = event.get("awslogs", {}).get("data")
    if not data:
        raise ValueError("missing awslogs.data")

    compressed = base64.b64decode(data)
    return json.loads(gzip.decompress(compressed).decode("utf-8"))


def process_log_event(log_event, payload, cloudwatch):
    try:
        observation = json.loads(log_event.get("message", ""))
    except json.JSONDecodeError as exc:
        log_skip("malformed_json", log_event, str(exc))
        return "skipped"

    validated = validate_observation(observation)
    if not validated["ok"]:
        log_skip(validated["reason"], log_event, validated.get("detail"))
        return "skipped"

    sni = validated["sni"]
    original_ip = validated["original_destination_ip"]
    resolved_ips, resolve_error = resolve_a_records(sni)
    if not resolved_ips:
        log_skip("dns_resolution_empty", log_event, resolve_error)
        return "skipped"

    if original_ip in resolved_ips:
        return "processed"

    alert = {
        "event": "suspected_sni_spoofing",
        "sni": sni,
        "original_destination_ip": original_ip,
        "original_destination_port": observation.get("original_destination_port", ""),
        "source_ip": observation.get("source_ip", ""),
        "source_port": observation.get("source_port", ""),
        "upstream_host_used": observation.get("upstream_host_used", ""),
        "resolved_ips": sorted(resolved_ips),
        "log_group": payload.get("logGroup", ""),
        "proxy_instance_id": payload.get("logStream", ""),
        "log_event_id": log_event.get("id", ""),
    }
    print(json.dumps(alert, sort_keys=True))
    try:
        publish_spoofing_metric(cloudwatch)
    except Exception as exc:  # Metric delivery must not poison the batch.
        print(json.dumps({
            "event": "sni_spoofing_detector_metric_publish_failed",
            "error": str(exc),
            "log_event_id": log_event.get("id", ""),
        }, sort_keys=True))
    return "alerts"


def validate_observation(observation):
    sni = canonicalize_sni(observation.get("sni"))
    if not sni:
        return {"ok": False, "reason": "missing_or_invalid_sni"}

    original_ip = observation.get("original_destination_ip")
    if not original_ip:
        return {"ok": False, "reason": "missing_original_destination_ip"}

    try:
        parsed_ip = ip_address(str(original_ip))
    except ValueError as exc:
        return {
            "ok": False,
            "reason": "invalid_original_destination_ip",
            "detail": str(exc),
        }

    if parsed_ip.version != 4:
        return {"ok": False, "reason": "unsupported_original_destination_ip_version"}

    return {
        "ok": True,
        "sni": sni,
        "original_destination_ip": str(parsed_ip),
    }


def canonicalize_sni(value):
    sni = str(value or "").strip().lower().rstrip(".")
    if not sni or len(sni) > 253:
        return None
    labels = sni.split(".")
    for label in labels:
        if not label or len(label) > 63:
            return None
        if label.startswith("-") or label.endswith("-"):
            return None
        if not all(ch.isalnum() or ch == "-" for ch in label):
            return None
    return sni


def resolve_a_records(hostname):
    resolved = set()
    errors = []
    pending = [(hostname, 0)]
    seen = set()

    while pending:
        name, depth = pending.pop(0)
        if (name, depth) in seen:
            continue
        seen.add((name, depth))
        if depth > MAX_CNAME_DEPTH:
            errors.append(f"cname_depth_exceeded:{name}")
            continue

        cname_targets = set()
        for resolver in DNS_RESOLVERS:
            try:
                addresses, cnames = query_dns_a_and_cname(name, resolver)
                resolved.update(addresses)
                cname_targets.update(cnames)
            except (OSError, ValueError, RuntimeError, TimeoutError) as exc:
                errors.append(f"{resolver}:{type(exc).__name__}:{exc}")

        if resolved:
            return resolved, None

        for cname in sorted(cname_targets):
            canonical = canonicalize_sni(cname)
            if canonical:
                pending.append((canonical, depth + 1))

    return resolved, "; ".join(errors) if errors else "no_a_records"


def query_dns_a_and_cname(hostname, server_ip):
    query_id = random.randint(0, 65535)
    packet = build_dns_query(query_id, hostname)

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(DNS_TIMEOUT_SECONDS)
        sock.sendto(packet, (server_ip, 53))
        response, _ = sock.recvfrom(4096)

    return parse_dns_response(response, query_id)


def build_dns_query(query_id, hostname):
    header = struct.pack("!HHHHHH", query_id, 0x0100, 1, 0, 0, 0)
    question = b"".join(
        len(label).to_bytes(1, "big") + label.encode("ascii")
        for label in hostname.split(".")
    )
    question += b"\x00"
    question += struct.pack("!HH", 1, 1)
    return header + question


def parse_dns_response(response, expected_query_id):
    if len(response) < 12:
        raise ValueError("short_dns_response")

    query_id, flags, qdcount, ancount, _, _ = struct.unpack("!HHHHHH", response[:12])
    if query_id != expected_query_id:
        raise RuntimeError("dns_response_query_id_mismatch")

    rcode = flags & 0x000F
    if rcode != 0:
        raise RuntimeError(f"dns_rcode_{rcode}")

    offset = 12
    for _ in range(qdcount):
        _, offset = read_dns_name(response, offset)
        offset += 4
        if offset > len(response):
            raise ValueError("truncated_dns_question")

    addresses = set()
    cnames = set()
    for _ in range(ancount):
        _, offset = read_dns_name(response, offset)
        if offset + 10 > len(response):
            raise ValueError("truncated_dns_answer_header")
        record_type, record_class, _, rdlength = struct.unpack("!HHIH", response[offset : offset + 10])
        offset += 10
        rdata_offset = offset
        offset += rdlength
        if offset > len(response):
            raise ValueError("truncated_dns_answer_rdata")

        if record_class != 1:
            continue
        if record_type == 1 and rdlength == 4:
            addresses.add(socket.inet_ntoa(response[rdata_offset:offset]))
        elif record_type == 5:
            cname, _ = read_dns_name(response, rdata_offset)
            cnames.add(cname.rstrip("."))

    return addresses, cnames


def read_dns_name(message, offset):
    labels = []
    jumped = False
    original_offset = offset
    jumps = 0

    while True:
        if offset >= len(message):
            raise ValueError("truncated_dns_name")

        length = message[offset]
        if length & 0xC0 == 0xC0:
            if offset + 1 >= len(message):
                raise ValueError("truncated_dns_pointer")
            pointer = ((length & 0x3F) << 8) | message[offset + 1]
            if pointer >= len(message):
                raise ValueError("dns_pointer_out_of_range")
            if not jumped:
                original_offset = offset + 2
            jumped = True
            offset = pointer
            jumps += 1
            if jumps > 16:
                raise ValueError("dns_pointer_loop")
            continue

        if length == 0:
            offset += 1
            break

        offset += 1
        if offset + length > len(message):
            raise ValueError("truncated_dns_label")
        labels.append(message[offset : offset + length].decode("ascii"))
        offset += length

    return ".".join(labels), original_offset if jumped else offset


def publish_spoofing_metric(cloudwatch):
    cloudwatch.put_metric_data(
        Namespace=METRIC_NAMESPACE,
        MetricData=[
            {
                "MetricName": METRIC_NAME,
                "Value": 1,
                "Unit": "Count",
            }
        ],
    )


def log_skip(reason, log_event, detail=None):
    event = {
        "event": "sni_spoofing_detector_skip",
        "reason": reason,
        "log_event_id": log_event.get("id", ""),
    }
    if detail:
        event["detail"] = str(detail)
    print(json.dumps(event, sort_keys=True))
