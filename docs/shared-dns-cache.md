# Shared DNS cache — making SNI/dst-IP verification deterministic

> Low-level design + repo-change notes. The product-level requirements live in the
> companion GitHub issue. This file is the "how and why"; the issue is the "what".

## 1. The problem this closes

The proxy's core guarantee is: parse the SNI from the ClientHello, resolve it, and
allow the connection only if the original destination IP is one of the resolved
A-records (`packer/nginx-proxy/assets/nginx/lua/check_sni.lua`).

That comparison is only sound if the proxy resolves the SNI to **the same answer set
the client used**. Today it does not, and cannot guarantee it:

1. The workload resolves `google.com` → it gets some IP `A` (from a rotating CDN/round-robin RRset) and connects to `A`.
2. A moment later the proxy independently resolves `google.com` to verify. For a short-TTL, many-IP domain it may observe a *different* subset `{B, C}` that does not contain `A`.
3. The proxy sees `dst_ip = A ∉ {B, C}` and flags **SNI spoofing** on a perfectly legitimate request.

This is a real, observed false positive — see issue **#4** ("Investigate DNS false
positives in SNI/original-dst verification"). Its closing comment states the open
question plainly: *"a broader DNS truth issue where no recursive resolver can
guarantee the full set a client may have seen."* This feature is the answer to that
question.

## 2. Why the current mitigation is probabilistic (and why that's not enough)

Issue #4 was mitigated, not solved. The implemented strategy (option 3 in that issue)
is **DNS fanout**: query several recursive resolvers (`169.254.169.253`, `1.1.1.1`,
`8.8.8.8`), repeat `queries_per_sni` times each (default 3), follow CNAMEs, and union
all observed A-records before comparing. Delivered at runtime via AppConfig
(`appconfig.tf` → `local.proxy_runtime_policy.dns`).

The issue comment is explicit about the ceiling:

> *This is a false-positive reduction strategy, not a proof strategy. Even with
> multiple resolvers and repeated queries, the proxy still cannot guarantee it has
> seen every IP a client may have legitimately received for a CDN-style domain.*

Fanout widens the observed set but is still **sampling a moving target**. It also has a
second cost surfaced in issue **#19**: every connection emits `queries_per_sni × N`
live DNS queries, and the VPC `.2` resolver enforces a hard **1024 packets/sec per
ENI** limit. Fanout makes the proxy's first collapse mode (resolver throttling) arrive
sooner. See `docs/scaling-in-production.md`.

So fanout trades correctness *and* throughput for a probability. We want determinism.

## 3. The rejected alternative: "override mode"

One previously-discussed option is **override mode**: the proxy ignores the client's
destination entirely, resolves the SNI itself, and forwards to *its own* resolution.
If the SNI is allowlisted, the proxy picks a valid IP and the connection just works —
no false positives, ever.

We reject this as the primary design because **it deletes the detection signal**. The
proxy can no longer tell a spoofed destination from a legitimate one; it silently
rewrites both. The whole point of the product (closing the ANF SNI-spoofing bypass *and
knowing when someone tries it*) evaporates. Override mode may still be useful as an
opt-in "availability over visibility" mode later, but it is not this feature.

## 4. The solution: one recursive cache shared by client and proxy

**Core insight:** the verification is only racy because the client and the proxy
resolve *independently*. If both resolve through the **same caching recursive
resolver**, the proxy's lookup hits the cache entry the client's lookup just populated
and reads back the **identical RRset** — within the cache's TTL window.

Concretely:

1. The workload resolves `google.com`. The query is steered to a dedicated **BIND9**
   recursive resolver, which fetches the RRset upstream, **caches the full set**, and
   returns it. The client connects to one of those IPs.
2. The workload generates traffic; the proxy intercepts it and resolves the same SNI —
   also via BIND9. Because the entry is still cached, BIND9 returns the **same RRset**,
   which is guaranteed to contain the IP the client chose.
3. `dst_ip ∈ resolved` holds for legitimate traffic. A genuine spoof (client dialed an
   IP that is *not* in the SNI's real RRset) still mismatches → **detection is
   preserved**.

This converts a probabilistic comparison into a near-deterministic one, and as a bonus
collapses the proxy's DNS load to a single cached lookup per SNI (directly relevant to
issues #19 and the PPS ceiling).

### 4.1 The one edge case: TTL skew

The guarantee holds only while the client and the proxy read the *same* cache entry.
It breaks in one situation:

- The client caches a result locally with the **authoritative TTL** (say 300s).
- BIND9 evicts its copy sooner (e.g. a low `max-cache-ttl`, or the authoritative TTL is
  short and BIND9 honored it).
- The proxy resolves *after* BIND9's entry expired but *before* the client re-resolves.
  BIND9 fetches a **fresh** RRset (CDN rotated), which may not contain the client's
  still-valid IP → false positive returns.

**Mitigation:** make BIND9's effective cache lifetime ≥ the longest TTL any client will
hold. Tunables:
- `min-cache-ttl` — floor the cache lifetime so short-TTL CDN records still stick around
  long enough for the proxy's follow-up lookup.
- `serve-stale` (`stale-answer-ttl` / `stale-cache-enable`) — keep serving the last good
  RRset briefly past expiry, which is exactly the "proxy lags the client" window.

These are knobs in BIND9's `named.conf`, baked into the BIND9 AMI and ideally surfaced
as Packer/Terraform variables. The residual risk (client TTL longer than our configured
ceiling) is documented, not eliminated — same honesty as the fanout caveat.

## 5. Architecture

```
        ┌──────────────────────── workload VPC (10.0.0.0/16) ────────────────────────┐
        │                                                                             │
        │  workload ──DNS──► .2 Route 53 Resolver ──┬─ DNS Firewall (allow/deny)      │
        │  (10.0.1)         (169.254.169.253)       │  (dns_firewall.tf, unchanged)   │
        │                                           │                                 │
        │                                           └─ Resolver FORWARD rule          │
        │                                              (allowed_fqdns → BIND9)         │
        │                                                     │                        │
        │  proxy ──DNS(SNI)──► .2 Resolver ───────────────────┤  outbound endpoint     │
        │  (10.0.2)                                            │  (ENIs in workload VPC)│
        │                                                      ▼                        │
        └──────────────────────────────────────────────── VPC peering ───────────────┘
                                                               │
        ┌──────────────────────── DNS VPC (10.1.0.0/16) ───────┼───────────────────────┐
        │                                                      ▼                         │
        │                                  BIND9 recursive resolver (10.1.x)             │
        │                                  - caches full RRsets (min-cache-ttl)          │
        │                                  - recurses upstream via its own NAT/IGW       │
        │                                    (NOT via workload VPC .2 → no loop)         │
        └────────────────────────────────────────────────────────────────────────────┘
```

Key properties:

- **Both client and proxy resolve through `.2`**, and `.2` forwards the
  allowlisted domains to BIND9 via the Resolver rule. Neither talks to BIND9 directly,
  so the shared cache is the single source of truth and the **DNS Firewall stays in the
  path** (defense in depth preserved — verify ordering during implementation; see §9).
- **The proxy's "shared-cache attitude" is purely runtime policy**: set the AppConfig
  `dns.resolvers` to `["169.254.169.253"]` and `dns.queries_per_sni` to `1`. No fanout
  needed — the cache, not repetition, provides completeness.
- **BIND9 lives in a separate VPC.** A Resolver forwarding rule is VPC-scoped and
  applies to *every* source in the associated VPC. If BIND9 sat in the workload VPC and
  recursed through `.2`, its own upstream queries would match the rule and loop back to
  itself. A separate, unassociated DNS VPC means BIND9 recurses cleanly to the internet
  and never sees the rule. This is also AWS's documented centralized-DNS pattern.

### 5.1 Integrity precondition: the workload must have no off-path resolver

The shared cache is authoritative only if it is the **only** way the workload can
resolve a name. Any channel that lets the client resolve *without* traversing
`.2 → forwarding rule → BIND9` bypasses the cache: the client's lookup never lands in
BIND9, the proxy's later lookup is independent again, and **both the determinism and the
spoofing detection are lost**. Two side channels must be closed — same "block, not
bypass" stance as `bypass-vectors.md`:

- **DoT / DoQ (DNS over TLS, TCP/853; DNS over QUIC, UDP/853).** Distinct ports — drop
  both at ANF. Clients fall back to Do53 (which we control). UDP/853 also rides the
  UDP-block posture already taken against QUIC.
- **DoH (DNS over HTTPS, HTTPS/443).** Indistinguishable from normal HTTPS by port, so it
  is *contained by existing controls* rather than a dedicated block: (a) egress is
  allowlisted by SNI, so a DoH provider only works if its domain is on `allowed_fqdns` —
  therefore **never allowlist public DoH endpoints** (`dns.google`,
  `cloudflare-dns.com`, `mozilla.cloudflare-dns.com`, …); (b) DoH bootstrapped to a bare
  IP carries no SNI and is already dropped by the `drop_no_sni` path in `check_sni.lua`.
  Optionally also NXDOMAIN the Firefox canary `use-application-dns.net` so browsers
  auto-disable DoH.

If either channel is left open, the feature degrades silently — no error, just a
resolver path the proxy can't see. Treat closing them as part of the feature, not a
follow-up.

## 6. Why this "changes the deployment drastically"

This is not an in-place tweak; it adds a whole DNS tier and a second VPC:

- A second VPC + subnet + its own egress (IGW/NAT) so BIND9 can recurse.
- VPC peering (or TGW) between the workload VPC and the DNS VPC, with routes on both
  sides and security groups opening UDP/TCP 53 from the outbound-endpoint ENIs to BIND9.
- A Route 53 Resolver **outbound endpoint** in the workload VPC + a **forwarding rule** +
  a rule association.
- A new BIND9 golden AMI (new Packer config).

Cost/operational notes to keep visible: an outbound endpoint is billed hourly per ENI,
peering adds cross-VPC data charges, and BIND9 is now a stateful-ish dependency on the
egress path (its availability gates DNS for the whole workload VPC).

## 7. Repo changes

Mirrors the existing flat-Terraform + per-AMI-Packer conventions. Nothing here is built
yet — this section is the implementation map for the issue.

### 7.1 New Packer config — `packer/bind-dns/`
Model on `packer/nginx-proxy/`:
- `bind-dns.pkr.hcl` — AL2023 base, `ami_name_prefix = "aws-firewall-proxy-bind-dns"`,
  same `git_sha` / `packer_vpc_id` / `packer_subnet_id` vars.
- `provision.sh` — install `bind` (named), enable + start the service.
- `assets/named.conf` (+ systemd unit) — recursion on; `allow-query` restricted to the
  workload VPC CIDR; `min-cache-ttl` / serve-stale per §4.1; forwarders or full
  recursion for upstream.
- `assets/README.md` — short note, consistent with the other Packer dirs.

### 7.2 Proxy AMI — **unchanged** (decided)
There is **no second proxy image**. It is the same proxy; only the DNS resolver it is
told to use changes, and that is a runtime-policy change delivered via AppConfig (§5).
The shared-cache "attitude" = set `dns.resolvers = ["169.254.169.253"]` and
`queries_per_sni = 1`; the fanout "attitude" = the current multi-resolver list. So
`packer/nginx-proxy/` is untouched, and the only new Packer config is the BIND9 AMI
(§7.1).

### 7.3 Terraform — new files
- `dns_vpc.tf` — second VPC (`var.dns_vpc_cidr`, e.g. `10.1.0.0/16`), subnet, IGW + NAT
  (or IGW-only if BIND9 gets a public IP for recursion), route table.
- `dns_server.tf` — BIND9 `aws_instance` from a new `data.aws_ami.bind_dns`, its SG
  (ingress UDP/TCP 53 from the outbound-endpoint ENIs / workload VPC CIDR), IAM profile
  if SSM/CloudWatch parity is wanted.
- `dns_resolver.tf` — `aws_route53_resolver_endpoint` (direction `OUTBOUND`) in the
  workload VPC + its SG (egress 53 to BIND9); `aws_route53_resolver_rule` (`FORWARD`,
  `domain_name` per forwarded set, `target_ip` = BIND9); `aws_route53_resolver_rule_association`
  to the workload VPC.
- `peering.tf` — `aws_vpc_peering_connection` (workload ↔ DNS VPC) + accepter.

### 7.4 Terraform — edits to existing files
- `main.tf` — add `data.aws_ami.bind_dns` (tag `Name=aws-firewall-proxy-bind-dns`),
  matching the existing AMI data-source pattern.
- `routes.tf` — peering routes both directions (workload VPC ↔ DNS VPC CIDRs).
- `variables.tf` — `dns_vpc_cidr`, `dns_subnet_cidr`, `bind_instance_type`,
  `bind_min_cache_ttl`, `forwarded_domains` (default: `var.allowed_fqdns`), and a mode
  selector `proxy_dns_mode` (`"fanout"` | `"shared-cache"`). Consider `enable_shared_dns`
  to gate the whole second-VPC stack with `count`, so the existing single-VPC deploy
  still works untouched.
- `appconfig.tf` — when `proxy_dns_mode = "shared-cache"`, set
  `local.proxy_runtime_policy.dns.resolvers = ["169.254.169.253"]` and
  `queries_per_sni = 1`. This is the entire "switch the proxy's attitude" mechanism.
- `dns_firewall.tf` — review only; the rule group stays associated to the workload VPC.
  Confirm firewall-vs-forwarding ordering (§9).
- `firewall.tf` — add ANF rules to **drop DoT/DoQ** (TCP/853 and UDP/853) so the workload
  cannot resolve off-path (§5.1). Cross-link `bypass-vectors.md`.
- `outputs.tf` — BIND9 private IP, resolver endpoint id, rule id, peering id.
- `terraform.tfvars.example` / `variables.tf` defaults — document the new knobs.

### 7.5 Tests + docs
- `tests/test_terraform_static.py` — assert the forwarding rule, rule association,
  outbound endpoint, peering, and BIND9 SG exist when `enable_shared_dns` is on.
- A runtime/smoke test that, in shared-cache mode, the proxy resolves via `.2` and a
  short-TTL CDN domain no longer false-positives (the scenario from issue #4).
- `README.md` — document the two DNS modes and how to switch.
- Cross-link this file from `docs/production-grade-plan.md` and as the resolution of the
  open question in issue #4.

### 7.6 Constraint on the forwarding rule — AWS autodefined system rules

Route 53 Resolver applies **autodefined system rules** that take precedence for a set of
names, and **an outbound forwarding rule does not apply to them**:
<https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/resolver-overview-forward-vpc-to-network-autodefined-rules.html>

This set notably includes **`amazonaws.com`** (plus AWS-internal zones, `localhost`, the
VPC's `*.compute.internal`, and the private/`169.254` reverse-DNS zones). Our default
`allowed_fqdns` contains `amazonaws.com`, so queries for AWS service endpoints will **not**
be forwarded to BIND9 — they resolve on the autodefined path via Amazon DNS,
independently for client and proxy. Implications:

- **For AWS service domains this is fine, even desirable.** The proxy's own dependencies
  (AppConfig, SSM) keep resolving normally, and these endpoints are stable enough that the
  §1 race is a non-issue in practice.
- **But the shared-cache guarantee does not cover them.** They silently fall back to
  independent resolution — so if a future allowlist entry is both autodefined *and*
  CDN-rotated, it would not get the §4 determinism.
- **Action:** enumerate which `allowed_fqdns` entries fall under autodefined rules. For
  each, decide: tolerate independent resolution (the right call for AWS endpoints), or
  create a more-specific overriding forward rule. Verify override-ability against the doc
  first — some autodefined domains are protected and **cannot** be overridden.

## 8. Decided design points (recap)

- **Forwarded scope:** forward only `allowed_fqdns` (+ subdomains) to BIND9. Everything
  else is already denied by the DNS Firewall (`dns_firewall.tf`), so there is nothing
  legitimate left to share-cache. Non-allowed domains never need to reach BIND9.
- **No second proxy image** (§7.2). The attitude switch is AppConfig-only.

## 9. Open questions to settle before/while building

1. **DNS Firewall ordering** — verify the Resolver evaluates the DNS Firewall rule group
   *before* applying the forwarding rule, so a blocked domain is never forwarded to
   BIND9. Confirm against AWS behavior during implementation; don't assume.
2. **Resolver endpoint HA in a single-AZ deploy** — an outbound endpoint requires **≥ 2
   IP addresses**, normally across 2 AZs. This project is single-AZ
   (`var.availability_zone`). Either add a second subnet/AZ just for the endpoint, or
   accept two ENIs where the platform allows it. Note: the two-AZ build (§10) makes this
   requirement fall out naturally.
3. **BIND9 availability / cache coherence at scale** — a single instance is a SPOF on the
   egress DNS path; but adding a second instance is *not* free, because two recursive
   caches are not coherent (§10). Resolve the HA-vs-determinism tension explicitly.

## 10. Scaling to two AZs

The base infrastructure going multi-AZ (proxy, firewall, subnets, NAT GW, route tables
replicated per AZ) is tracked separately in issue **#14**. This section covers only what
the **DNS tier** of *this* feature adds on top of that, because it has a non-obvious
catch.

### 10.1 What replicates
A symmetric two-AZ build duplicates the per-AZ egress path:

- **2 workload subnets** — one per AZ, each with its own workload instance.
- **2 proxies** — one per AZ; each AZ's workload route points at its local proxy ENI.
- **2 BIND9 servers** — the DNS VPC gets a subnet per AZ, one BIND9 each.
- **Outbound endpoint → 2 ENIs across 2 AZs.** This is exactly the `≥ 2 IPs in 2 AZs`
  shape Resolver wants, so the single-AZ friction in §9.2 disappears here.
- VPC peering stays a single connection (peering is not AZ-scoped); just add the per-AZ
  CIDR routes.

### 10.2 The catch: two caches are not one cache
The whole guarantee in §4 rests on the client and the proxy reading **the same cache
entry**. Two BIND9 servers have **two independent recursive caches that do not
replicate**. So the determinism guarantee holds *per cache*, not across the fleet.

The failure mode: a client's resolution populates cache **A**, but the proxy's
verification query for the same flow is forwarded to cache **B**. If B is cold (or holds
a different CDN RRset), the proxy may not see the client's IP → the false positive this
feature was built to kill comes back. A single VPC-associated `FORWARD` rule with two
`target_ip`s does **not** give source-AZ affinity — Resolver distributes across targets
without guaranteeing the client and the proxy land on the same one.

### 10.3 Design response: AZ-local resolution paths
Keep each AZ self-contained: the workload, its proxy, **and** the BIND9 they resolve
through all live in (or pin to) the same AZ, so a given flow's client query and proxy
verify-query hit the **same** cache. Then the §4 guarantee holds *within* each AZ, and
the only residual divergence is between the two AZ-local caches — which only matters if
one flow is split across AZs, which AZ-local routing prevents.

The hard part is making the forwarding actually AZ-affine. Options, to be decided at
implementation:

- **Per-AZ forwarding** — separate rule/endpoint wiring so AZ-A queries only ever target
  BIND9-A and AZ-B only BIND9-B. Cleanest semantically, more moving parts; needs
  verification that Resolver can be constrained this way (a single VPC-scoped rule
  cannot, on its own).
- **Best-effort + high `min-cache-ttl`** — accept fleet-level distribution but floor the
  cache lifetime so both caches converge to the same RRset for popular domains. Cheaper,
  weaker guarantee; quantify the residual divergence rather than assume it away.
- **Single shared BIND9 even in 2-AZ** — keep one cache for coherence, accept it as a
  cross-AZ SPOF + cross-AZ DNS latency/data cost. Trades HA back for determinism.

Whichever is chosen, state the guarantee honestly: two-AZ buys availability but, unless
resolution is strictly AZ-affine, slightly relaxes the determinism the single-cache
design provides.

### 10.4 Cost / ops at 2 AZs
Doubles BIND9 instances and proxy/workload instances, adds a second outbound-endpoint
ENI (billed per ENI-hour), and introduces cross-AZ data charges on any DNS or peering
traffic that crosses an AZ boundary. Fold into the sizing in
`docs/scaling-in-production.md`.

## 11. Non-goals

- Not changing the ANF FQDN allowlist or the DNS Firewall *semantics* — only inserting a
  shared recursive cache behind them.
- Not implementing override mode (§3).
- Not solving TTL skew beyond the `min-cache-ttl` / serve-stale ceiling (§4.1); residual
  risk is documented.
- Not building the base multi-AZ infrastructure here — that is issue #14; §10 only covers
  this feature's DNS-tier additions on top of it.
