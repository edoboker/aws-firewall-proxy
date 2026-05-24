# HTTP support — design backlog

These are open design issues that must be resolved before implementing plaintext HTTP support (see `production-grade-plan.md` §20).

The TCP-peek-then-splice pattern that works for TLS does not translate cleanly to HTTP: HTTP allows multiple requests per connection, ambiguous framing, and a few legitimate Host-less request shapes. Each item below requires an explicit decision.

## 1. HTTP/1.1 keep-alive with multiple Hosts on one connection

RFC-legal; rare in practice but possible. After the first request locks the connection to one upstream IP, subsequent requests with a different `Host:` header land on the wrong server or 404. Allowed→allowed transitions fail silently; allowed→blocked is still blocked (the connection never reaches the forbidden IP).

**Decision needed:** parse every request (real HTTP proxy) or accept the inconsistency (peek-once).

## 2. HTTP/2 cleartext (h2c) — multiple `:authority` per connection

Same issue as §1, but is a design feature of h2 rather than an edge case. Largely irrelevant for general egress (h2c is uncommon outside service meshes), but the answer depends on whether the workload uses h2c deliberately.

## 3. Absolute-form request URIs

`GET http://example.com/path HTTP/1.1` puts the host in the request line, not the `Host:` header. The parser must read both, or the proxy must reject absolute-form requests outright.

## 4. HTTP/1.0 requests without Host header

No FQDN → no resolution possible.

**Policy:** block. Affects only legacy embedded clients; tolerable.

## 5. Bare-IP Host header (`Host: 1.2.3.4`)

No FQDN → the security model cannot be enforced.

**Policy:** block. Without this, the entire HTTP guarantee collapses — an attacker writes any IP and reaches any IP.

## 6. HTTP request smuggling (CL.TE / TE.CL desync)

The moment the proxy parses HTTP, it participates in framing-disagreement attacks between proxy and origin.

**Policy:** strict framing — reject requests with ambiguous `Content-Length` / `Transfer-Encoding` combinations.
