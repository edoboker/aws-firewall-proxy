# nginx-proxy golden AMI

Builds the AMI used by `terraform/nginx_proxy.tf`.

This AMI now bakes the full transparent proxy runtime:

- OpenResty with stream preread support
- the custom `SO_ORIGINAL_DST` C stream module
- the Lua preread guard that parses ClientHello, enforces the SNI allowlist, resolves DNS, and detects SNI spoofing
- iptables-services
- awscli v2
- AWS AppConfig Agent
- the `refresh-proxy-runtime-policy` systemd timer
- the CloudWatch agent config for `/var/log/nginx/{access,error}.log`

## Layout

`assets/` is intentionally split by responsibility:

- `assets/nginx/conf/` - nginx/OpenResty config templates
- `assets/nginx/lua/` - Lua preread and debug hooks
- `assets/nginx/c-module/` - original-dst C module source
- `assets/scripts/` - runtime helper scripts
- `assets/systemd/` - service and timer units
- `assets/cloudwatch/` - CloudWatch agent config

## Prerequisites

- Packer >= 1.10
- AWS credentials with permission to launch a `c6i.large` in `eu-north-1`, create AMIs, and tag them

## Build

Stand up the shared build VPC once (see `packer/build-infra/main.tf`), then feed its outputs to packer.

**Bash / zsh:**

```bash
cd packer/build-infra && terraform init && terraform apply
cd ../nginx-proxy
packer init .
packer build \
  -var "git_sha=$(git rev-parse --short HEAD)" \
  -var "packer_vpc_id=$(terraform -chdir=../build-infra output -raw vpc_id)" \
  -var "packer_subnet_id=$(terraform -chdir=../build-infra output -raw subnet_id)" \
  .
```

**PowerShell** (Windows):

```powershell
cd packer\build-infra; terraform init; terraform apply
cd ..\nginx-proxy
packer init .
packer build `
  -var "git_sha=$(git rev-parse --short HEAD)" `
  -var "packer_vpc_id=$(terraform -chdir=../build-infra output -raw vpc_id)" `
  -var "packer_subnet_id=$(terraform -chdir=../build-infra output -raw subnet_id)" `
  .
```

**Windows `cmd.exe`** (no `$(...)` expansion - pre-resolve into env vars):

```cmd
cd packer\build-infra
terraform init && terraform apply
for /f "delims=" %i in ('terraform output -raw vpc_id') do @set PACKER_VPC_ID=%i
for /f "delims=" %i in ('terraform output -raw subnet_id') do @set PACKER_SUBNET_ID=%i
for /f "delims=" %i in ('git rev-parse --short HEAD') do @set GIT_SHA=%i
cd ..\nginx-proxy
packer init .
packer build -var "git_sha=%GIT_SHA%" -var "packer_vpc_id=%PACKER_VPC_ID%" -var "packer_subnet_id=%PACKER_SUBNET_ID%" .
```

If you have a default VPC in the account and prefer to use it, omit `packer_vpc_id` and `packer_subnet_id`.

The resulting AMI is tagged `Name=aws-firewall-proxy-nginx`. Terraform finds it via `data "aws_ami" "nginx_proxy"` and always picks the most recent matching self-owned image.

## Build speed note

The proxy AMI build compiles OpenResty from source, so it is much more CPU-sensitive than the workload AMI build. For that reason, the proxy packer template now defaults to `instance_type = "c6i.large"` instead of a small burstable instance.

If you want to trade cost for speed, override it at build time, for example:

```bash
packer build -var "instance_type=c6i.xlarge" .
```

The workload AMI does not have the same compile-heavy path, so it can stay on a smaller builder by default.

## Runtime policy configuration

The AMI now bakes only safe bootstrap defaults. Mutable proxy policy is deployed later from Terraform-managed AppConfig and rendered locally on the instance by `refresh-proxy-runtime-policy.sh`.

That runtime policy includes:

- the SNI allowlist
- the nginx/Lua resolver list
- the DNS query count per SNI
- the enforcement mode (`strict` or `audit`)

The demo Terraform defaults publish:

- Route 53 Resolver (`169.254.169.253`) plus `1.1.1.1` and `8.8.8.8`
- `proxy_dns_queries_per_sni = 3`
- `proxy_enforcement_mode = "strict"`

## Metrics pipeline

The proxy metrics path is a three-part chain:

1. nginx/OpenResty triggers Lua hooks during worker startup and per-connection processing
2. Lua aggregates counters and latency histograms in an nginx shared dictionary
3. the CloudWatch agent receives the flushed StatsD packets on `127.0.0.1:8125` and publishes them to CloudWatch

### Who calls `init_metrics.lua`?

nginx itself does. The stream config declares:

```nginx
init_worker_by_lua_file /etc/nginx/lua/init_metrics.lua;
```

That directive runs during nginx worker initialization, so `init_metrics.lua` is invoked once for each worker process when nginx starts or reloads. The file is intentionally tiny: it just imports `proxy_metrics.lua` and calls `start_flush_timer()`. Only worker `0` actually schedules the repeating flush timer, which prevents duplicate publishers.

### Per-connection trigger flow

Each proxied TLS connection through the stream listener drives the metrics lifecycle:

- `preread_by_lua_file /etc/nginx/lua/check_sni.lua`
  starts the metrics session with `record_session_start()`, which increments `Requests` and `ActiveConnections`
- the same preread hook records the terminal policy outcome:
  - `record_allow()` for accepted sessions
  - `record_block(...)` for allowlist denies, no-SNI drops, DNS failures, and internal errors
  - `record_mismatch(...)` for SNI spoofing detections
- `log_by_lua_file /etc/nginx/lua/log_metrics.lua`
  runs at session end and calls `finalize_session()`, which decrements `ActiveConnections` and records upstream connect latency and upstream failure metrics for forwarded sessions

### Aggregation and flush behavior

`proxy_metrics.lua` stores metric state in the nginx shared dictionary:

```nginx
lua_shared_dict proxy_metrics 1m;
```

It groups counters and histogram buckets into rolling publish windows keyed by `METRICS_PUBLISH_INTERVAL_SECONDS` from `/etc/sysconfig/aws-firewall-proxy-runtime`. When a window closes, the flush timer converts the aggregated values into StatsD lines and sends them over UDP to `127.0.0.1:8125`.

### CloudWatch agent handoff

The proxy AMI does not have Lua call CloudWatch directly. Instead:

- `render-cloudwatch-agent-config.sh` renders the final agent config from the runtime interval
- `render-cloudwatch-agent-config.service` runs before `amazon-cloudwatch-agent.service`
- the CloudWatch agent listens for local StatsD traffic, aggregates it on the same interval, and publishes metrics into the `AwsFirewallProxy/Nginx` namespace

This separation keeps the hot request path inside nginx/Lua while delegating AWS API interaction and retry behavior to the CloudWatch agent.

## What is on the host at boot

- `/etc/nginx/nginx.conf` - OpenResty stream config with the Lua preread guard and the original-dst module loaded
- `/etc/nginx/lua/check_sni.lua` - parses ClientHello, enforces the allowlist, resolves DNS, and detects spoofing
- `/etc/nginx/lua/proxy_metrics.lua` - aggregates proxy counters and latency histograms, then flushes them to the local CloudWatch agent StatsD listener
- `/etc/nginx/lua/log_metrics.lua` - log-phase hook for upstream connect metrics and active-connection cleanup
- `/etc/nginx/lua/proxy_runtime_policy.lua` - generated Lua runtime policy consumed by `check_sni.lua`
- `/etc/nginx/lua/debug_log_by_lua.lua` - optional debug-only session summary hook
- `/etc/nginx/conf.d/sni_allowlist.conf` - generated allowlist map from AppConfig
- `/etc/nginx/conf.d/proxy_resolver.conf` - generated resolver include from AppConfig
- `/usr/local/sbin/refresh-proxy-runtime-policy.sh` - renders the AppConfig-backed runtime policy
- `/etc/sysconfig/aws-firewall-proxy-runtime` - exports only stable local debug state such as `PROXY_DEBUG`
- `/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json` - boot-rendered CloudWatch agent config with StatsD and host metrics
- `/etc/sysconfig/proxy-runtime-sync` - AppConfig coordinates for the runtime sync service
- `/etc/sysconfig/aws-appconfig-agent` - region/prefetch settings for AWS AppConfig Agent
- `/usr/local/openresty/nginx/modules/ngx_stream_original_dst_module.so` - compiled original-dst module
- `/etc/sysconfig/iptables` - `PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8443`, restored at boot by `iptables-services`
- `/etc/sysctl.d/99-proxy.conf` - `net.ipv4.ip_forward = 1`

## Logging behavior

Default production-style behavior is:

- OpenResty error log level is `warn`
- security events go to **dedicated sparse logs**, not the error log:
  - SNI spoofing detections (`decision="mismatch"`) → `/var/log/nginx/sni_spoofing.log`
  - allowlist deny / no-SNI drop → `/var/log/nginx/policy_denied.log`

  Both are written by `access_log … if=` rules keyed on `$proxy_decision`, so
  they fire only on the matching event — not per connection.
- internal Lua/runtime failures are emitted as `ERR` to `/var/log/nginx/error.log`, headed `lua="sni-guard"`
- the per-connection access log (`/var/log/nginx/access.log`) is **disabled by default** (debug toggle — see the project README "Debugging")

So the security signal is the volume of the `sni_spoofing.log` (attacks) and
`policy_denied.log` (blocked-by-policy) streams, each shipped to its own
CloudWatch log group. Keeping spoofing out of the error log means error-log
volume stays a clean proxy-health signal.

## Notes

- The current proxy path drops spoofed connections instead of silently correcting them.
- AppConfig is the runtime policy source for the on-host proxy.
- DNS/original-dst matching is probabilistic for CDN-style domains. Multiple resolvers and repeated queries improve coverage, but they cannot guarantee that the proxy sees every IP a client may have received.
