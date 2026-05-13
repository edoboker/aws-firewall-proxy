# aws-firewall-proxy

Transparent forward proxy that fixes the SNI spoofing bypass in AWS Network Firewall.
AWS Network Firewall FQDN rules inspect only the TLS SNI header — they never verify that the destination IP actually belongs to that hostname. An attacker can set SNI to an allowed domain while routing traffic to a malicious IP. This project deploys a DNS-aware proxy in the VPC egress path that resolves the SNI hostname and always forwards to the DNS-resolved IP, closing the gap.

## Architecture

```
Workload EC2  ──▶  Proxy EC2 (nginx or Envoy)  ──▶  AWS Network Firewall  ──▶  NAT GW  ──▶  Internet
 (10.0.1.0/24)      (10.0.2.0/24)                    (10.0.3.0/24)             (10.0.4.0/24)
```

- **Workload subnet** — client EC2 instance; default route points to the proxy ENI.
- **Proxy subnet** — transparent proxy intercepts TLS traffic via iptables REDIRECT, reads the SNI, resolves the hostname via VPC DNS, and forwards to the real IP. Two implementations are provided: nginx (stream module) and Envoy (SNI dynamic forward proxy).
- **Firewall subnet** — AWS Network Firewall applies an FQDN allowlist (Suricata rules with `dotprefix` for safe suffix matching).
- **Public subnet** — NAT Gateway for internet egress.

Single AZ deployment. Traffic is steered through route tables — no load balancers or DNS tricks.

## Deploy

```bash
cd terraform

# 1. Configure variables
cp terraform.tfvars.example terraform.tfvars   # edit as needed

# 2. Apply
terraform init
terraform apply
```

## Verify — SNI spoofing test

From the workload EC2 (connect via EC2 Instance Connect):

```bash
# Spoofed IP — proxy ignores the fake destination and resolves google.com itself
curl -v --resolve google.com:443:1.1.1.1 https://google.com --max-time 10
# Expected: succeeds, proving the proxy overrides the spoofed IP

# Blocked domain — ANF drops traffic for domains not in the allowlist
curl -v https://example.com --max-time 10
# Expected: times out / connection reset
```

## Key Design Decisions

- **`source_dest_check = false`** on the proxy ENI — required for transparent proxying (packets arrive with a destination IP that isn't the proxy's own).
- **iptables PREROUTING REDIRECT** — steers inbound port 443 to the proxy listener (8443) without requiring client-side configuration.
- **`dotprefix` in Suricata rules** — prevents suffix-matching attacks (e.g., `evilgoogle.com` won't match a rule for `google.com`).
- **Two proxy implementations** — nginx (simple, well-known) and Envoy (richer observability). Only one is routed at a time; switch by updating the workload route table target.
