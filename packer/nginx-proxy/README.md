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

```bash
cd packer/nginx-proxy
packer init .
packer build \
  -var "git_sha=$(git rev-parse --short HEAD)" \
  .
```

If the account has no default VPC (typical for newer AWS Organizations), Packer cannot create the temporary build security group. Either create a default VPC once with `aws ec2 create-default-vpc --region eu-north-1`, or pass an existing VPC and a public subnet:

```bash
packer build \
  -var "git_sha=$(git rev-parse --short HEAD)" \
  -var "vpc_id=vpc-xxxxxxxx" \
  -var "subnet_id=subnet-xxxxxxxx" \
  .
```

The subnet must route to the internet (IGW or NAT) so Packer can SSH in and `dnf` can fetch packages.

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
