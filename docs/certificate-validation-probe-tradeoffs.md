# Certificate-Validation Probe — Trade-offs and Positioning

## Context

One possible way to close the AWS Network Firewall SNI-spoofing gap is to have the proxy validate the destination IP by opening a separate TLS connection to that IP using the claimed SNI.

For example:

1. The workload opens a TCP connection to destination IP `X`.
2. The proxy peeks at the TLS ClientHello and extracts `SNI = google.com`.
3. Instead of relying only on DNS, the proxy opens its own side TLS connection to `X:443` with `SNI = google.com`.
4. If `X` presents a certificate valid for `google.com`, the proxy allows the original client connection to proceed.
5. If the certificate is invalid, mismatched, expired, or absent, the proxy blocks the connection.

This is not full TLS inspection because the proxy does **not** terminate or decrypt the client’s TLS session. The client can still perform an end-to-end TLS handshake directly with the destination. That means this approach avoids some of the compatibility problems of classic TLS inspection, especially certificate pinning and enterprise CA trust-store issues.

However, this approach is still **TLS-inspection-adjacent**. The proxy actively creates a TLS session to the destination as part of its security decision. That introduces latency, compute cost, destination-side side effects, and weaker detection semantics than the shared-DNS-cache design.

---

## One-sentence assessment

The certificate-validation probe is a useful **prevention-only** alternative, but it is weaker than shared DNS cache + SNI/original-destination verification if the goal is both **blocking spoofing** and **detecting spoofing with high confidence**.

---

## What the probe proves — and what it does not prove

The probe proves:

> “This destination IP can currently present a certificate that validates for the claimed SNI.”

It does **not** prove:

> “The workload legitimately resolved this FQDN to this IP through the controlled DNS path.”

That distinction is critical.

For large cloud providers, CDNs, SaaS platforms, and multi-tenant edge networks, many hostnames may terminate on overlapping infrastructure. An IP may be capable of serving a valid certificate for a given hostname even if the client did not actually resolve that hostname to that IP immediately before connecting.

So the certificate probe validates a **certificate-to-hostname relationship**, not a **DNS-answer-to-destination relationship**.

The shared DNS cache architecture is built around the latter claim: the workload and proxy both resolve through the same recursive cache, so the proxy can check whether the original destination IP belongs to the same answer set observed by the workload.

---

## Main disadvantages

### 1. Weak detection semantics

This is the biggest architectural disadvantage.

If the side TLS probe succeeds, the proxy cannot distinguish between:

1. legitimate traffic, where the workload resolved `google.com` to `X`; and
2. suspicious traffic, where the workload manually dialed `X`, and `X` happens to serve a valid certificate for `google.com`.

That means the probe can identify obvious failures, but it cannot reliably classify successful probes as legitimate client behavior.

It can tell you:

> “This destination cannot serve the claimed hostname.”

It cannot confidently tell you:

> “This workload spoofed the destination IP.”

For a product or assignment narrative focused on **prevention + detection**, this is a major weakness.

---

### 2. Higher latency than DNS validation

A DNS-based check usually requires one or more resolver queries. With a shared recursive cache, the proxy lookup should often be a local cache hit or at least a low-latency internal DNS path.

A certificate-validation probe requires substantially more work:

1. Open a TCP connection to the destination IP.
2. Send a TLS ClientHello with the claimed SNI.
3. Receive the ServerHello and certificate chain.
4. Validate the certificate chain and hostname.
5. Optionally perform revocation-related logic, depending on implementation.
6. Close the side connection.
7. Only then allow or reject the original client flow.

Even without revocation checking, this adds at least one outbound TCP/TLS handshake to the critical path. For high-volume egress, this is expensive.

---

### 3. Additional compute and connection pressure

Every client connection can create a second connection from the proxy to the destination.

This increases:

- proxy CPU usage;
- proxy memory usage;
- outbound connection count;
- ephemeral port pressure;
- NAT Gateway state;
- firewall state;
- destination-side connection attempts;
- TLS handshakes observed by external services.

A DNS comparison is mostly a control-plane lookup. A certificate probe is a real data-plane interaction with the remote destination.

---

### 4. The proxy contacts the suspicious destination before denying it

With DNS/shared-cache validation, the proxy can often decide before opening any connection to the destination.

With certificate probing, the proxy must contact the destination in order to decide.

That means even denied traffic may still produce an outbound connection attempt to a potentially malicious or attacker-chosen IP.

This weakens the clean security property:

> “Denied destinations are never contacted.”

Instead, the property becomes:

> “Denied destinations may still receive a TLS probe before the client flow is blocked.”

That is a meaningful difference in high-security egress environments.

---

### 5. Destination-visible side effects

The probe is visible to the remote server.

The destination may log:

- the proxy or NAT public IP;
- the SNI used in the probe;
- the TLS fingerprint of the proxy;
- incomplete TLS handshakes;
- repeated short-lived handshakes;
- probe timing and volume.

This creates an external behavioral footprint. It may also trigger rate limits, bot detection, anomaly detection, or abuse controls on SaaS/CDN providers.

DNS validation is much less intrusive because the authoritative destination is not necessarily contacted by the proxy as part of the decision.

---

### 6. Potential scanning-oracle / confused-deputy behavior

A compromised workload may be able to use the proxy as a certificate-scanning oracle.

Example attack shape:

```text
SNI = allowed.example.com
Destination IP = attacker-chosen IP
```

The proxy may then initiate a TLS probe to the attacker-chosen IP before deciding whether to allow the flow.

Even if the connection is ultimately blocked, the attacker has induced the proxy to perform network activity on their behalf. At scale, this can become a confused-deputy problem:

- internal workload controls an external scan target;
- proxy performs the probe;
- destination sees the proxy/NAT identity, not the original workload;
- logs now show the trusted egress infrastructure contacting arbitrary IPs.

This does not necessarily make the design invalid, but it is an important disadvantage compared with DNS-based validation.

---

### 7. More operational complexity

Correct TLS validation is not trivial.

The proxy now needs to handle:

- CA trust-store updates;
- intermediate certificate chain building;
- hostname verification;
- wildcard and SAN matching;
- IDNA/punycode names;
- expired certificates;
- clock skew;
- certificate revocation policy;
- TLS version compatibility;
- cipher-suite compatibility;
- ALPN behavior;
- IPv4/IPv6 behavior;
- error classification;
- retries and timeouts.

DNS comparison also has edge cases, but TLS validation has a larger compatibility surface and more ways to fail differently from the real client.

---

### 8. Probe behavior may differ from real client behavior

The proxy’s TLS stack is not necessarily identical to the workload’s TLS stack.

A real client and the proxy may differ in:

- TLS version support;
- cipher suites;
- ALPN values;
- certificate validation behavior;
- root CA set;
- support for legacy servers;
- mTLS behavior;
- client TLS fingerprint;
- SNI handling;
- timeout behavior.

This creates possible false positives and false negatives.

For example:

- The probe fails because the destination dislikes the proxy’s TLS fingerprint, but the real client would have succeeded.
- The probe succeeds, but the real client would fail due to certificate pinning or stricter trust behavior.
- The probe does not include the same ALPN values as the real client, so the server presents different behavior.

The proxy is now making a security decision based on a synthetic TLS session that may not faithfully represent the real client session.

---

### 9. It still does not solve hidden-SNI protocols

Certificate probing only helps if the proxy can read the intended hostname.

It does not solve:

- QUIC / HTTP/3 over UDP;
- Encrypted ClientHello / ECH;
- TLS handshakes without visible SNI;
- raw TCP protocols with no hostname;
- off-path DNS resolution that bypasses the controlled resolver path.

Those still need to be blocked or explicitly declared unsupported.

---

## Comparison with other approaches

| Design | Prevention | Detection | Latency | Contacts destination before decision? | Main weakness |
|---|---:|---:|---:|---:|---|
| Native NGINX override | Good | Poor | Low/medium | Yes | Silently removes spoofing signal |
| DNS fanout + compare | Medium | Medium | Medium | No | Probabilistic DNS false positives |
| Shared DNS cache + compare | Good | Good | Low/medium | No | Requires DNS-path control and cache coherence |
| Certificate-validation probe | Good-ish | Weak | High | Yes | Proves certificate serving, not DNS legitimacy |

---

## Example pseudo-flow

A simplified certificate-probe decision flow could look like this:

```pseudo
on_tls_client_hello(client_conn):
    sni = parse_sni(client_conn.client_hello)
    original_dst_ip = get_original_destination(client_conn)

    if sni is empty:
        deny(reason = "no_sni")

    if sni not in allowlist:
        deny(reason = "sni_not_allowed")

    probe_result = tls_probe(
        dst_ip = original_dst_ip,
        server_name = sni,
        timeout_ms = 1000,
        validate_hostname = true,
        validate_chain = true
    )

    if probe_result.valid:
        allow(reason = "cert_probe_valid")
    else:
        deny(reason = "cert_probe_failed")
```

The important observation is that the probe must contact `original_dst_ip` before the proxy can make the allow/deny decision.

---

## When the certificate probe may still be useful

The certificate probe is not useless. It may be reasonable when:

- DNS-path control is impossible;
- the environment prefers availability over precise spoofing detection;
- the goal is only to block obviously invalid SNI/IP combinations;
- connection volume is low enough that added latency and connection pressure are acceptable;
- external side effects are acceptable;
- the allowlist consists mostly of dedicated services rather than large multi-tenant CDNs;
- the system explicitly treats probe success as “acceptable destination attestation,” not as proof of legitimate DNS resolution.

In that framing, it is better described as:

> **Certificate-based destination attestation**

rather than:

> **SNI-spoofing detection**

---

## Recommended positioning for the presentation

I would position this as an alternative design, not as the recommended final architecture.

Suggested slide wording:

> **Alternative: Certificate-based destination attestation**  
> The proxy opens a side TLS connection to the original destination IP using the claimed SNI and validates the returned certificate. This avoids terminating the client TLS session, so it reduces certificate-pinning impact compared with full TLS inspection. However, it is latency-heavy, externally visible, compute-intensive, and mostly prevention-oriented. It proves that the destination can serve the claimed hostname, not that the workload reached an IP returned by the controlled DNS path.

Then contrast it with the recommended design:

> **Recommended: Shared DNS cache + SNI/original-destination verification**  
> Both workload and proxy resolve through the same managed recursive cache. The proxy can therefore compare the original destination IP to the same DNS answer set the workload likely used. This preserves both prevention and detection while avoiding a side TLS handshake to every destination.

---

## Final conclusion

The certificate-validation probe is clever, and it avoids the most invasive part of classic TLS inspection: terminating the client TLS session.

But it still has four fundamental disadvantages:

1. It is expensive in latency and compute.
2. It contacts the destination before deciding whether the destination is legitimate.
3. It creates externally visible probe traffic.
4. It gives weak detection because it validates certificate serving, not legitimate DNS resolution.

Therefore, it is best presented as a **prevention-only fallback** or **alternative destination-attestation strategy**, while the main recommendation remains:

> **Shared DNS cache + custom SNI/original-destination verification module.**

That design better fits the core goal: not only blocking SNI spoofing, but detecting and explaining when it happens.
