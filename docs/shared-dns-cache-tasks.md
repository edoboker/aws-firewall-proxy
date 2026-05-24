# Shared DNS cache — implementation task list

Breakdown of the feature in `shared-dns-cache.md` into discrete tasks. Each task has a
single owner-able scope, can be implemented on its own branch, and has a verification
step that can be run **without** the other tasks being finished (mocked/standalone where
the real dependency isn't there yet). Section refs (§) point at `shared-dns-cache.md`.

## Dependency overview

```
T1 BIND9 AMI ─────────────┐
                          ▼
T2 DNS VPC + BIND9 ──► T3 Peering+routes ──► T4 Resolver fwd rule ──┐
                                                                    ├─► T7 E2E determinism
T5 Proxy attitude (AppConfig) ──────────────────────────────────────┤
T6 Block DoT/DoQ at ANF ─────────────────────────────────────────────┘
```

Parallelizable from the start: **T1**, **T5**, **T6** (no deps on each other). **T2→T3→T4**
is a strict chain. **T7** is the integration gate and runs last.

A global toggle `enable_shared_dns` (default `false`) gates the whole new stack (T2–T4)
so the existing single-VPC deploy stays green while tasks land incrementally.

---

## T1 — BIND9 golden AMI (Packer)

**Goal:** a baked recursive-resolver AMI, built the same way as the existing proxy/workload images.

**Scope / files:** new `packer/bind-dns/` — `bind-dns.pkr.hcl` (AL2023 base,
`ami_name_prefix = "aws-firewall-proxy-bind-dns"`), `provision.sh` (install + enable
`named`), `assets/named.conf` (+ systemd), `assets/README.md`. Recursion on; `allow-query`
restricted to the workload VPC CIDR; `min-cache-ttl` / serve-stale per §4.1. (§7.1)

**Depends on:** nothing.

**Verify standalone:** `packer build` succeeds and tags the AMI. Launch one instance;
`dig @<bind-ip> google.com` returns A records; a second identical query is a cache hit
(TTL counts down / cache stats show it). Confirm a short-TTL record still resolves on a
follow-up query within the `min-cache-ttl` window. `dig` from outside the allowed CIDR is
refused.

---

## T2 — DNS VPC + BIND9 instance (Terraform)

**Goal:** stand up the second VPC and run the BIND9 AMI in it, with its own egress for recursion.

**Scope / files:** `dns_vpc.tf` (VPC `var.dns_vpc_cidr`, subnet, IGW/NAT, RT),
`dns_server.tf` (BIND9 `aws_instance` from new `data.aws_ami.bind_dns`, SG: ingress 53
udp/tcp from workload VPC CIDR, egress for recursion), `main.tf` (AMI data source),
`variables.tf` (`dns_vpc_cidr`, `dns_subnet_cidr`, `bind_instance_type`,
`bind_min_cache_ttl`, `enable_shared_dns`). Gate new resources with `count`/the toggle. (§7.3–7.4)

**Depends on:** T1 (AMI must exist to launch; TF can be written in parallel, tested after).

**Verify standalone:** `terraform validate` + `plan` clean with `enable_shared_dns=true`
and a no-op `plan` with it `false`. After `apply`, the BIND9 instance is running and, from
inside the DNS VPC (EIC), `dig @localhost google.com` recurses to the internet. Static
assertions added to `tests/test_terraform_static.py`.

---

## T3 — VPC peering + routes

**Goal:** make BIND9 reachable from the workload VPC.

**Scope / files:** `peering.tf` (`aws_vpc_peering_connection` + accepter), `routes.tf`
(per-direction routes for the two CIDRs), SG adjustments so the outbound-endpoint
ENIs/workload VPC can reach BIND9:53. (§7.3–7.4)

**Depends on:** T2.

**Verify standalone:** from a workload-VPC host, `dig @<bind-private-ip> google.com`
succeeds (proves peering route + SG allow 53). Cross-VPC `ping`/TCP 53 reachability check.

---

## T4 — Route 53 Resolver outbound endpoint + forwarding rule

**Goal:** force allowlisted DNS from the workload VPC through `.2` → BIND9, sharing the cache.

**Scope / files:** `dns_resolver.tf` — `aws_route53_resolver_endpoint` (`OUTBOUND`) + its
SG, `aws_route53_resolver_rule` (`FORWARD`, `forwarded_domains` default `var.allowed_fqdns`,
`target_ip` = BIND9), `aws_route53_resolver_rule_association` to the workload VPC.
Document the autodefined-rule caveat for `amazonaws.com` (§7.6). (§7.3)

**Depends on:** T2, T3.

**Verify standalone:** from a workload host, `dig google.com` (default `.2` resolver) is
served by BIND9 — confirm via BIND9 query log / cache populated. A **non-allowlisted**
domain still returns NXDOMAIN (DNS Firewall, not forwarded). `amazonaws.com` is **not** in
BIND9's query log (autodefined path — expected, §7.6). Note: outbound endpoint needs ≥2
IPs/AZs (§9.2) — handle or document in single-AZ.

---

## T5 — Proxy attitude switch (AppConfig)

**Goal:** let Terraform flip the proxy between `fanout` and `shared-cache` resolution with no AMI change.

**Scope / files:** `variables.tf` (`proxy_dns_mode` = `"fanout"` | `"shared-cache"`),
`appconfig.tf` — in `shared-cache` mode set `dns.resolvers = ["169.254.169.253"]` and
`queries_per_sni = 1`; otherwise keep the current fanout list. Validate against the
existing JSON schema. (§5, §7.2, §7.4)

**Depends on:** nothing (pure policy); end-to-end meaning arrives with T4.

**Verify standalone:** with `proxy_dns_mode=shared-cache`, the rendered
`aws_appconfig_hosted_configuration_version` content has the single resolver +
`queries_per_sni=1` and passes schema validation. On a running proxy, the synced
`/etc/nginx/lua/proxy_runtime_policy.lua` reflects it. Flipping back to `fanout` restores
the multi-resolver list. `tests/test_appconfig_policy_schema.py` extended.

---

## T6 — Block off-path resolvers (DoT / DoQ) at ANF

**Goal:** close the side channels that would let the workload resolve without BIND9 (§5.1).

**Scope / files:** `firewall.tf` — ANF rules dropping TCP/853 and UDP/853. Cross-link
`bypass-vectors.md`; note the DoH containment posture (no new rule — relies on the SNI
allowlist + `drop_no_sni`). (§5.1, §7.4)

**Depends on:** nothing.

**Verify standalone:** from a workload host, a DoT query (`kdig +tls @1.1.1.1`) and a
UDP/853 query both fail/timeout; ordinary Do53 still works. Confirm no public DoH endpoint
is present in `allowed_fqdns`.

---

## T7 — End-to-end determinism verification

**Goal:** prove the feature does what it claims — the issue #4 false positive is gone, real spoofing still caught.

**Scope / files:** extend `tests/` (e.g. a shared-cache variant of `test_sni_spoofing.py`)
and the benchmark. Document the two modes in `README.md`; cross-link from
`docs/production-grade-plan.md` and resolve the open question in issue #4. (§7.5)

**Depends on:** T1–T6.

**Verify:** in `shared-cache` mode, repeatedly connect to a short-TTL allowlisted CDN
domain through the proxy → **zero** `decision=mismatch` false positives over N runs (vs. a
measurable rate in `fanout`). Re-run the spoofing benchmark scenario → a genuine
client-dialed-wrong-IP case is still flagged `mismatch` (true positive preserved). Capture
both numbers in the benchmark results.
