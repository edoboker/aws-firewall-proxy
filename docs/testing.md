# Testing Guide

## Deploy order

`terraform apply` creates everything, but the ECS task will fail to start until the nginx image exists in ECR. Follow this order:

### 1. terraform apply

```cmd
cd terraform
terraform apply
```

### 2. Build and push the nginx image

**Bash:**
```bash
ECR_URL=$(terraform output -raw ecr_repository_url)
ECR_REGISTRY=$(echo $ECR_URL | cut -d/ -f1)
aws ecr get-login-password --region eu-north-1 | docker login --username AWS --password-stdin $ECR_REGISTRY
docker build -t $ECR_URL:latest ../docker/nginx/
docker push $ECR_URL:latest
```

**PowerShell:**
```powershell
$ECR_URL = terraform output -raw ecr_repository_url
$ECR_REGISTRY = ($ECR_URL -split "/")[0]
$ECR_PASSWORD = aws ecr get-login-password --region eu-north-1
docker login --username AWS --password $ECR_PASSWORD $ECR_REGISTRY
docker build -t "${ECR_URL}:latest" ..\docker\nginx\
docker push "${ECR_URL}:latest"
```

### 3. Wait for the ECS task to start

The ECS service (`desired_count = 1`) automatically schedules the nginx container on the proxy EC2 once:
- The EC2 instance has booted and the ECS agent has registered with the cluster (~1–2 min)
- The image is available in ECR

No manual container run is needed. Check it's running:

**Bash:**
```bash
aws ecs list-tasks --cluster dev-proxy

aws ecs describe-tasks --cluster dev-proxy \
  --tasks $(aws ecs list-tasks --cluster dev-proxy --query 'taskArns[0]' --output text) \
  --query 'tasks[0].lastStatus'
# Expected: "RUNNING"
```

**PowerShell:**
```powershell
aws ecs list-tasks --cluster dev-proxy

$TASK_ARN = aws ecs list-tasks --cluster dev-proxy --query 'taskArns[0]' --output text
aws ecs describe-tasks --cluster dev-proxy --tasks $TASK_ARN --query 'tasks[0].lastStatus'
```

If the task is stuck in `PENDING`, the EC2 hasn't registered yet — wait another minute and retry.

### 4. Connect to the workload EC2

**Bash:**
```bash
INSTANCE_ID=$(terraform output -raw workload_instance_id)
aws ssm start-session --target $INSTANCE_ID
```

**PowerShell:**
```powershell
$INSTANCE_ID = terraform output -raw workload_instance_id
aws ssm start-session --target $INSTANCE_ID
```

---

## Checks

### Check 1 — iptables rules are active (on the proxy EC2)

The nginx container's entrypoint sets iptables rules on the host (host network mode). Verify from the proxy EC2 (add SSM to it if needed, same pattern as the workload):

```bash
iptables -t nat -L -n -v
```

Expected: PREROUTING has a REDIRECT rule for `dpt:443 → 8443`, and OUTPUT has a RETURN rule for the nginx UID.

```bash
sysctl net.ipv4.ip_forward   # Expected: 1
ss -tlnp | grep 8443         # Expected: nginx listening
```

### Check 2 — Normal HTTPS works (baseline)

From the workload EC2 SSM session (Linux shell):

```bash
curl -v https://google.com --max-time 10
```

Expected: TLS handshake succeeds, HTTP 200/301 response. This confirms traffic flows workload → proxy → ANF → NAT GW → internet.

---

## Core Security Test — SNI/IP spoofing is neutralised

This is the key test. It simulates an attacker sending a packet with `SNI=google.com` but routing it to a different IP (`1.1.1.1`, Cloudflare — not owned by Google).

**Without this proxy**, AWS Network Firewall would pass the packet because the SNI matches `google.com`.

**With this proxy**, nginx reads the SNI, resolves `google.com` via DNS, and connects to the real Google IP — the original destination IP in the packet is completely ignored.

Run from the **workload EC2 SSM session** (Linux shell):

```bash
curl -v --resolve google.com:443:1.1.1.1 https://google.com --max-time 10
```

- `--resolve google.com:443:1.1.1.1` forces the curl client to connect to `1.1.1.1` instead of the real Google IP — this is the spoofed packet.
- Expected: **the request succeeds and returns a Google response**, but the connection went to Google's real IP, not `1.1.1.1`.

To confirm the proxy overrode the destination, check the nginx access log in CloudWatch (`/ecs/dev-proxy/nginx`). You will see `google.com` as the upstream — not `1.1.1.1`.

Try the same with an IP that has no port 443 at all:

```bash
curl -v --resolve google.com:443:192.0.2.1 https://google.com --max-time 10
# Expected: succeeds — proxy ignores 192.0.2.1 and connects to real google.com
```

---

## Blocked Domain Test

From the workload EC2 SSM session:

```bash
curl -v https://evil.example.com --max-time 10
# Expected: connection times out — dropped by ANF
```

Check the ANF alert log in CloudWatch (`/aws/network-firewall/dev-proxy/alert`) to confirm a DROP event was recorded.

---

## Verify Traffic Path via CloudWatch

Open the ANF flow log group `/aws/network-firewall/dev-proxy/flow`. All egress connections should show the **proxy's private IP** as the source — not the workload EC2's IP. If you see the workload IP directly, the workload subnet route table is misconfigured.
