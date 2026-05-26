# aws-firewall-proxy

Transparent forward proxy that prevents SNI-spoofed egress by overriding the
actual upstream destination, then detects suspicious original destinations
asynchronously.

AWS Network Firewall FQDN rules inspect the TLS SNI value, but they do not
verify that the client is actually connecting to an IP that belongs to that
hostname. A client can claim an allowed SNI while routing traffic to a different
IP. This project inserts a transparent proxy into the VPC egress path so the
proxy can:

- recover the original destination IP before NAT
- read the ClientHello SNI with nginx `ssl_preread`
- ignore the original destination for forwarding
- connect upstream to the proxy-resolved SNI host
- emit structured `{SNI, original_dst}` observations
- detect suspected SNI spoofing asynchronously in Lambda

Important production caveat: prevention and detection are separate. The proxy
prevents the original spoofed destination from being contacted because it always
forwards to `$ssl_preread_server_name:443`. The later DNS-to-original-destination
comparison is probabilistic for large, geo-distributed, CDN-backed services and
can false-positive. Detection is a signal, not proof, and it does not block
traffic.

## Architecture

```text
Workload EC2  -->  nginx proxy EC2  -->  AWS Network Firewall  -->  NAT GW  -->  Internet
 (10.0.1.0/24)      (10.0.2.0/24)         (10.0.3.0/24)              (10.0.4.0/24)
```

- **Workload subnet** - client EC2 instance; default route points to the proxy ENI.
- **Proxy subnet** - transparent OpenResty intercepts TLS via iptables REDIRECT, recovers `SO_ORIGINAL_DST` via a custom C stream module, reads SNI with `ssl_preread`, and forwards to `$ssl_preread_server_name:443` rather than the original destination IP. A compact JSON observation log is shipped to CloudWatch Logs.
- **Async detector** - CloudWatch Logs invokes a Lambda for override observations. The Lambda resolves the SNI, compares the original destination IP with current A records, logs suspected spoofing alerts, and publishes the `AwsFirewallProxy/SuspectedSniSpoofing` metric.
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

This builds an AL2023-based AMI with OpenResty, the original-dst C module, nginx `ssl_preread` SNI routing, AWS AppConfig Agent, the runtime policy sync service, iptables-services, awscli v2, and CloudWatch agent config baked in. Mutable proxy policy is no longer baked into the AMI.

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
- the AppConfig agent can prefetch the deployed runtime policy
- the proxy can render its initial allowlist, resolver config, and Lua policy before nginx starts

### 3. Run the integration tests

```bash
make setup
make test
```

The tests use AWS SSM Run Command against the workload and proxy EC2s - no SSH required.

If you prefer the manual flow, it is still:

```bash
python -m venv .venv
source .venv/bin/activate          # Windows PowerShell: .venv\Scripts\Activate.ps1
pip install -e .
pip install -e ./tests
pytest -v tests
```

### 4. Manual verification

Connect to the workload EC2 via EC2 Instance Connect or use SSM Run Command, then:

```bash
# Allowed destination chosen by normal DNS
curl -v https://google.com --max-time 10
# Expected: succeeds

# Spoofed original destination
curl -v --resolve google.com:443:1.1.1.1 https://google.com --max-time 10
# Expected: proxy forwards to google.com:443, not 1.1.1.1; async detector may later alert

# Blocked domain
curl -v https://example.com --max-time 10
# Expected: depends on downstream firewall/DNS policy; TLS override proxy no longer enforces an on-host SNI allowlist
```

### 5. Change proxy runtime policy

Terraform now owns the proxy runtime policy content in AppConfig. Update:

- `nginx_allowed_snis`
- `proxy_public_dns_resolvers`
- `proxy_dns_queries_per_sni`
- `proxy_enforcement_mode`

Then run:

```bash
terraform apply
```

The proxy refresh timer picks up the deployed AppConfig version from the local AppConfig Agent within about 60 seconds and reloads nginx only if the rendered runtime policy changed.

AppConfig is the runtime source of truth for the proxy policy.

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

Observability is tuned for a small CloudWatch footprint. Override observations
are always written as compact JSON to
`/var/log/nginx/override_observations.log` and shipped to
`/aws/firewall-proxy/nginx/override-observations`. The CloudWatch log stream
name is the EC2 instance ID, so the async detector can include that context in
alert logs without adding instance metadata to the nginx JSON body.

Operational dashboards no longer depend only on log-derived metrics. The proxy
publishes aggregated metrics directly to the local CloudWatch agent every
`proxy_metrics_publish_interval_seconds` seconds (default `20`), while the
debug toggles below remain optional.

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

**Verbose Lua diagnostics for HTTP.** Set `PROXY_DEBUG=1` in
`/etc/sysconfig/aws-firewall-proxy-runtime` and restart nginx to emit
step-by-step HTTP guard NOTICE lines to `error.log`. The TLS override path does
not use Lua.

## Key design decisions

- **`source_dest_check = false`** on the proxy ENI - required for transparent proxying.
- **iptables `PREROUTING` REDIRECT** - steers inbound port 443 to the proxy listener on 8443 without client-side configuration.
- **Custom C module for `SO_ORIGINAL_DST`** - surfaces the pre-NAT destination IP to nginx/OpenResty.
- **nginx `ssl_preread` SNI routing** - reads ClientHello SNI without terminating TLS and forwards to `$ssl_preread_server_name:443`.
- **AppConfig-backed runtime policy** - allowlist, DNS fanout, and enforcement mode are deployed as one runtime document and rendered locally on the proxy.
- **Async spoofing detector** - evaluates `{SNI, original_dst}` observations after the fact and emits a non-blocking metric/alarm signal.
- **Golden AMI via Packer** - avoids boot-time package drift and keeps the proxy runtime reproducible.
- **Forwarding override before detection** - prevention comes from ignoring the client-selected destination IP for upstream connection setup.

## DNS Matching Caveat

The async SNI/original-dst check asks: "does the original destination IP appear
in the DNS answers we can observe for this SNI right now?" That is useful, but
it is not a perfect truth oracle.

For names such as `google.com`, repeated `nslookup google.com 8.8.8.8` calls may return one different IP each time. Other names, such as `login.microsoftonline.com`, may return 10 or more addresses in a single response. Both behaviors are normal. Large providers use recursive resolver location, cache state, TTLs, load balancing, and CDN edge selection to vary answers.

Production implication: suspected spoofing alerts can false-positive for
high-scale CDN-style domains. In this architecture, those alerts do not block
traffic. Treat the DNS comparison as a useful investigation signal whose
confidence depends on domain behavior, resolver choice, cache state, and timing.
