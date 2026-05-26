# Bypass vectors

This document enumerates protocols and TLS features where SNI-based override
forwarding and async spoofing detection have hard limits.

The current TLS path is prevention-first: nginx reads SNI with `ssl_preread` and
forwards to `$ssl_preread_server_name:443`, ignoring the client's original
destination IP. The async detector later compares `{SNI, original_dst}` against
current DNS answers. That later comparison is probabilistic and does not block.

## 1. QUIC / HTTP/3 (UDP/443)

QUIC runs over UDP and is not redirected by the proxy's TCP-only iptables rule.
The TLS 1.3 ClientHello inside QUIC requires protocol-aware parsing that this
TCP stream proxy does not perform.

**Mitigation:** block UDP/443 and UDP/80 at AWS Network Firewall. Modern clients
fall back to TCP-based HTTPS when QUIC is unreachable.

## 2. Encrypted ClientHello

ECH encrypts the real SNI. `ssl_preread` sees only the outer ClientHello, whose
outer SNI may be a decoy.

**Mitigation:** treat ECH as a known SNI-firewall boundary. The proxy can only
route by the visible outer SNI; the async detector can only evaluate that same
visible SNI against the original destination.

## 3. TLS session resumption without SNI

Some TLS resumption paths can omit `server_name`. With no SNI, nginx has no
hostname for `$ssl_preread_server_name:443`, so the override proxy cannot form a
valid upstream.

**Mitigation:** the connection fails closed at the proxy. Clients usually retry
with a full handshake that includes SNI.

## 4. Non-HTTPS TCP protocols carrying no FQDN

Raw TCP, gRPC over h2c without a higher-layer name binding, and custom binary
protocols have no hostname field the proxy can route by.

**Mitigation:** block by default at AWS Network Firewall. The override proxy is
for TLS over TCP/443.

## 5. Off-path DNS resolvers

The proxy no longer depends on matching the client's DNS answer for prevention,
because forwarding is based on proxy-side SNI resolution. Off-path DNS still
matters for detection quality: if a workload used a different resolver, the
original destination IP may not appear in the detector's later DNS answer set.

**Mitigation:** keep DoT (TCP/853) and DoQ (UDP/853) blocked at AWS Network
Firewall. DoH (HTTPS/443) must be controlled by the normal egress/FQDN policy;
do not intentionally allow public DoH endpoints unless that is an accepted
policy choice.
