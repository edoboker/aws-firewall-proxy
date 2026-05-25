# Bypass vectors — protocols where SNI inspection cannot apply

This document enumerates protocols and TLS features where the proxy fundamentally cannot enforce its core guarantee (resolve SNI → verify destination IP).

**Policy across all of these: block, not bypass.** We do not attempt to "support" them — we configure the egress path so they cannot traverse it.

This is consistent with how major cloud security providers describe their own FQDN-rule firewalls. AWS Network Firewall, GCP Cloud NGFW, and Azure Firewall all explicitly document that FQDN-based filtering does **not** apply to QUIC or to traffic with encrypted SNI. We follow the same boundary.

## 1. QUIC / HTTP/3 (UDP/443)

QUIC runs over UDP and is not redirected by the proxy's TCP-only iptables rule. The TLS 1.3 ClientHello inside QUIC requires protocol-aware parsing that an SNI-peek TCP proxy does not perform.

**Mitigation:** block UDP/443 (and UDP/80) at AWS Network Firewall. Modern clients fall back to TCP-based HTTPS when QUIC is unreachable.

## 2. Encrypted ClientHello (ECH / formerly ESNI)

ECH encrypts the SNI under the server's HPKE public key (advertised via DNS HTTPS records). `ssl_preread` and Envoy's `tls_inspector` see only the outer ClientHello, whose outer SNI is a meaningless decoy for FQDN enforcement.

**Mitigation:** block traffic whose outer SNI is not on the allowlist. When the outer SNI happens to be allowlisted, we lose visibility into the real inner destination — the same boundary every SNI-based firewall in the industry hits.

Tracked separately in `production-grade-plan.md` §6.

## 3. TLS 1.3 session resumption without SNI

PSK-only resumption in TLS 1.3 permits the ClientHello to omit `server_name`. With no SNI, the proxy has no hostname to resolve.

**Mitigation:** reject (TCP RST / connection close). The client falls back to a full handshake on retry, at which point SNI is present and inspection proceeds normally.

## 4. Non-HTTPS TCP protocols carrying no FQDN

Raw TCP, gRPC over h2c without a higher-layer name binding, custom binary protocols. There is no field the proxy can bind a hostname to.

**Mitigation:** block by default at ANF (allowlist is TLS over TCP/443 only). See `production-grade-plan.md` §20 for the explicit non-goal statement.

## 5. Off-path DNS resolvers (DoT / DoQ / DoH)

If the workload can resolve a name without traversing the VPC `.2` resolver, the shared-cache guarantee collapses: the client's lookup never lands in the shared BIND9 cache, the proxy's later verification lookup is independent again, and both the determinism and the SNI-spoofing detection are lost. See `shared-dns-cache.md` §5.1.

**Mitigation:**
- **DoT (TCP/853) and DoQ (UDP/853)** run on distinct ports — drop both at ANF (`firewall.tf`, sids 8000–8001). Clients fall back to Do53, which the egress path controls.
- **DoH (HTTPS/443)** is indistinguishable from normal HTTPS by port, so it is *contained by existing controls*, not a dedicated rule: egress is SNI-allowlisted (so **never allowlist public DoH endpoints** like `dns.google` or `cloudflare-dns.com`), and DoH bootstrapped to a bare IP carries no SNI and is dropped by the `drop_no_sni` path in `check_sni.lua`.
