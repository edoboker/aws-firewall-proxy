# nginx-proxy golden AMI

Builds the AMI used by `terraform/nginx_proxy.tf`.

This AMI now bakes the full transparent proxy runtime:

- OpenResty with stream preread support
- the custom `SO_ORIGINAL_DST` C stream module
- nginx `ssl_preread` routing for TLS override, plus Lua helpers for the experimental HTTP path
- iptables-services
- AWS AppConfig Agent
- the `refresh-proxy-runtime-policy` systemd timer
- the CloudWatch agent config for nginx/runtime logs

## Layout

`assets/` is intentionally split by responsibility:

- `assets/nginx/conf/` - nginx/OpenResty config templates
- `assets/nginx/lua/` - Lua policy helpers for the experimental HTTP listener
- `assets/nginx/c-module/` - original-dst C module source
- `assets/scripts/` - runtime helper scripts
- `assets/systemd/` - service and timer units
- `assets/cloudwatch/` - CloudWatch agent config

## Prerequisites

- Packer >= 1.10
- AWS credentials with permission to launch a `c6i.large` in `eu-north-1`, create AMIs, and tag them

## Build

Stand up the shared build VPC once (see `terraform/packer-bootstrap/main.tf`), then feed its outputs to packer.

**Bash / zsh:**

```bash
cd terraform/packer-bootstrap && terraform init && terraform apply
cd ../..
packer init packer/nginx-proxy
packer build \
  -var "git_sha=$(git rev-parse --short HEAD)" \
  -var "packer_vpc_id=$(terraform -chdir=terraform/packer-bootstrap output -raw vpc_id)" \
  -var "packer_subnet_id=$(terraform -chdir=terraform/packer-bootstrap output -raw subnet_id)" \
  packer/nginx-proxy
```

**PowerShell** (Windows):

```powershell
cd terraform\packer-bootstrap; terraform init; terraform apply
cd ..\..
packer init packer\nginx-proxy
packer build `
  -var "git_sha=$(git rev-parse --short HEAD)" `
  -var "packer_vpc_id=$(terraform -chdir=terraform/packer-bootstrap output -raw vpc_id)" `
  -var "packer_subnet_id=$(terraform -chdir=terraform/packer-bootstrap output -raw subnet_id)" `
  packer\nginx-proxy
```

**Windows `cmd.exe`** (no `$(...)` expansion - pre-resolve into env vars):

```cmd
cd terraform\packer-bootstrap
terraform init && terraform apply
for /f "delims=" %i in ('terraform output -raw vpc_id') do @set PACKER_VPC_ID=%i
for /f "delims=" %i in ('terraform output -raw subnet_id') do @set PACKER_SUBNET_ID=%i
for /f "delims=" %i in ('git rev-parse --short HEAD') do @set GIT_SHA=%i
cd ..\..
packer init packer\nginx-proxy
packer build -var "git_sha=%GIT_SHA%" -var "packer_vpc_id=%PACKER_VPC_ID%" -var "packer_subnet_id=%PACKER_SUBNET_ID%" packer\nginx-proxy
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

That runtime policy renders the nginx resolver include used by TLS override
forwarding and the policy consumed by the experimental cleartext HTTP
Host/original-dst listener on port 80. It includes:

- the HTTP Host allowlist
- the nginx resolver list used by TLS proxying and HTTP Host validation
- the DNS query count per Host
- the HTTP enforcement mode (`strict` or `audit`)

The demo Terraform defaults publish:

- Route 53 Resolver (`169.254.169.253`) plus `1.1.1.1` and `8.8.8.8`
- `http_dns_queries_per_host = 3`
- `http_enforcement_mode = "strict"`

On first boot, nginx depends on a successful AppConfig policy render rather than a legacy fallback path.

## Connection flow

The current TLS override listener uses nginx `ssl_preread`, not the legacy Lua
SNI guard. For each TLS connection it recovers the original destination, reads
`$ssl_preread_server_name`, forwards to `$ssl_preread_server_name:443`, and
writes a compact override observation for the async detector.

The Lua preread hook remains only for the experimental HTTP path. It validates
the cleartext Host header against AppConfig policy, checks the original
destination IP against the Host RRset, and forwards to one resolved Host IP on
port 80.

## What is on the host at boot

- `/etc/nginx/nginx.conf` - OpenResty stream config with `ssl_preread`, override forwarding, and the original-dst module loaded
- `/etc/nginx/lua/check_http_host.lua` - experimental HTTP Host/original-dst guard
- `/etc/nginx/lua/proxy_runtime_policy.lua` - generated Lua runtime policy consumed by the HTTP guard
- `/etc/nginx/conf.d/http_host_allowlist.conf` - generated HTTP Host allowlist map from AppConfig
- `/etc/nginx/conf.d/proxy_resolver.conf` - generated resolver include from AppConfig
- `/usr/local/sbin/refresh-proxy-runtime-policy.sh` - renders the AppConfig-backed runtime policy
- `/etc/sysconfig/aws-firewall-proxy-runtime` - exports only stable local debug state such as `PROXY_DEBUG`
- `/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json` - boot-rendered CloudWatch agent config with nginx/runtime logs and host metrics
- `/etc/sysconfig/proxy-runtime-sync` - AppConfig coordinates for the runtime sync service
- `/etc/sysconfig/aws-appconfig-agent` - region/prefetch settings for AWS AppConfig Agent
- `/usr/local/openresty/nginx/modules/ngx_stream_original_dst_module.so` - compiled original-dst module
- `/etc/sysconfig/iptables` - `PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8443`, restored at boot by `iptables-services`
- `/etc/sysctl.d/99-proxy.conf` - `net.ipv4.ip_forward = 1`

## Logging behavior

Default behavior is:

- OpenResty error log level is `warn`
- TLS override observations go to `/var/log/nginx/override_observations.log`
  and are shipped to `/aws/firewall-proxy/nginx/override-observations`
- the async detector Lambda consumes that log group and emits structured alerts
  plus the `AwsFirewallProxy/SuspectedSniSpoofing` metric
- sparse Lua policy-denied logs remain available for the experimental HTTP path
- `/etc/logrotate.d/aws-firewall-proxy` rotates nginx and runtime-sync logs.

## Notes

- The current TLS proxy path overrides the upstream destination instead of
  connecting to the client-selected IP.
- AppConfig is the runtime policy source of truth.
- DNS/original-dst matching in the async detector is probabilistic for
  CDN-style domains and should be treated as an investigation signal.
