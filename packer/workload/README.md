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

```bash
cd packer/workload
packer init .
packer build \
  -var "git_sha=$(git rev-parse --short HEAD)" \
  .
```

If the account has no default VPC, pass an existing VPC + public subnet:

```bash
packer build \
  -var "git_sha=$(git rev-parse --short HEAD)" \
  -var "vpc_id=vpc-xxxxxxxx" \
  -var "subnet_id=subnet-xxxxxxxx" \
  .
```

The resulting AMI is tagged `Name=aws-firewall-proxy-workload`. Terraform
finds it via `data "aws_ami" "workload"` (most-recent matching tag).

## What's on the host at boot

- `/usr/local/bin/hey` — pinned release, SHA256-verified at build time.
- `jq` for parsing on-box if ever needed.

Rebuild and re-`terraform apply` to roll a new client image.
