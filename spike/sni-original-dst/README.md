# Spike: SO_ORIGINAL_DST from nginx stream Lua

## What this proves

This spike proves the end-to-end detection path for SNI spoofing:

- a tiny C stream module exposes Linux `SO_ORIGINAL_DST` to nginx as `$original_dst`
- Lua in stream preread parses the TLS ClientHello itself to recover SNI
- Lua resolves that SNI, compares the resolved A-record set to `$original_dst`, and drops mismatches
- nginx then proxies only the connections that passed the check

The important hostname field in this spike is **`$spike_sni`**, not nginx's builtin `$ssl_preread_server_name`.

## Current behavior

In the default runtime mode:

- a normal connection is allowed and stays quiet
- an SNI spoofing attempt is dropped during preread
- the only expected warning log is the spoofing warning
- internal failures such as parse or DNS errors log at `ERR`
- nginx connection-level chatter is suppressed by using `error_log ... warn`

Example spoofing warning:

```text
... spike_lua="check_sni" event="sni_spoofing_detected" decision="mismatch" sni="www.google.com" original_dst="192.0.2.1:443" dst_ip="192.0.2.1" resolved="142.251.150.119,142.251.151.119,..." dns_resolver="1.1.1.1,8.8.8.8" dns_queries_per_sni="3" record_version="0x0301" record_len="512" handshake_type="1" handshake_len="508" client_hello_version="0x0303" session_id_len="32" cipher_suites_len="36" cipher_suite_count="18" compression_methods_len="1" extensions_len="397" extension_count="11"
```

If you opt into the JSON access log for debugging, the useful fields are:

- `spike_sni`
- `spike_dst_ip`
- `spike_resolved`
- `spike_decision`

Example JSON access line:

```json
{"spike_sni":"www.google.com","spike_dst_ip":"142.251.156.119","spike_resolved":"142.251.150.119,142.251.151.119,142.251.152.119,142.251.153.119,142.251.154.119,142.251.155.119,142.251.156.119,142.251.157.119","original_dst":"142.251.156.119:443","client":"172.17.0.2","status":"200","spike_decision":"allow"}
```

## How to run

From the repo root:

```powershell
docker build -t sni-spike spike/sni-original-dst
docker run --rm -d --name sni-spike --cap-add=NET_ADMIN sni-spike
docker exec sni-spike bash /test/spike.sh
docker logs sni-spike
```

The packaged probe now behaves like this:

- Probe A: TLS handshake succeeds and the default runtime stays quiet
- Probe B: TLS handshake is dropped and logs `event="sni_spoofing_detected"`

Useful default log filter:

```powershell
docker logs sni-spike 2>&1 | Select-String 'sni_spoofing_detected|client_hello_|resolver_|missing_original_dst|bad_original_dst|lua_exception'
```

`/test/spike.sh` waits for `/ready` before firing probes, so you do not have to race startup.

## Runtime logging modes

There are now two intentionally separate logging modes.

### Default runtime mode

This is the production-like mode:

- no step-by-step Lua logs on allow
- no per-connection JSON access log
- one structured `WARN` for spoofing mismatches
- `ERR` only for internal failures
- nginx's own connection logs are suppressed

This is the mode you should use if you only want to see suspected SNI spoofing attempts.

### Debug runtime mode

Use one or more of these when diagnosing behavior:

1. Set `SPIKE_DEBUG=1`

```powershell
docker run --rm -d --name sni-spike --cap-add=NET_ADMIN -e SPIKE_DEBUG=1 sni-spike
```

This does two things:

- `lua/check_sni.lua` emits structured `NOTICE` logs such as `client_hello_parsed` and `allow`
- the entrypoint renders nginx with `error_log ... notice` so those debug notices are visible

2. Enable the extra log-phase summary hook

In [`nginx.conf`](./nginx.conf), uncomment:

```nginx
# log_by_lua_file /usr/local/openresty/nginx/lua/debug_log_by_lua.lua;
```

That enables [`lua/debug_log_by_lua.lua`](./lua/debug_log_by_lua.lua), which emits one extra per-session summary line at `NOTICE`.

3. Enable the JSON access log

In [`nginx.conf`](./nginx.conf), replace:

```nginx
access_log off;
```

with:

```nginx
access_log /dev/stderr spike;
```

That gives you one structured JSON line per proxied connection.

Because [`nginx.conf`](./nginx.conf) is copied into the image as a template, any template change requires a rebuild:

```powershell
docker build -t sni-spike spike/sni-original-dst
```

## Making nginx work with custom Lua and C

### Why the original design did not work

Several issues had to be fixed before the spike actually enforced anything:

1. `check_sni.lua` existed, but nginx was not executing it. The config still had only a small debug `preread_by_lua_block`.
2. After wiring Lua in, the default postponed preread hook still did not fire in this REDIRECT proxy path.
3. Forcing preread earlier with `preread_by_lua_no_postpone on;` made Lua run, but nginx had still not populated `$ssl_preread_server_name`.
4. nginx's upstream resolver and Lua's DNS resolver were configured independently, so they could drift.
5. The old logs mixed nginx builtin fields, Lua-derived fields, and very long trace strings, which made the output hard to read.
6. The test probe could race nginx startup.

The net effect was that traffic could proxy, but the actual security decision path either never ran or ran too early to use nginx's builtin SNI field.

### What changed

#### C side

- [`c-module/ngx_stream_original_dst_module.c`](./c-module/ngx_stream_original_dst_module.c) stays intentionally small
- it calls `getsockopt(SO_ORIGINAL_DST)` on the accepted socket
- it exposes the result as stream variable `$original_dst`
- it does not do DNS, policy, or drop logic

This keeps the minimum privileged wire-up in C and leaves policy in Lua.

#### Lua side

- [`lua/check_sni.lua`](./lua/check_sni.lua) now owns the policy path
- it runs in stream preread
- it peeks the ClientHello bytes and parses SNI itself
- it resolves the parsed hostname with `lua-resty-dns`
- it compares the resolved A-record set to `$original_dst`
- it sets the nginx variables used later for debugging:
  - `$spike_sni`
  - `$spike_dst_ip`
  - `$spike_resolved`
  - `$spike_decision`
- it is quiet on allow in normal mode
- it emits one structured spoofing `WARN` on mismatch
- it emits `ERR` only for real internal failures
- if `SPIKE_DEBUG=1`, it emits readable `NOTICE` logs instead of one giant trace string

[`lua/debug_log_by_lua.lua`](./lua/debug_log_by_lua.lua) is now explicitly debug-only. It is not part of the enforcement path and is disabled by default.

#### nginx side

- [`nginx.conf`](./nginx.conf) is treated as a template and rendered at container boot
- `preread_by_lua_no_postpone on;` forces the Lua preread hook to run early enough in this REDIRECT path
- `proxy_pass` uses `$spike_sni`, not `$ssl_preread_server_name`
- the builtin `ssl_preread` path is no longer part of the decision logic
- the default template disables the access log so production-style runs stay quiet

#### Boot sequence

1. The Docker multi-stage build compiles the dynamic C module against vanilla nginx with `--with-compat`.
2. The runtime image uses `openresty/openresty:1.27.1.1-alpine`, which already includes stream Lua support.
3. The compiled `.so` is copied into OpenResty's module directory and loaded with `load_module`.
4. The nginx config template, Lua files, and probe script are copied into the image.
5. At container start, [`entrypoint.sh`](./entrypoint.sh):
   - renders `nginx.conf` from the template using `DNS_RESOLVERS`
   - renders nginx's error log level as `warn` by default or `notice` when `SPIKE_DEBUG=1`
   - exports `SPIKE_DEBUG` for nginx worker visibility
   - installs the iptables REDIRECT rules
   - excludes nginx's own worker UID from the OUTPUT redirect
   - stays quiet by default apart from actual warnings and errors
   - starts OpenResty in the foreground

### How the request path works now

1. A client connects to TCP/443.
2. iptables REDIRECT sends it to nginx on 8443.
3. The C module exposes the original pre-NAT destination as `$original_dst`.
4. Lua runs in the stream preread phase because of `preread_by_lua_no_postpone on;`.
5. Lua peeks the first TLS record and parses the ClientHello itself.
6. Lua extracts SNI into `$spike_sni`.
7. Lua resolves `$spike_sni`.
8. Lua compares the resolved set to the IP from `$original_dst`.
9. On match, the proxy continues to `$spike_sni:443`.
10. On mismatch, Lua logs `sni_spoofing_detected` and aborts the connection.

### Why preread phase still matters even though builtin `ssl_preread` does not

We still need the **preread phase** because that is where nginx stream Lua can inspect the TCP bytes before proxying starts.

We do **not** need nginx's builtin `ssl_preread` parser anymore, because the working path now parses the ClientHello directly in Lua. Those are two different things:

- preread phase: the lifecycle phase where the bytes are available
- `ssl_preread`: nginx's builtin TLS metadata parser

This spike still depends on the first and no longer depends on the second.

## JSON access log caveat

The JSON access log is now a debug aid, not the default runtime log.

If you enable it, the most important caveat is still:

- **`$spike_sni` is the useful hostname field**

Do not add nginx's builtin `$ssl_preread_server_name` back into the JSON line unless you are intentionally comparing parsers. In this working configuration it is not the field that drives the policy decision, and logging both host fields just makes the output noisy and confusing.

## Shared DNS configuration

The spike now uses one shared resolver list for both nginx and Lua:

- environment variable: `DNS_RESOLVERS`
- compatibility fallback: `DNS_RESOLVER`
- query-count variable: `DNS_QUERIES_PER_SNI`, clamped to `1..16`
- nginx consumes it when [`entrypoint.sh`](./entrypoint.sh) renders [`nginx.conf`](./nginx.conf)
- Lua consumes it via `os.getenv("DNS_RESOLVERS")`

This removes the old mismatch where nginx and Lua could resolve through different servers.

### Container behavior

Inside the spike container there are two DNS paths:

1. nginx plus Lua
   - this is the security-relevant path
   - both use the shared `DNS_RESOLVERS`
   - the default is `1.1.1.1`

2. other processes such as `curl`
   - these use the container's normal resolver path, usually `/etc/resolv.conf`
   - this is separate from nginx's `resolver` directive

That means Probe A works like this:

- `curl` picks a destination IP using the container resolver
- nginx and Lua validate the SNI using `DNS_RESOLVERS`

Those usually overlap for `www.google.com`, but they are not literally the same mechanism unless you align them.

To override the nginx plus Lua resolver list:

```powershell
docker run --rm -d --name sni-spike --cap-add=NET_ADMIN -e DNS_RESOLVERS=1.1.1.1,8.8.8.8 -e DNS_QUERIES_PER_SNI=3 sni-spike
```

If you also want the probe client in the container to use the same DNS server, set Docker DNS too:

```powershell
docker run --rm -d --name sni-spike --cap-add=NET_ADMIN --dns 1.1.1.1 -e DNS_RESOLVERS=1.1.1.1 sni-spike
```

Without `--dns`, `curl` may still use Docker's default resolver path even though nginx and Lua are using `DNS_RESOLVERS`.

### Why repeated DNS queries exist

For high-scale domains, DNS answers can rotate even when asking the same resolver repeatedly. For example, repeated `nslookup google.com 8.8.8.8` calls may return one different A record each time, while `login.microsoftonline.com` may return a larger set in one response. Both are normal.

The spike therefore supports `DNS_QUERIES_PER_SNI`: Lua queries each configured resolver that many times, follows CNAMEs, unions all A records it observes, and compares `$original_dst` against the union. This reduces false positives, but it does not guarantee that the proxy has seen every IP a client may have received.

### EC2 and AWS behavior

For the AMI-backed EC2 proxy, the intended default resolver is:

- `169.254.169.253`

That is the AWS Route 53 Resolver inside the VPC. It is the normal default because:

- it works without depending on public resolvers
- it can resolve private Route 53 zones
- it matches normal VPC DNS behavior

So on ordinary EC2 in a VPC, the recommended default is: do not override DNS unless you have a specific reason.

### Manually forcing `1.1.1.1`

If you intentionally want the proxy to use `1.1.1.1` instead of the AWS VPC resolver, that is still possible.

For the spike container:

```powershell
docker run --rm -d --name sni-spike --cap-add=NET_ADMIN -e DNS_RESOLVERS=1.1.1.1 sni-spike
```

For the AMI build:

```powershell
packer build -var "dns_resolvers=1.1.1.1" .
```

Trade-offs on AWS:

- you lose the default VPC resolver behavior
- you may lose access to private Route 53 records
- CDN edge selection may differ from what the VPC resolver would have returned
- the instance must actually be able to reach `1.1.1.1:53`

### Why nginx needs an explicit resolver

nginx stream proxying does not automatically use "whatever the host resolver is" for hostname upstream resolution. The `resolver` directive must be present in the nginx config.

That is why this design is explicit:

- in the spike container, [`entrypoint.sh`](./entrypoint.sh) renders nginx config from `DNS_RESOLVERS`
- in the EC2 AMI, `provision.sh` renders nginx config from the packer `dns_resolvers` variable

### Packer wiring

The AMI build also has a single resolver variable:

- packer variable: `dns_resolvers`
- default in `packer/nginx-proxy/nginx-proxy.pkr.hcl`: `169.254.169.253`

During the AMI build:

- `provision.sh` renders `/etc/nginx/nginx.conf` with that resolver
- it also writes `/etc/sysconfig/aws-firewall-proxy-runtime` containing:

```bash
DNS_RESOLVERS=<value>
DNS_QUERIES_PER_SNI=<value>
```

That runtime file is the future handoff point for Lua or other runtime logic so nginx and Lua can consume the same baked resolver value.

## What "normal ClientHello" means here

In this spike, "normal ClientHello" means the common case:

- TLS over TCP, not QUIC
- a standard TLS ClientHello record
- the `server_name` extension is present
- the bytes needed for the parse are available in the preread peek
- the SNI is plaintext, not hidden by ECH

That covers normal browser, curl, OpenSSL, and SDK traffic.

## Why the manual ClientHello parser is still spike-shaped

The current parser is good enough to prove the design, but it is still more brittle than a production-grade protocol parser.

Cases where it can be wrong or insufficient:

- TLS 1.3 PSK-only resumption without SNI
- ECH, where the real inner SNI is hidden
- QUIC, which is not TCP and not this parser's protocol
- non-TLS traffic on port 443
- fragmented or unusual record layouts that are not fully available in the first preread peek
- the general maintenance risk of hand-maintained wire parsing in Lua

That is why this is standard engineering for a spike, but not yet the final production implementation.
