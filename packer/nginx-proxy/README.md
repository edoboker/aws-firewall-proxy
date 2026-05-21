# nginx-proxy golden AMI

Builds the AMI used by `terraform/nginx_proxy.tf`. Bakes in nginx + stream
module, iptables-services, awscli v2, the proxy `nginx.conf`, and the
`refresh-sni-allowlist` systemd timer that pulls the SNI allowlist from SSM
Parameter Store every 60s.

## Prerequisites

- Packer >= 1.10
- AWS credentials with permission to launch a t3.small in `eu-north-1`,
  create AMIs, and tag them.

## Build

Stand up the shared build VPC once (see `packer/build-infra/main.tf`), then
feed its outputs to packer.

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

**Windows `cmd.exe`** (no `$(...)` expansion — pre-resolve into env vars):

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

`-chdir=` is avoided (cmd's `for /f` mangles `=` inside the inner command),
so we capture the terraform outputs from inside `build-infra`, then `cd`
to the nginx-proxy AMI dir and build.

If you have a default VPC in the account and prefer to use it, omit the
`packer_vpc_id`/`packer_subnet_id` vars — packer falls back to the default VPC.

The resulting AMI is tagged `Name=aws-firewall-proxy-nginx`. Terraform finds
it via `data "aws_ami" "nginx_proxy"` (most-recent matching tag).

## What's on the host at boot

- `/etc/nginx/nginx.conf` — stream proxy on :8443, denies SNIs not in the
  allowlist by routing them to an empty upstream.
- `/etc/nginx/conf.d/sni_allowlist.conf` — generated from SSM by the timer.
- `/usr/local/sbin/refresh-sni-allowlist.sh` — reads
  `/etc/sysconfig/nginx-sni-allowlist` (written by Terraform user_data) to
  learn the parameter name + region, then fetches and renders.
- `/etc/sysconfig/iptables` — `PREROUTING -p tcp --dport 443 -j REDIRECT
  --to-port 8443`, restored at boot by `iptables-services`.
- `/etc/sysctl.d/99-proxy.conf` — `net.ipv4.ip_forward = 1`.

CI integration lives in `steering/production-grade-plan.md` §6.
