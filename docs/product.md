# AWS Firewall Proxy — Product Overview

## Problem

AWS Network Firewall supports FQDN-based rules (e.g., allow `google.com`), but performs **no IP validation against the resolved hostname**. An attacker can craft a packet with a legitimate SNI/Host header (e.g., `google.com`) while routing it to a malicious IP. The firewall inspects only the application-layer host field, so the packet passes — a classic SNI/host spoofing bypass.

## Proposed Solutions

1. **DNS-aware proxy (chosen MVP):** Deploy a transparent proxy (e.g., Squid/Envoy) in-line that resolves the SNI/Host to its actual IPs and verifies the destination IP matches. Drops packets where IP ≠ resolved IPs for the hostname.
2. **Lambda + Route 53 Resolver DNS firewall enrichment:** Intercept DNS responses via Route 53 Resolver, track FQDN→IP mappings, and push dynamic IP sets to AWS Network Firewall rules. No proxy needed but adds latency and complexity on rule sync.
3. **Custom Suricata rule with JA3 + IP allowlist:** Extend the existing Suricata engine inside AWS Network Firewall with rules that cross-reference IP sets built from DNS responses. Limited by Suricata rule expressiveness and no native DNS correlation.

## Chosen Solution: DNS-Aware Transparent Proxy

A lightweight proxy sits between clients and the internet (deployed as an EC2/ECS service in the VPC egress path). It:
- Intercepts TLS traffic via SNI inspection or HTTP CONNECT
- Resolves the requested FQDN to IPs
- Checks that the TCP destination IP is among the resolved IPs
- Enforces the FQDN allowlist independently of AWS Network Firewall

AWS Network Firewall remains in place as a first-pass filter; the proxy adds the missing IP-to-hostname binding enforcement.

## Scope

- MVP: single-region, egress-only, HTTPS/TLS traffic
- Out of scope: UDP, non-SNI protocols, multi-region, mTLS
