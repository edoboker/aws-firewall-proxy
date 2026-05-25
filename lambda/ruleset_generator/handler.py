import json
import os
import random
import socket
import struct
from ipaddress import ip_address

import boto3


MAX_ADDRESSES_PER_FQDN = int(os.environ.get("MAX_ADDRESSES_PER_FQDN", "64"))
DNS_TIMEOUT_SECONDS = float(os.environ.get("DNS_TIMEOUT_SECONDS", "2"))
PUBLIC_RESOLVERS = {
    "cloudflare": "1.1.1.1",
    "google": "8.8.8.8",
}


def lambda_handler(event, context):
    fqdns = [fqdn.strip().lower().rstrip(".") for fqdn in json.loads(os.environ["FQDNS"])]
    prefix_list_ids = json.loads(os.environ.get("PREFIX_LIST_IDS", "[]"))
    if not prefix_list_ids:
        prefix_list_ids = [os.environ["PREFIX_LIST_ID"]]

    entries = []
    for fqdn in fqdns:
        ips = resolve_fqdn(fqdn)
        if not ips:
            raise RuntimeError(f"no IPv4 answers resolved for {fqdn}")

        for ip in ips[:MAX_ADDRESSES_PER_FQDN]:
            entries.append(
                {
                    "Cidr": f"{ip}/32",
                    "Description": fqdn[:255],
                }
            )

    desired_entries = dedupe_entries(entries)
    replace_prefix_list_entries(prefix_list_ids, desired_entries)
    return {
        "prefix_list_ids": prefix_list_ids,
        "entry_count": len(desired_entries),
        "fqdns": fqdns,
    }


def resolve_fqdn(fqdn):
    answers = set()
    answers.update(resolve_with_platform_resolver(fqdn))
    for resolver_ip in PUBLIC_RESOLVERS.values():
        answers.update(resolve_with_dns_server(fqdn, resolver_ip))
    return sorted(answers)


def resolve_with_platform_resolver(fqdn):
    answers = set()
    for family, _, _, _, sockaddr in socket.getaddrinfo(fqdn, 443, family=socket.AF_INET):
        if family == socket.AF_INET:
            answers.add(str(ip_address(sockaddr[0])))
    return answers


def resolve_with_dns_server(fqdn, server_ip):
    query_id = random.randint(0, 65535)
    packet = build_dns_query(query_id, fqdn)

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(DNS_TIMEOUT_SECONDS)
        sock.sendto(packet, (server_ip, 53))
        response, _ = sock.recvfrom(4096)

    return parse_a_records(response, query_id)


def build_dns_query(query_id, fqdn):
    header = struct.pack("!HHHHHH", query_id, 0x0100, 1, 0, 0, 0)
    labels = fqdn.strip(".").split(".")
    question = b"".join(len(label).to_bytes(1, "big") + label.encode("ascii") for label in labels)
    question += b"\x00"
    question += struct.pack("!HH", 1, 1)
    return header + question


def parse_a_records(response, expected_query_id):
    query_id, flags, qdcount, ancount, _, _ = struct.unpack("!HHHHHH", response[:12])
    if query_id != expected_query_id:
        raise RuntimeError("DNS response query id mismatch")
    if flags & 0x000F:
        return set()

    offset = 12
    for _ in range(qdcount):
        offset = skip_dns_name(response, offset)
        offset += 4

    answers = set()
    for _ in range(ancount):
        offset = skip_dns_name(response, offset)
        record_type, record_class, _, rdlength = struct.unpack("!HHIH", response[offset : offset + 10])
        offset += 10
        rdata = response[offset : offset + rdlength]
        offset += rdlength

        if record_type == 1 and record_class == 1 and rdlength == 4:
            answers.add(socket.inet_ntoa(rdata))

    return answers


def skip_dns_name(message, offset):
    while True:
        length = message[offset]
        if length & 0xC0 == 0xC0:
            return offset + 2
        if length == 0:
            return offset + 1
        offset += 1 + length


def dedupe_entries(entries):
    by_cidr = {}
    for entry in entries:
        by_cidr.setdefault(entry["Cidr"], entry)
    return [by_cidr[cidr] for cidr in sorted(by_cidr)]


def replace_prefix_list_entries(prefix_list_ids, desired_entries):
    ec2 = boto3.client("ec2")
    prefix_lists = describe_prefix_lists(ec2, prefix_list_ids)
    total_capacity = sum(prefix_list["MaxEntries"] for prefix_list in prefix_lists)
    if len(desired_entries) > total_capacity:
        raise RuntimeError(
            f"resolved {len(desired_entries)} entries but prefix list capacity is {total_capacity}"
        )

    chunks = split_entries_by_capacity(desired_entries, prefix_lists)
    for prefix_list, chunk in zip(prefix_lists, chunks):
        replace_one_prefix_list(ec2, prefix_list, chunk)


def describe_prefix_lists(ec2, prefix_list_ids):
    by_id = {}
    for prefix_list_id in prefix_list_ids:
        prefix_list = ec2.describe_managed_prefix_lists(PrefixListIds=[prefix_list_id])[
            "PrefixLists"
        ][0]
        by_id[prefix_list_id] = prefix_list
    return [by_id[prefix_list_id] for prefix_list_id in prefix_list_ids]


def split_entries_by_capacity(entries, prefix_lists):
    chunks = []
    offset = 0
    for prefix_list in prefix_lists:
        next_offset = offset + prefix_list["MaxEntries"]
        chunks.append(entries[offset:next_offset])
        offset = next_offset
    return chunks


def replace_one_prefix_list(ec2, prefix_list, desired_entries):
    current_entries = get_all_prefix_list_entries(ec2, prefix_list["PrefixListId"])
    current_by_cidr = {entry["Cidr"]: entry.get("Description", "") for entry in current_entries}
    desired_by_cidr = {entry["Cidr"]: entry.get("Description", "") for entry in desired_entries}

    remove_entries = [{"Cidr": cidr} for cidr in current_by_cidr if cidr not in desired_by_cidr]
    add_entries = [entry for entry in desired_entries if entry["Cidr"] not in current_by_cidr]

    if not remove_entries and not add_entries:
        return

    request = {
        "PrefixListId": prefix_list["PrefixListId"],
        "CurrentVersion": prefix_list["Version"],
    }
    if remove_entries:
        request["RemoveEntries"] = remove_entries
    if add_entries:
        request["AddEntries"] = add_entries

    ec2.modify_managed_prefix_list(**request)


def get_all_prefix_list_entries(ec2, prefix_list_id):
    entries = []
    next_token = None
    while True:
        request = {"PrefixListId": prefix_list_id}
        if next_token:
            request["NextToken"] = next_token

        response = ec2.get_managed_prefix_list_entries(**request)
        entries.extend(response["Entries"])
        next_token = response.get("NextToken")
        if not next_token:
            return entries
