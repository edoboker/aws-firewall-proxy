# Scaling in production

This document records the known scaling limits of the current proxy design and why,
as configured, it is **not yet recommended for production load**. It is the narrative
companion to the capacity-planning work in `production-grade-plan.md` §3/§10.

Context for the numbers below: the deployed proxy is a single **t3.small**
(`terraform/nginx_proxy.tf`, `var.proxy_instance_type`) — 2 vCPU burstable, 2 GiB RAM,
one ENI. The proxy is a **transparent SNI inspector**: TLS is never terminated, so the
usual #1 proxy cost (handshake/crypto) is absent and the bottlenecks shift to DNS,
connection slots, and the burstable-instance budget.

## 1. DNS resolver rate limit (the first thing that breaks)

Every proxied connection triggers a **live DNS resolution with no caching**.
`assets/nginx/lua/check_sni.lua` (`resolve_sni_addresses`) calls
`resty.dns.resolver:new()` and queries the configured resolvers — `queries_per_sni × N
resolvers` — on **every connection**. There is no `lua_shared_dict` cache, so the same
SNI is re-resolved on every new connection. A second resolution then happens in nginx
core for `proxy_pass $client_sni:443` (that one *is* cached via `resolver ... valid=10s`).

This collides with a hard AWS limit. The VPC `.2` / `169.254.169.253` Route 53 Resolver
enforces **1024 packets per second per network interface**, regardless of instance size:

> https://docs.aws.amazon.com/vpc/latest/userguide/AmazonDNS-concepts.html#vpc-dns-limits

Because the uncached Lua path emits at least one query per connection (often several,
given `queries_per_sni` and multiple resolvers), the **new-connection rate caps at
roughly a few hundred connections/second** before the resolver begins dropping packets
(surfaced as `Linklocal_allowance_exceeded` on the ENI). Once packets drop,
`resolver:query` (`retrans=2, timeout=1500`) stalls inside preread for up to ~3s per
connection — which then cascades into connection-slot exhaustion (§2).

**Why this makes the current design unfit for production:** the ceiling is set by an
AWS per-ENI limit that **you cannot scale up by resizing the instance**. The only ways
through it are (a) cache DNS so repeated SNIs don't re-query, (b) spread load across more
ENIs/instances, or (c) point at a resolver that isn't the rate-limited `.2` address. The
design needs (a) before it can be trusted under real load.

- Tracked: **#19 — add a Lua-level DNS cache in the proxy preread guard.**
- Related correctness caveat (answer variability for CDN domains): see the
  "DNS Matching Caveat" section in the top-level `README.md`.

## 2. nginx connection slots

Concurrency is bounded by `worker_connections 1024` (`assets/nginx/conf/nginx.conf.template`)
with `worker_processes auto`. A **stream session consumes two** connection structures
(downstream client + upstream), so the effective ceiling is
`worker_connections × workers ÷ 2` — about **1024 concurrent sessions** on a 2-vCPU box.
`LimitNOFILE=65536` (`assets/systemd/nginx.service`) is generous, so file descriptors are
*not* the limit; the connection structures are.

`proxy_timeout 600s` compounds this: idle sessions are held for 10 minutes, so slots
reclaim slowly. The long timeout is currently necessary to support long-lived streams
(gRPC/SSE/WebSocket — see `backlog.md` #3), so it can't simply be cut.

This is the **collapse mechanism** that the DNS limit (§1) triggers: when resolution
starts timing out, each new connection holds its slot in preread for up to ~3s; at a few
hundred conn/sec the ~1024 slots are exhausted within seconds and nginx stops accepting.

- Tracked: **#20 — tune nginx connection slots and `proxy_timeout` for production concurrency.**

### conntrack (a downstream consequence, not yet a limit)

The iptables `PREROUTING REDIRECT` (`provision.sh`) puts every connection into
`nf_conntrack`. At ~1024 sessions this is comfortable — well under the default
`nf_conntrack_max` (~65k+ on a 2 GiB host). conntrack only becomes a real limit **if
`worker_connections` is raised significantly** (§2); at that point `nf_conntrack_max` and
the conntrack TCP timeouts (default established timeout is 5 days) must be tuned, or
entries will accumulate behind the 600s `proxy_timeout`.

## 3. Instance sizing (and the build-vs-deploy mismatch)

The two instance types in the repo are deliberately different and worth calling out:

| Role | Type | Defined in |
| --- | --- | --- |
| AMI build (Packer) | `c6i.large` | `packer/nginx-proxy/nginx-proxy.pkr.hcl` (`var.instance_type`) |
| Deployed proxy | `t3.small` | `terraform/nginx_proxy.tf` (`var.proxy_instance_type`) |

The build box is non-burstable to compile OpenResty quickly; the deployed box is the
small burstable instance. The deployed sizing has two production-relevant consequences:

- **Burstable CPU credits.** Raw per-connection CPU is low — ClientHello parsing is a few
  hundred byte-ops in LuaJIT, the C `getsockopt(SO_ORIGINAL_DST)` is negligible, and there
  is no TLS crypto. The DNS wait *yields* rather than burning CPU. So CPU is fine for
  bursts, but **sustained** load above the t3.small baseline (~20%) drains the CPU-credit
  balance and then throttles to baseline. A steadily busy proxy should either run t3 in
  `unlimited` mode or move to a non-burstable type (e.g. `c6i`/`c7i`).
- **Network is also burstable.** t3.small sustains ~128 Mbps (bursts to 5 Gbps). For a
  byte-moving proxy this *could* bind first — but in practice the per-connection DNS
  ceiling (§1) caps the connection rate so low that the network baseline is rarely the
  first wall.

**Memory is not a concern at any realistic concurrency here.** With no TLS state and only
~16 KB/direction stream buffers, ~1024 sessions use well under 200 MB of the 2 GiB. You
hit the connection cap (§2) long before memory matters.

## Summary: bottleneck order

1. **DNS resolver PPS limit + no Lua cache (§1)** — hard AWS per-ENI ceiling; collapses
   first at a few hundred conn/sec. → #19
2. **nginx connection slots (§2)**, amplified by `proxy_timeout 600s` — the mechanism the
   DNS stall exhausts. → #20
3. **CPU credits (§3)** — a slow bleed under sustained load on the burstable instance.
4. **Network baseline (§3)** — only relevant once §1 is fixed and real bytes flow.
5. **Memory / conntrack** — comfortable as configured; only matter after §1/§2 are raised.

Until #19 (DNS cache) and #20 (connection slots) are addressed, treat the proxy as a
**demo/low-throughput** component, not a production-scale egress chokepoint.
