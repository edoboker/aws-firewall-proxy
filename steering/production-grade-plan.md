# Production-grade refactor plan

Items are listed in priority order. §1–§3 are the foundational sequence: decide the infra, prove it works, measure it.

## 1. Underlying infrastructure choice + config store

Decide the underlying infrastructure of the proxy. Is it EC2? Is it ECS? This has cascading consequences — launch templates + custom AMIs vs simple container images, ASG vs ECS service for self-healing, how the SDLC pipeline is shaped, how custom-proxy code (if pursued) is packaged.

Bundled with this: **which AWS service holds the FQDN allowlist configuration at runtime?** The answer is shaped by the infra decision (ECS task hot-reloading from Parameter Store vs AMI baked at build time vs sidecar pulling from AppConfig). Decide them together. The workflow/audit half of allowlist management lives in §11.

## 2. Organized testing directory

Have an organized testing directory with all sorts of tests: infrastructure tests (Terratest, terraform test), proxy behavior tests (SNI-spoof curl variants + automated equivalents), application simulation tests. Without this layer, no claim about correctness or performance is defensible.

## 3. Benchmarking scripts (with caching dimension)

Build benchmarking scripts that measure throughput, latency, and other relevant metrics. Scripts should be runnable against different technologies and implementations so solutions can be compared head-to-head.

Caching is a sub-dimension of this work, not a separate task: run the benchmarks with cache on vs off (DNS cache, connection cache) and report the delta.

## 4. Architecture diagrams

Must-have. Generate diagrams (ideally from code — `terraform graph`, cloudcraft, or hand-maintained drawio committed alongside the repo) covering: traffic flow, RT chain, the two proxy variants, and the centralized-egress reference architecture from §17. Cheap parallel win alongside §1 — drawing forces the infra decision to be concrete.

## 5. Exfiltration demo

Create a demo that uses existing exfiltration tools and shows they fail when the proxy is in place. High-impact deliverable for an interview submission — turns an abstract security claim into a visible result.

## 6. Complete SDLC / deployment pipeline

Build a complete SDLC solution for the deployment pipeline of these proxies, and demonstrate that when the proxy is updated, it is deployed automatically after being tested. Shape depends on §1.

## 7. Logging, metrics, observability

Focus on logging, metrics, and observability of the proxy. Measure KPIs such as:
- Added latency introduced by the proxy
- Cache hits
- Failures
- Detected attacks
- Repeating FQDNs / SNIs

## 8. DR / failover runbooks and service self-healing

Document what happens when both AZs lose the proxy, and the recovery path. Beyond the runbook, build self-healing into the service itself — health checks that auto-replace unhealthy instances, ASG-level remediation, etc. — so the runbook is the last resort, not the first.

## 9. High availability

Pick the HA topology:
- Single instance in each availability zone, counting on the workload being distributed across multiple AZs.
- Two instances per availability zone — likely requires AWS Gateway Load Balancer with the Geneve reverse tunnel set up.

Decide which model fits and document the trade-offs.

## 10. Capacity planning model

Once §3 benchmarks exist, build a sizing model: given N workload requests/sec at P95 latency budget X, how many proxy instances of type Y are needed. Without the benchmark numbers this is hand-waving, so it depends on §3.

## 11. Cost analysis

Per-GB cost analysis of egress traffic with the proxy in path. Compare against the no-proxy baseline to quote the security-vs-dollars trade-off concretely.

## 12. FQDN allowlist change management workflow

Workflow for adding/removing entries: PR approval, audit trail, who's authorized. (The runtime config-store decision is bundled into §1.)

## 13. Active response to detected SNI spoofing

Don't just log spoofing attempts — trigger automated response. Automation hooked into the log pipeline that can act on detection events (block source, alert, quarantine). The proxy stays a TCP-level SNI inspector — no TLS termination, so no cert-pinning risk — but the surrounding system reacts to what it sees.

## 14. DNS tunneling detection

Relevant once we allow wildcard FQDNs (`*.example.com`) in the allowlist. With a wildcard, an attacker can encode data in subdomains and exfiltrate via DNS — the proxy alone won't catch it. Need detection logic (entropy, query rate, label-length anomalies).

## 15. Encrypted SNI and TLS 1.3

Think about encrypted SNI (ESNI / ECH) support and what to do about TLS 1.3. See `bypass-vectors.md` for the current "block, not bypass" stance.

## 16. IPv6 support

Add IPv6 support to the proxy and the surrounding VPC plumbing. Low additional cost, broadens applicability.

## 17. Plaintext HTTP support (with explicit non-goals)

Extend the proxy to also handle plaintext HTTP — read the Host header, resolve it, forward to the DNS-resolved IP. **Explicit non-goals**: gRPC and raw TCP. Neither carries an FQDN that the proxy can compare against a resolved IP, so the core security guarantee can't be applied — they're out of scope, not "TODO later". See `http-support-backlog.md` for the design issues to resolve first.

## 18. Centralized egress account — reference architecture

The standard enterprise pattern is a shared egress VPC in a dedicated networking account, with workload VPCs peering in via Transit Gateway. Implementing this in the demo requires two accounts, which is too much overhead. Instead, write a **reference-architecture doc** that explains at a high level how the current single-account design would map to a centralized-egress topology — diagrams + a paragraph on TGW routing, account boundaries, IAM separation.

## 19. Audit log retention

Define retention durations and storage tiering for proxy logs, ANF logs, and DNS firewall logs. Long enough for forensic / compliance use.

## 20. Custom nginx / Envoy plugin to log resolved IPs (exploratory)

Write a custom plugin for nginx or Envoy that logs all resolved IP addresses. Provides the ability to detect attacks that use SNI spoofing — by recording what the proxy actually resolved versus what the client asked for, we get the data needed to surface the bypass attempts the proxy is silently fixing.

De-prioritized: the marginal narrative value over off-the-shelf logging is small until the foundation is solid.

## 21. Custom proxy implementation (exploratory)

Implement a custom proxy rather than using nginx or Envoy. Might give better control over traffic and better logging than what the off-the-shelf options expose.

De-prioritized: expensive, and the security claim doesn't depend on it.
