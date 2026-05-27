# aws-firewall-proxy

AWS egress filtering demo for closing the gap between TLS SNI allowlists and
the actual destination IP a client connects to.

AWS Network Firewall FQDN rules inspect TLS SNI, but they do not prove that the
client is connecting to an IP that belongs to that hostname. A client can claim
an allowed SNI while routing traffic to a different IP. This repo demonstrates
two ways to reduce that risk.

## Implemented Approaches

1. **Override proxy with async detection.** The default path inserts a
   transparent OpenResty/nginx proxy into egress. It recovers the original
   destination, reads SNI with `ssl_preread`, forwards to
   `$ssl_preread_server_name:443` instead of the client-selected IP, and emits
   compact observations for an async Lambda detector.
2. **Lambda rule generator.** An optional, experimental path resolves selected
   exact FQDNs in Lambda, publishes their IPv4 answers into managed prefix
   lists, and lets AWS Network Firewall enforce rules that bind exact SNI to
   the generated destination IP sets.

## Architecture

The Terraform stack is a single-AZ lab with two complementary patterns.

**Default: override proxy with async detection**

```text
Workload EC2
  -> OpenResty/nginx transparent proxy
  -> AWS Network Firewall
  -> NAT Gateway
  -> Internet

Detection pipeline:
OpenResty override observations
  -> CloudWatch Agent
  -> /aws/firewall-proxy/nginx/override-observations
  -> CloudWatch Logs subscription
  -> sni-spoofing-detector Lambda
  -> Lambda logs + AwsFirewallProxy/SuspectedSniSpoofing metric/alarm
```

The workload subnet routes default egress to the proxy ENI. The proxy recovers
the original destination, ignores it for forwarding, connects to the SNI
hostname, and writes `{SNI, original_dst}` observations. The detector Lambda
later resolves the SNI, compares it with the original destination IP, and emits
a suspicion signal. Detection does not block traffic; prevention comes from the
proxy never connecting to the client-selected destination IP.

**Optional: Lambda rule generator**

```text
Lambda resolver job
  -> managed prefix lists
  -> AWS Network Firewall SNI+IP rules

Direct workload EC2 or proxy subnet traffic
  -> AWS Network Firewall generated rule group
  -> NAT Gateway
  -> Internet
```

The rule generator is a control-plane alternative for selected exact FQDNs. It
resolves those names in Lambda, refreshes managed prefix lists, and attaches a
separate Network Firewall rule group that allows traffic only when the TLS SNI
and destination IP set match the same FQDN. It is experimental and disabled by
default.

Shared infrastructure includes the VPC, workload/proxy/firewall/public subnets,
AWS Network Firewall, NAT Gateway, CloudWatch logs/metrics, SSM access, and
Packer-built AMI images. AppConfig renders the proxy resolver config and the
experimental cleartext HTTP Host/original-dst policy.

Traffic is steered with route tables; there are no load balancers in this demo.
This is not production-ready as an inline egress chokepoint; see
`docs/scaling-in-production.md` and `docs/production-grade-plan.md`.

## Quickstart

### Prerequisites

- Terraform >= 1.5
- Packer >= 1.10
- AWS CLI v2
- Python >= 3.10 plus `pip`

Your AWS credentials should be able to create VPC, EC2, NAT, IGW, AWS Network
Firewall, SSM, IAM, AMI, Lambda, CloudWatch, AppConfig, and prefix-list
resources. Default region is `eu-north-1`; override with `TF_VAR_aws_region`
and `AWS_REGION`.

### 1. Build the AMIs

Terraform expects two self-owned AMIs:

- `aws-firewall-proxy-nginx`
- `aws-firewall-proxy-workload`

Provision the Terraform state bucket and Packer build VPC:

```bash
cd terraform/bootstrap
terraform init
terraform apply
STATE_BUCKET=$(terraform output -raw state_bucket_name)

cd ../packer-bootstrap
terraform init -backend-config="bucket=${STATE_BUCKET}"
terraform apply
```

Build the proxy AMI:

```bash
packer init packer/nginx-proxy
packer build \
  -var "git_sha=$(git rev-parse --short HEAD)" \
  -var "packer_vpc_id=$(terraform -chdir=terraform/packer-bootstrap output -raw vpc_id)" \
  -var "packer_subnet_id=$(terraform -chdir=terraform/packer-bootstrap output -raw subnet_id)" \
  packer/nginx-proxy
```

Build the workload AMI:

```bash
packer init packer/workload
packer build \
  -var "git_sha=$(git rev-parse --short HEAD)" \
  -var "packer_vpc_id=$(terraform -chdir=terraform/packer-bootstrap output -raw vpc_id)" \
  -var "packer_subnet_id=$(terraform -chdir=terraform/packer-bootstrap output -raw subnet_id)" \
  packer/workload
```

### 2. Deploy the Stack

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
STATE_BUCKET=$(terraform -chdir=bootstrap output -raw state_bucket_name)
terraform init -backend-config="bucket=${STATE_BUCKET}"
terraform apply
```

Edit `terraform.tfvars` before applying to choose environment name, CIDRs,
instance sizes, firewall allowlists, HTTP prototype settings, and optional
rule-generator settings.

Give the EC2 instances about 60 seconds after `apply` finishes so SSM,
AppConfig, the runtime-policy renderer, nginx, and CloudWatch Agent settle.

### 3. Run Tests

```bash
make setup
make test
```

The tests use SSM Run Command against the workload and proxy EC2s; no SSH is
required. Live tests skip when no deployed stack is available.

### 4. Manual Verification

Connect to the workload EC2 via EC2 Instance Connect or SSM Run Command:

```bash
# Allowed destination chosen by normal DNS
curl -v https://google.com --max-time 10

# Spoofed original destination
curl -v --resolve google.com:443:1.1.1.1 https://google.com --max-time 10
# Expected: proxy forwards to google.com:443, not 1.1.1.1; async detector may alert

# Blocked domain
curl -v https://example.com --max-time 10
# Expected: depends on downstream firewall/DNS policy
```

### 5. Runtime Policy

The TLS override path does not use an on-host allowlist or synchronous DNS
revalidation policy. It forwards to the SNI-derived upstream using the rendered
nginx resolver config and emits override observations for async detection.

Terraform publishes AppConfig policy for the proxy resolver config and for the
experimental cleartext HTTP Host/original-dst listener on port 80. Update these
values in `terraform.tfvars`, then run `terraform apply`:

- `http_allowed_hosts`
- `proxy_public_dns_resolvers`
- `http_dns_queries_per_host`
- `http_enforcement_mode`

The refresh timer reads the deployed AppConfig version through the local
AppConfig Agent and reloads nginx only if rendered runtime files changed.

### 6. Rule Generator

The Lambda rule generator is disabled by default. To test it:

```hcl
enable_ruleset_generator          = true
ruleset_generator_fqdns           = ["login.microsoftonline.com", "wiz.io"]
enable_ruleset_generator_schedule = true
```

Generated FQDNs must not overlap `allowed_fqdns`; otherwise the broader SNI-only
firewall allowlist can bypass the generated SNI+IP binding.

### 7. Benchmarks

```bash
python benchmark/workload_bench/run.py
python benchmark/workload_bench/run.py --steps 10,50,100 --duration 10 --fqdn google.com
```

See `benchmark/workload_bench/README.md` and `benchmark/lambda_bench/README.md`
for benchmark details.

### 8. Tear Down

```bash
cd terraform && terraform destroy
cd ../terraform/packer-bootstrap && terraform destroy
```

Terraform does not deregister Packer-built AMIs; remove them manually for a full
cleanup.

Further operational notes live in `docs/observability.md`.
