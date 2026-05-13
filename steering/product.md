# AWS Network Firewall Proxy — Product Overview

## Problem

AWS Network Firewall supports FQDN-based rules (e.g., allow `google.com`), but performs **no hostname resolution and therefore no IP validation against the hostname**. An attacker can craft a packet with a legitimate SNI/Host header (e.g., `google.com`) while routing it to a malicious IP. The firewall inspects only the application-layer host field, so the packet passes — a classic SNI/host spoofing bypass.

## Proposed Solution
**DNS-aware proxy:** 
Deploy a transparent proxy (e.g., Squid/Envoy) in-line that resolves the SNI/Host to its actual IPs and verifies the destination IP matches. Drops packets where IP ≠ resolved IPs for the hostname.

A lightweight proxy sits between clients and the internet (deployed as an EC2/ECS service in the VPC egress path). It:
- Intercepts TLS traffic via SNI inspection or HTTP CONNECT
- Resolves the requested FQDN to IPs
- Checks that the TCP destination IP is among the resolved IPs

AWS Network Firewall remains in place as a first-pass filter; the proxy adds the missing IP-to-hostname binding enforcement.

## Scope
- MVP: single-region, egress-only, HTTPS/TLS traffic