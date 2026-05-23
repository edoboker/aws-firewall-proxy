# nginx-proxy golden AMI

Builds the AMI used by `terraform/nginx_proxy.tf`.

This AMI now bakes the full transparent proxy runtime:

- OpenResty with stream preread support
- the custom `SO_ORIGINAL_DST` C stream module
- the Lua preread guard that parses ClientHello, enforces the SNI allowlist, resolves DNS, and detects SNI spoofing
- iptables-services
- awscli v2
- the `refresh-sni-allowlist` systemd timer
- the CloudWatch agent config for `/var/log/nginx/{access,error}.log`

The build also bakes one shared DNS resolver value used by:

- nginx's `resolver` directive
- the Lua DNS comparison path

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
  -var "dns_resolver=169.254.169.253" \
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
  -var "dns_resolver=169.254.169.253" `
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
packer build -var "git_sha=%GIT_SHA%" -var "dns_resolver=169.254.169.253" -var "packer_vpc_id=%PACKER_VPC_ID%" -var "packer_subnet_id=%PACKER_SUBNET_ID%" .
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

## DNS configuration

### Default behavior on AWS / EC2

The default resolver is:

- `169.254.169.253`

That is the AWS Route 53 Resolver inside the VPC, and it is the recommended default because:

- it matches normal VPC DNS behavior
- it can resolve private Route 53 zones
- it does not depend on public DNS reachability

### Why nginx still needs an explicit resolver

Even on EC2, nginx/OpenResty stream proxying does not automatically inherit hostname-upstream resolution from "whatever Linux DNS is using." The `resolver` directive must still be set explicitly.

So this AMI bakes the resolver choice into nginx config during the packer build and also persists it to a runtime env file for Lua to read.

### If you want `1.1.1.1` intentionally

If you intentionally want Cloudflare DNS instead of the AWS VPC resolver:

```bash
packer build -var "dns_resolver=1.1.1.1" .
```

or in PowerShell:

```powershell
packer build -var "dns_resolver=1.1.1.1" .
```

Trade-offs on AWS:

- private Route 53 records may stop resolving
- DNS answers may differ from the VPC resolver
- CDN edge selection may differ
- the instance must be able to reach `1.1.1.1:53`

## What is on the host at boot

- `/etc/nginx/nginx.conf` - OpenResty stream config with the Lua preread guard and the original-dst module loaded
- `/etc/nginx/lua/check_sni.lua` - parses ClientHello, enforces the allowlist, resolves DNS, and detects spoofing
- `/etc/nginx/lua/debug_log_by_lua.lua` - optional debug-only session summary hook
- `/etc/nginx/conf.d/sni_allowlist.conf` - generated from SSM by the timer
- `/usr/local/sbin/refresh-sni-allowlist.sh` - renders the SSM-backed allowlist map
- `/etc/sysconfig/aws-firewall-proxy-runtime` - exports `DNS_RESOLVER`, `ENFORCE`, and `SPIKE_DEBUG`
- `/usr/local/openresty/nginx/modules/ngx_stream_original_dst_module.so` - compiled original-dst module
- `/etc/sysconfig/iptables` - `PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8443`, restored at boot by `iptables-services`
- `/etc/sysctl.d/99-proxy.conf` - `net.ipv4.ip_forward = 1`

## Logging behavior

Default production-style behavior is:

- OpenResty error log level is `warn`
- SNI spoofing detections are emitted as structured `WARN` lines in `/var/log/nginx/error.log`
- internal Lua/runtime failures are emitted as `ERR`
- access logs still go to `/var/log/nginx/access.log` for CloudWatch metrics and request auditing

So the security signal is:

- `WARN`: suspicious or policy-significant event, such as `event="sni_spoofing_detected"`

That is the right default severity because spoofing attempts are not normal traffic noise, but they are also not necessarily a proxy malfunction.

## Notes

- The current proxy path drops spoofed connections instead of silently correcting them.
- The SSM allowlist still remains an independent first-layer gate on top of the SNI-vs-original-dst spoofing detection.
