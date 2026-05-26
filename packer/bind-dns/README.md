# bind-dns golden AMI

Builds the BIND9 recursive resolver AMI used by the shared DNS cache design.

The image bakes a locked-down recursive cache:

- AL2023 + `bind` / `named`
- recursion enabled for localhost and the workload VPC CIDR only
- cache misses forwarded to the DNS VPC's own Route 53 Resolver (`169.254.169.253`)
- BIND-side DNSSEC validation disabled because this image is a forwarding cache, not
  the internet-recursing validator
- `min-cache-ttl` set to BIND's 90-second maximum to reduce short-TTL CDN churn
- BIND serve-stale enabled for the small "proxy lags the client" window

## Layout

- `bind-dns.pkr.hcl` - Packer template, AMI tags, AL2023 source AMI lookup
- `provision.sh` - installs BIND, renders `/etc/named.conf`, validates it, and enables `named`
- `assets/named.conf` - BIND configuration template
- `assets/systemd/` - named service override

## Prerequisites

- Packer >= 1.10
- AWS credentials with permission to launch a `t3.small` in `eu-north-1`, create AMIs, and tag them
- The shared build VPC from `packer/build-infra` if the account does not have a usable default VPC

## Build

**Bash / zsh:**

```bash
cd packer/build-infra && terraform init && terraform apply
cd ../bind-dns
packer init .
packer build \
  -var "git_sha=$(git rev-parse --short HEAD)" \
  -var "packer_vpc_id=$(terraform -chdir=../build-infra output -raw vpc_id)" \
  -var "packer_subnet_id=$(terraform -chdir=../build-infra output -raw subnet_id)" \
  -var "bind_allow_query_cidr=10.0.0.0/16" \
  .
```

**PowerShell** (Windows):

```powershell
cd packer\build-infra; terraform init; terraform apply
cd ..\bind-dns
packer init .
packer build `
  -var "git_sha=$(git rev-parse --short HEAD)" `
  -var "packer_vpc_id=$(terraform -chdir=../build-infra output -raw vpc_id)" `
  -var "packer_subnet_id=$(terraform -chdir=../build-infra output -raw subnet_id)" `
  -var "bind_allow_query_cidr=10.0.0.0/16" `
  .
```

If you have a default VPC in the account and prefer to use it, omit `packer_vpc_id` and
`packer_subnet_id`.

The resulting AMI is tagged `Name=aws-firewall-proxy-bind-dns`. Terraform should find it
with the same most-recent, self-owned AMI lookup pattern used by the proxy and workload
images.

## Tunables

- `bind_allow_query_cidr` defaults to `10.0.0.0/16` and should match the workload VPC CIDR.
- `bind_min_cache_ttl` defaults to `90` seconds, which is BIND's maximum accepted value.
- `bind_stale_answer_ttl` defaults to `30` seconds.

## Standalone Verification

After building the AMI, launch one instance where the test client is inside
`bind_allow_query_cidr`. The instance does not need internet egress; cache misses go to
the DNS VPC's Route 53 Resolver.

```bash
dig @<bind-private-ip> google.com A
dig @<bind-private-ip> google.com A
sudo rndc stats
sudo tail -n 50 /var/log/named/query.log
```

The first query should recurse successfully, and the second query should return from
cache with a lower TTL. A client outside `bind_allow_query_cidr` should receive a refused
response.
