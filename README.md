# aws-firewall-proxy

Transparent forward proxy that fixes the SNI spoofing bypass in AWS Network Firewall.
AWS Network Firewall FQDN rules inspect only the TLS SNI header — they never verify that the destination IP actually belongs to that hostname. An attacker can set SNI to an allowed domain while routing traffic to a malicious IP. This project deploys a DNS-aware proxy in the VPC egress path that resolves the SNI hostname and always forwards to the DNS-resolved IP, closing the gap.

## Architecture

```
Workload EC2  ──▶  nginx proxy EC2  ──▶  AWS Network Firewall  ──▶  NAT GW  ──▶  Internet
 (10.0.1.0/24)      (10.0.2.0/24)         (10.0.3.0/24)              (10.0.4.0/24)
```

- **Workload subnet** — client EC2 instance; default route points to the proxy ENI.
- **Proxy subnet** — transparent nginx (stream module) intercepts TLS via iptables REDIRECT, reads the SNI, resolves the hostname via VPC DNS, and forwards to the real IP. The host enforces a **first-layer SNI allowlist** sourced from SSM Parameter Store (refreshed every 60s).
- **Firewall subnet** — AWS Network Firewall applies an **independent FQDN allowlist** (Suricata rules with `dotprefix` for safe suffix matching). Defense in depth: nginx and ANF can deny independently.
- **Public subnet** — NAT Gateway for internet egress.

Single AZ deployment. Traffic is steered through route tables — no load balancers or DNS tricks.

## Quickstart guide

### Prerequisites

Install on your workstation:

- **Terraform** ≥ 1.5 — `terraform`.
- **Packer** ≥ 1.10 — `packer`. Builds the proxy AMI.
- **AWS CLI v2** — `aws`. For credentials, SSM access, and the test harness.
- **Python** ≥ 3.10 + `pip` — runs the pytest integration suite.
- AWS credentials in the environment (`aws sts get-caller-identity` should succeed) with permission to: create VPC/EC2/NAT/IGW/ANF/SSM/IAM resources, build AMIs, and call `ssm:SendCommand` against the launched instances.

Default region is `eu-north-1`. Override via `TF_VAR_aws_region` and `AWS_REGION` if you deploy elsewhere — Packer also builds in that region (see `packer/nginx-proxy/nginx-proxy.pkr.hcl`).

### 1. Build the proxy AMI

The Terraform stack expects a self-owned AMI tagged `Name=aws-firewall-proxy-nginx`. Build it once (and again whenever the proxy config or pinned packages change).

**1a. Provision the build VPC.** Packer needs a VPC + public subnet to launch the build instance. `packer/build-infra/` is a tiny standalone Terraform stack (separate state) that creates exactly that:

```bash
cd packer/build-infra
terraform init
terraform apply
```

(Alternative if you'd rather not manage another stack: `aws ec2 create-default-vpc --region eu-north-1`. A default VPC also gives Packer what it needs.)

**1b. Build the AMI.**

```bash
cd ../nginx-proxy
packer init .
packer build \
  -var "git_sha=$(git rev-parse --short HEAD)" \
  -var "vpc_id=$(terraform -chdir=../build-infra output -raw vpc_id)" \
  -var "subnet_id=$(terraform -chdir=../build-infra output -raw subnet_id)" \
  .
```

This produces an AL2023-based AMI with nginx + stream module, iptables-services, awscli v2, the proxy `nginx.conf`, and the `refresh-sni-allowlist` systemd timer baked in. See `packer/nginx-proxy/README.md` for details.

### 2. Deploy the infrastructure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit allowlists / region / sizes as needed
terraform init
terraform apply
```

`terraform apply` discovers the most-recent matching AMI via `data "aws_ami" "nginx_proxy"`. If you rebuild the AMI later, a follow-up `terraform apply` replaces the proxy instance with the new image.

Give the EC2 instances ~60 seconds after `apply` finishes so the SSM agent registers and the on-host allowlist refresh completes.

### 3. Run the integration tests

Use a virtualenv so the test dependencies don't pollute your system Python:

```bash
cd tests
python -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -e .
pytest -v
```

The tests use AWS SSM Run Command against the deployed workload and proxy EC2s — no SSH required. See `tests/README.md` for what each test covers.

### 4. Manual verification — SNI spoofing test

Connect to the workload EC2 via EC2 Instance Connect, then:

```bash
# Spoofed IP — proxy ignores the fake destination and resolves google.com itself
curl -v --resolve google.com:443:1.1.1.1 https://google.com --max-time 10
# Expected: succeeds, proving the proxy overrides the spoofed IP

# Blocked domain — denied by the nginx gate (and by ANF as backstop)
curl -v https://example.com --max-time 10
# Expected: times out / connection reset
```

### 5. Change the allowlist without a redeploy

The nginx SNI allowlist lives in SSM Parameter Store (`/<env>-proxy/nginx-sni-allowlist`). Edit it directly to see the on-host timer pick up the change within ~60s:

```bash
aws ssm put-parameter \
  --name /dev-proxy/nginx-sni-allowlist \
  --type StringList \
  --overwrite \
  --value "amazonaws.com,cdn.amazonlinux.com"
```

The ANF rule group is still managed by Terraform (`var.allowed_fqdns`) — the two allowlists are independent.

### 6. Run the benchmark (optional)

The benchmark runner in `benchmark/` accepts an optional UTF-8 YAML config
for the probe duration, concurrency, target FQDN, results directory, and
route-swap timing:

```bash
cp benchmark/config.example.yaml benchmark/config.yaml
python benchmark/run.py --config benchmark/config.yaml
# CLI flags still override YAML values:
python benchmark/run.py --config benchmark/config.yaml --fqdn google.com
```

See `benchmark/README.md` for the full benchmark workflow and config schema.

### 7. Tear down

```bash
cd terraform && terraform destroy
cd ../packer/build-infra && terraform destroy   # if you used the build VPC
```

The Packer AMI is not destroyed by Terraform; deregister it manually from the EC2 console if you want a clean slate.

## Key design decisions

- **`source_dest_check = false`** on the proxy ENI — required for transparent proxying (packets arrive with a destination IP that isn't the proxy's own).
- **iptables PREROUTING REDIRECT** — steers inbound port 443 to the proxy listener (8443) without requiring client-side configuration.
- **`dotprefix` in Suricata rules** — prevents suffix-matching attacks (e.g., `evilgoogle.com` won't match a rule for `google.com`).
- **Golden AMI via Packer** — pinned package versions, no boot-time `dnf install`, no GitHub binary downloads through the very proxy being booted.
- **Two independent allowlists (nginx + ANF)** — defense in depth; either gate can deny. Nginx reads SSM on a 60s timer for fast iteration; ANF is Terraform-managed for change control.
