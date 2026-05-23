# Spike: SO_ORIGINAL_DST retrieval from nginx + stream-lua

## What this proves

Production-grade plan §20 calls for surfacing the gap between the SNI a client claims and the IP it is actually connecting to, so SNI spoofing becomes detectable and droppable instead of being silently corrected by the proxy's re-resolution.

This spike now proves the full path end-to-end:

- A tiny C stream module can expose Linux `SO_ORIGINAL_DST` to nginx as `$original_dst`.
- Lua in nginx stream preread can recover the effective SNI, resolve it, compare it to `$original_dst`, log the full resolved set, and drop mismatches.
- The working hostname field in this spike is **`$spike_sni`**, not nginx's builtin `$ssl_preread_server_name`.

## Current result

The spike currently works with these behaviors:

- Happy path: the TLS handshake completes and logs `spike_decision="allow"`.
- Spoof path: the connection is reset during preread and logs `spike_decision="mismatch"`.
- The resolved A-record set is visible in both the verbose Lua preread logs and the JSON access log as `spike_resolved`.

Sample decision lines:

```text
... spike_lua="check_sni" event="decision" ... effective_sni="www.google.com" ... decision="allow" resolved="142.251.150.119,142.251.151.119,..."
... spike_lua="check_sni" event="decision" ... effective_sni="www.google.com" ... decision="mismatch" dst_ip="192.0.2.1" resolved="142.251.150.119,142.251.151.119,..."
```

Sample JSON access lines:

```json
{"sni":"-","spike_sni":"www.google.com","spike_sni_source":"manual_clienthello_parse","spike_dst_ip":"142.251.156.119","spike_resolved":"142.251.150.119,142.251.151.119,142.251.152.119,142.251.153.119,142.251.154.119,142.251.155.119,142.251.156.119,142.251.157.119","original_dst":"142.251.156.119:443","client":"172.17.0.2","status":"200","spike_decision":"allow","spike_trace":"entered>...>decision:allow"}
{"sni":"-","spike_sni":"www.google.com","spike_sni_source":"manual_clienthello_parse","spike_dst_ip":"192.0.2.1","spike_resolved":"142.251.150.119,142.251.151.119,142.251.152.119,142.251.153.119,142.251.154.119,142.251.155.119,142.251.156.119,142.251.157.119","original_dst":"192.0.2.1:443","client":"172.17.0.2","status":"500","spike_decision":"mismatch","spike_trace":"entered>...>decision:mismatch>enforce_exit"}
```

## How to run

From the repo root:

```powershell
docker build -t sni-spike spike/sni-original-dst
docker run --rm -d --name sni-spike --cap-add=NET_ADMIN sni-spike
docker exec sni-spike bash /test/spike.sh
docker logs sni-spike
```

To use a different resolver for both nginx and Lua:

```powershell
docker run --rm -d --name sni-spike --cap-add=NET_ADMIN -e DNS_RESOLVER=1.1.1.1 sni-spike
```

Useful log filter:

```powershell
docker logs sni-spike 2>&1 | Select-String 'spike_decision|spike_resolved|querying_dns|answers_received|spike_sni'
```

`/test/spike.sh` now waits for `/ready` before firing probes, so you do not have to race container startup.

## Making NGINX Work with Custom Lua and C

### Why the original design did not work

Several independent issues had to be fixed before the spike actually exercised the intended path:

1. `check_sni.lua` existed, but nginx was not executing it. The stream server had only a debug `preread_by_lua_block`.
2. Once Lua was wired in, the default postponed preread hook still did not fire in this REDIRECT proxy path.
3. Enabling `preread_by_lua_no_postpone on;` made Lua run early enough, but at that point nginx had **not** populated `$ssl_preread_server_name` yet.
4. nginx's upstream resolver and Lua's DNS resolver were configured separately, so they could drift.
5. The JSON access log showed nginx's builtin SNI field, which is usually empty in the working configuration and therefore misleading.
6. The test script could race nginx startup.

The net effect was: traffic proxied, but the security logic either never ran or ran too early to use nginx's builtin SNI field.

### What changed

#### C side

- [`c-module/ngx_stream_original_dst_module.c`](./c-module/ngx_stream_original_dst_module.c) is still intentionally tiny.
- It calls `getsockopt(SO_ORIGINAL_DST)` on `s->connection->fd`.
- It exposes the result as stream variable `$original_dst`.
- It contains no policy logic, DNS logic, or drop logic.

This is still the minimum-C part of the design.

#### Lua side

- [`lua/check_sni.lua`](./lua/check_sni.lua) now owns the whole decision path.
- It runs in **stream preread**.
- It logs phase entry, env visibility, ClientHello parsing, DNS querying, answer counts, resolved IPs, and final decisions.
- It sets helper variables used later in logs:
  - `$spike_sni`
  - `$spike_sni_source`
  - `$spike_dst_ip`
  - `$spike_resolved`
  - `$spike_decision`
  - `$spike_trace`
- [`lua/log_session.lua`](./lua/log_session.lua) runs in **stream log phase** and emits a summary even if you only want one per-connection line.

#### nginx side

- [`nginx.conf`](./nginx.conf) is now treated as a template.
- nginx runs Lua in preread with `preread_by_lua_no_postpone on;`.
- `proxy_pass` uses `$spike_sni`, not `$ssl_preread_server_name`.
- The JSON access log includes the useful spike fields, including the resolved IP set.

#### Boot sequence

1. Docker multi-stage build compiles the dynamic C module against vanilla nginx with `--with-compat`.
2. The runtime image uses `openresty/openresty:1.27.1.1-alpine`, which already includes stream-lua support.
3. The built `.so` is copied into OpenResty's module directory.
4. The nginx config template, Lua files, and test script are copied into the image.
5. At container start, [`entrypoint.sh`](./entrypoint.sh):
   - renders `nginx.conf` from the template using `DNS_RESOLVER`
   - installs the iptables REDIRECT rules
   - excludes nginx's own worker UID from OUTPUT redirection
   - launches OpenResty in the foreground

### How the request path works now

1. Client connects to TCP/443.
2. iptables REDIRECT sends it to nginx on 8443.
3. The C module surfaces the pre-NAT target as `$original_dst`.
4. Lua preread runs early because of `preread_by_lua_no_postpone on;`.
5. Because builtin `ssl_preread` is still empty at that exact point, Lua peeks the ClientHello bytes itself and parses the SNI manually.
6. Lua stores the effective hostname in `$spike_sni`.
7. Lua resolves `$spike_sni` via `lua-resty-dns`.
8. Lua compares the resolved set to `$original_dst`.
9. On match, proxying continues.
10. On mismatch, Lua exits with error and the handshake is reset.
11. Log phase emits a final per-session summary.

## Useful SNI and JSON Access Log Caveat

The most important logging caveat in this spike is:

- **`$ssl_preread_server_name` is not the useful field in the working configuration.**

Because preread Lua has to run before nginx has filled the builtin variable, the JSON access log often shows:

```json
"sni":"-"
```

That is expected in this spike. The fields you should actually look at are:

- `spike_sni`
- `spike_sni_source`
- `spike_dst_ip`
- `spike_resolved`
- `spike_decision`
- `spike_trace`

So the JSON access log is useful, but only if you treat `spike_sni` as the real hostname field.

## Shared DNS Resolver Setting

The spike now uses **one shared resolver setting** for both nginx and Lua:

- Env var name: `DNS_RESOLVER`
- nginx consumes it by rendering the config template at boot
- Lua consumes it via `os.getenv("DNS_RESOLVER")`

This removes the previous mismatch where nginx and Lua could resolve through different servers.

### How DNS configuration works in practice

There are two different DNS consumers in the spike, and it helps to keep them separate:

1. **nginx + Lua decision path**
   - This is the security-relevant path.
   - Both nginx upstream resolution and Lua's `lua-resty-dns` resolution use the single shared `DNS_RESOLVER` value.
   - In the spike container, that value defaults to `1.1.1.1`.

2. **Other processes in the container**
   - Tools like `curl`, `getent`, or shell utilities use the container's normal libc resolver path, usually `/etc/resolv.conf`.
   - That is separate from nginx's `resolver` directive.

This means that for the spike's "Probe A" happy path, `curl` chooses the initial destination IP using the container resolver, while nginx/Lua validate the SNI using `DNS_RESOLVER`. Those usually overlap for `www.google.com`, but they are not literally the same mechanism unless you align them.

### Container behavior

In the spike container:

- Default shared resolver for nginx + Lua: `1.1.1.1`
- Override mechanism: `-e DNS_RESOLVER=<ip>`

Examples:

```powershell
docker run --rm -d --name sni-spike --cap-add=NET_ADMIN sni-spike
docker run --rm -d --name sni-spike --cap-add=NET_ADMIN -e DNS_RESOLVER=1.1.1.1 sni-spike
docker run --rm -d --name sni-spike --cap-add=NET_ADMIN -e DNS_RESOLVER=8.8.8.8 sni-spike
```

If you want the probe client inside the container to use the same DNS server too, set Docker DNS as well:

```powershell
docker run --rm -d --name sni-spike --cap-add=NET_ADMIN --dns 1.1.1.1 -e DNS_RESOLVER=1.1.1.1 sni-spike
```

Without `--dns`, `curl` may still use Docker's default resolver path even though nginx/Lua are using `DNS_RESOLVER`.

### EC2 / AWS behavior

For the AMI-backed EC2 proxy, the intended default is:

- Resolver: `169.254.169.253`
- Meaning: AWS Route 53 Resolver / VPC resolver

That is the default packer value because it is the normal AWS choice:

- it works inside a VPC without depending on public resolvers
- it can resolve private Route 53 hosted zones
- it follows AWS VPC DNS behavior

So for ordinary EC2-in-VPC deployment, the expected recommendation is: **do not override DNS unless you have a specific reason**.

### Manual `1.1.1.1` on AWS

If you intentionally want the proxy to use `1.1.1.1` instead of the AWS VPC resolver, you can do that, but it is an explicit choice.

For the spike container:

```powershell
docker run --rm -d --name sni-spike --cap-add=NET_ADMIN -e DNS_RESOLVER=1.1.1.1 sni-spike
```

For the AMI build:

```powershell
packer build -var "dns_resolver=1.1.1.1" .
```

Trade-offs of doing that on AWS:

- you lose the normal "just use the VPC resolver" behavior
- you may lose access to private Route 53 records
- CDN edge selection may differ from what the workload would have gotten through the VPC resolver
- the instance must actually be able to reach `1.1.1.1:53`

### Why nginx needs this explicit configuration

nginx stream proxying does **not** automatically use "whatever the host resolver is" for hostname upstream resolution. The `resolver` directive must be present in nginx config.

So the design here is explicit on purpose:

- in the spike container, `entrypoint.sh` renders nginx config from `DNS_RESOLVER`
- in the EC2 AMI, `provision.sh` renders nginx config from the packer `dns_resolver` var

That makes the resolver choice visible and reproducible instead of implicit.

### Packer wiring

The AMI build now has a single packer variable too:

- Packer var: `dns_resolver`
- Default in `packer/nginx-proxy/nginx-proxy.pkr.hcl`: `169.254.169.253`

During the AMI build:

- `provision.sh` renders `/etc/nginx/nginx.conf` from the template with that resolver value.
- It also writes `/etc/sysconfig/aws-firewall-proxy-runtime` containing:

```bash
DNS_RESOLVER=<value>
```

That runtime file is the intended future handoff point for Lua or other runtime logic, so nginx and Lua can consume the same baked value instead of drifting.

## What "normal ClientHello" means here

In this spike, "normal ClientHello" means:

- TLS over TCP, not QUIC
- a standard TLS ClientHello record
- the `server_name` extension is present
- the bytes needed for the parse are available in the preread peek
- the SNI is plaintext, not hidden by ECH

That covers mainstream clients like curl, OpenSSL, browsers, SDKs, and most ordinary outbound HTTPS traffic.

## Why the manual ClientHello parse is still spike-shaped

The manual parser is good enough for this spike, but it is still more brittle than production-grade protocol handling.

Cases where it can be wrong or insufficient:

- **TLS 1.3 PSK-only resumption without SNI**: no hostname exists to parse.
- **ECH / encrypted ClientHello**: the real inner SNI is hidden by design.
- **QUIC**: not TCP, not this parser's protocol.
- **Non-TLS traffic on port 443**: the first bytes are not a TLS record.
- **Fragmentation / unusual record layout**: if the full ClientHello is not available the way the parser expects during preread, the parse can fail.
- **Future maintenance risk**: hand-maintained protocol parsing in Lua is easier to get subtly wrong than relying on nginx/OpenResty builtin parsing paths.

That is why this is "spike-shaped" rather than ideal steady-state programming. It works and proves the technical path, but it also identifies the exact brittle seam: early preread needed custom parsing because the builtin SNI variable was not populated yet.

## Layout

```text
spike/sni-original-dst/
├── Dockerfile
├── c-module/
│   ├── config
│   └── ngx_stream_original_dst_module.c
├── lua/
│   ├── check_sni.lua
│   └── log_session.lua
├── nginx.conf
├── entrypoint.sh
├── test/
│   └── spike.sh
└── README.md
```

## Out of scope for this spike

- Integration with `packer/nginx-proxy/` and `terraform/`
- DNS caching / TTL policy / CNAME handling
- Performance numbers
- IPv6 support in the C module
- Replacing the manual ClientHello parse with a more standard production path
