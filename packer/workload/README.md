# workload golden AMI

Builds the AMI used by `terraform/workload.tf` for the benchmark client EC2.
Bakes in the [`hey`](https://github.com/rakyll/hey) HTTP load generator and
`jq`, so `benchmark/run.py` can drive load via SSM without any runtime
installation.

## Prerequisites

- Packer >= 1.10
- AWS credentials with permission to launch a `t3.small` in `eu-north-1`,
  create AMIs, and tag them.

## Build

Stand up the shared build VPC once (see `packer/build-infra/main.tf`), then
feed its outputs to packer.

**Bash / zsh:**

```bash
cd packer/build-infra && terraform init && terraform apply
cd ../workload
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
cd ..\workload
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
cd ..\workload
packer init .
packer build -var "git_sha=%GIT_SHA%" -var "packer_vpc_id=%PACKER_VPC_ID%" -var "packer_subnet_id=%PACKER_SUBNET_ID%" .
```

`-chdir=` is avoided (cmd's `for /f` mangles `=` inside the inner command),
so we capture the terraform outputs from inside `build-infra`, then `cd`
to the workload AMI dir and build.

If you have a default VPC in the account and prefer to use it, omit the
`packer_vpc_id`/`packer_subnet_id` vars — packer falls back to the default VPC.

The resulting AMI is tagged `Name=aws-firewall-proxy-workload`. Terraform
finds it via `data "aws_ami" "workload"` (most-recent matching tag).

## What's on the host at boot

- `/usr/local/bin/hey` — pinned release, SHA256-verified at build time.
- `jq` for parsing on-box if ever needed.

Rebuild and re-`terraform apply` to roll a new client image.
