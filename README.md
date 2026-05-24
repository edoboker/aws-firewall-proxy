# aws-firewall-proxy

Transparent forward proxy that closes the SNI spoofing gap in AWS Network Firewall.

AWS Network Firewall FQDN rules inspect the TLS SNI value, but they do not verify that the client is actually connecting to an IP that belongs to that hostname. A client can claim an allowed SNI while routing traffic to a different IP. This project inserts a DNS-aware transparent proxy into the VPC egress path so the proxy can:

- recover the original destination IP before NAT
- parse the ClientHello itself
- enforce an on-host SNI allowlist
- resolve the claimed SNI
- drop the connection if the original destination IP is not in the resolved set

Important production caveat: the DNS-to-original-destination comparison is probabilistic for large, geo-distributed, CDN-backed services. A client and the proxy may query at different times, through different recursive resolvers, and legitimately receive different A-record subsets for the same SNI. This project can reduce the false-positive rate by querying multiple resolvers multiple times and unioning the results, but it cannot prove that it has every IP the client might have received.

## Architecture

```text
Workload EC2  -->  nginx proxy EC2  -->  AWS Network Firewall  -->  NAT GW  -->  Internet
 (10.0.1.0/24)      (10.0.2.0/24)         (10.0.3.0/24)              (10.0.4.0/24)
```

- **Workload subnet** - client EC2 instance; default route points to the proxy ENI.
- **Proxy subnet** - transparent OpenResty intercepts TLS via iptables REDIRECT, recovers `SO_ORIGINAL_DST` via a custom C stream module, parses ClientHello in Lua, resolves the SNI through the configured resolver set, and drops spoofed connections. The host also enforces a first-layer SNI allowlist sourced from SSM Parameter Store.
- **Firewall subnet** - AWS Network Firewall applies an independent FQDN allowlist using Suricata `dotprefix` rules.
- **Public subnet** - NAT Gateway for internet egress.

Single-AZ deployment. Traffic is steered with route tables - no load balancers or DNS tricks.

## Quickstart guide

### Prerequisites

Install on your workstation:

- **Terraform** >= 1.5
- **Packer** >= 1.10
- **AWS CLI v2**
- **Python** >= 3.10 plus `pip`

Your AWS credentials should be able to create VPC, EC2, NAT, IGW, ANF, SSM, IAM, and AMI resources and call `ssm:SendCommand` against the launched instances.

Default region is `eu-north-1`. Override with `TF_VAR_aws_region` and `AWS_REGION` if you deploy elsewhere.

### 1. Build the AMIs

Terraform expects two self-owned AMIs:

- `aws-firewall-proxy-nginx`
- `aws-firewall-proxy-workload`

#### 1a. Provision the build VPC

Packer needs a VPC plus public subnet to launch the build instance.

```bash
cd packer/build-infra
terraform init
terraform apply
```

If your account already has a usable default VPC, you can skip this and omit the explicit packer VPC/subnet vars.

#### 1b. Build the proxy AMI

```bash
cd ../nginx-proxy
packer init .
packer build \
  -var "git_sha=$(git rev-parse --short HEAD)" \
  -var "packer_vpc_id=$(terraform -chdir=../build-infra output -raw vpc_id)" \
  -var "packer_subnet_id=$(terraform -chdir=../build-infra output -raw subnet_id)" \
  .
```

This builds an AL2023-based AMI with OpenResty, the original-dst C module, the Lua preread guard, iptables-services, awscli v2, CloudWatch agent config, and the `refresh-sni-allowlist` timer baked in.

The `Makefile` demo defaults build the proxy with:

- `DNS_RESOLVERS=169.254.169.253,1.1.1.1,8.8.8.8`
- `DNS_QUERIES_PER_SNI=3`

That means Lua queries Route 53 Resolver, Cloudflare DNS, and Google DNS three times each, unions all A records it sees, and only then compares the original destination IP. The Terraform demo policy also allows the proxy to send DNS traffic to `1.1.1.1` and `8.8.8.8`.

#### 1c. Build the workload AMI

```bash
cd ../workload
packer init .
packer build \
  -var "git_sha=$(git rev-parse --short HEAD)" \
  -var "packer_vpc_id=$(terraform -chdir=../build-infra output -raw vpc_id)" \
  -var "packer_subnet_id=$(terraform -chdir=../build-infra output -raw subnet_id)" \
  .
```

### 2. Deploy the infrastructure

```bash
cd ../../terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

Edit `terraform.tfvars` to choose your environment name, CIDRs, instance sizes, ANF allowlist, and nginx allowlist before applying.

Terraform discovers the most recent matching AMIs via:

- `data "aws_ami" "nginx_proxy"`
- `data "aws_ami" "workload"`

If you rebuild an AMI later, a follow-up `terraform apply` rolls the corresponding instance forward to the newest image.

Give the EC2 instances about 60 seconds after `apply` finishes so:

- the SSM agent can register
- the proxy can fetch the initial SNI allowlist from SSM

### 3. Run the integration tests

```bash
python -m venv .venv
source .venv/bin/activate          # Windows PowerShell: .venv\Scripts\Activate.ps1
pip install -e .
pip install -e ./tests
pytest -v tests
```

The tests use AWS SSM Run Command against the workload and proxy EC2s - no SSH required.

### 4. Manual verification

Connect to the workload EC2 via EC2 Instance Connect or use SSM Run Command, then:

```bash
# Allowed destination chosen by normal DNS
curl -v https://google.com --max-time 10
# Expected: succeeds

# Spoofed destination
curl -v --resolve google.com:443:1.1.1.1 https://google.com --max-time 10
# Expected: connection reset / failure because the proxy detects SNI spoofing

# Blocked domain
curl -v https://example.com --max-time 10
# Expected: connection reset / failure because the on-host allowlist denies it
```

### 5. Change the allowlist without a redeploy

The nginx SNI allowlist lives in SSM Parameter Store at:

- `/<env>-proxy/nginx-sni-allowlist`

Example:

```bash
aws ssm put-parameter \
  --name /dev-proxy/nginx-sni-allowlist \
  --type StringList \
  --overwrite \
  --value "amazonaws.com,cdn.amazonlinux.com"
```

The proxy refresh timer picks that up within about 60 seconds.

The ANF rule group is still managed by Terraform via `var.allowed_fqdns`; the two allowlists are independent by design.

### 6. Run the benchmark (optional)

```bash
cp benchmark/config.example.yaml benchmark/config.yaml
python benchmark/run.py --config benchmark/config.yaml
python benchmark/run.py --config benchmark/config.yaml --fqdn google.com
```

See `benchmark/README.md` for the full benchmark workflow and config schema.

### 7. Tear down

```bash
cd terraform && terraform destroy
cd ../packer/build-infra && terraform destroy
```

Terraform does not deregister the Packer-built AMIs; remove them manually if you want a full cleanup.

## Debugging

Observability is tuned for a small CloudWatch footprint, so two verbose signals
are **off by default** and toggled at the nginx level — no infrastructure change
needed, because the log group and CloudWatch agent collection are already
provisioned (see `monitoring/`).

**Per-connection access log.** In production this is millions of lines and
dominates CloudWatch Logs ingestion cost, so it is disabled. To capture it
while debugging:

- On a running proxy instance: uncomment the
  `access_log /var/log/nginx/access.log proxy;` line in `/etc/nginx/nginx.conf`
  and `sudo nginx -s reload`.
- Or bake it into the AMI: uncomment the same line in
  `packer/nginx-proxy/assets/nginx/conf/nginx.conf.template` and rebuild.

Lines flow to the `/aws/firewall-proxy/nginx/access` group within ~a minute. The
`proxy` log format records every session with its `decision`, SNI, dst IP, and
resolved IPs — useful for inspecting *allowed* traffic, which the sparse event
logs intentionally omit.

**Verbose Lua diagnostics.** Set `PROXY_DEBUG=1` in
`/etc/sysconfig/aws-firewall-proxy-runtime` and restart nginx to emit
step-by-step `lua="sni-guard"` NOTICE lines (ClientHello parse details, DNS
resolution, allow/deny reasoning) to `error.log`.

## Key design decisions

- **`source_dest_check = false`** on the proxy ENI - required for transparent proxying.
- **iptables `PREROUTING` REDIRECT** - steers inbound port 443 to the proxy listener on 8443 without client-side configuration.
- **Custom C module for `SO_ORIGINAL_DST`** - surfaces the pre-NAT destination IP to nginx/OpenResty.
- **Lua preread policy** - parses ClientHello directly, enforces the allowlist, resolves DNS, and logs spoofing detections.
- **Configurable DNS fanout** - the proxy can query multiple resolvers repeatedly for each SNI, then union the returned A records before deciding.
- **Golden AMI via Packer** - avoids boot-time package drift and keeps the proxy runtime reproducible.
- **Two independent allowlists (nginx + ANF)** - defense in depth; either layer can deny.

## DNS Matching Caveat

The SNI/original-dst check asks: "does the destination IP appear in the DNS answers we can observe for this SNI?" That is useful, but it is not a perfect truth oracle.

For names such as `google.com`, repeated `nslookup google.com 8.8.8.8` calls may return one different IP each time. Other names, such as `login.microsoftonline.com`, may return 10 or more addresses in a single response. Both behaviors are normal. Large providers use recursive resolver location, cache state, TTLs, load balancing, and CDN edge selection to vary answers.

Production implication: strict dropping on DNS mismatch can false-positive for high-scale CDN-style domains. The project therefore makes the resolver list and query count explicit:

- `DNS_RESOLVERS`: comma-separated resolver list baked into the proxy AMI
- `DNS_QUERIES_PER_SNI`: number of A-record queries per resolver, clamped to `1..16`

The demo uses Route 53 Resolver plus `1.1.1.1` and `8.8.8.8`, with three queries per resolver. This improves coverage, but it still does not guarantee completeness. For production workloads, treat the DNS comparison as a high-confidence signal whose enforcement mode should be chosen per risk appetite and domain behavior.
