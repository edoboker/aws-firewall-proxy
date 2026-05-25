# Lambda IP fallback - MVP task list

This is a parallel experimental fallback, not a primary replacement for the
nginx/OpenResty proxy. The fallback resolves a small Terraform-owned list of
exact FQDNs, publishes the observed IPv4 addresses into a customer-managed VPC
prefix list, and lets AWS Network Firewall reference that prefix list through a
separate IP-based stateful rule group.

The MVP is intentionally narrow. It covers only L1-L5 from the feature plan and
defers observability, advanced error handling, fast feedback from client errors,
parallel fan-out, scale work, benchmarks, and cost analysis.

## Initial scope

- Exact FQDNs only:
  - `login.microsoftonline.com`
  - `wiz.io`
- IPv4 A records only.
- Up to 64 addresses per FQDN.
- Resolver sources:
  - the Lambda runtime's platform resolver, representing the AWS/Route 53 view
  - Cloudflare (`1.1.1.1`)
  - Google (`8.8.8.8`)
- The Terraform feature flag defaults off: `enable_lambda_ip_fallback = false`.
- Terraform lives in the main `terraform/` root and the main state owns the
  Lambda, prefix list, fallback rule group, and firewall-policy attachment.
- The fallback rule group is separate from the normal SNI/FQDN rule group, so
  behavior stays isolated even though state ownership is unified.

## Tradeoffs

The fallback is attractive because it removes the nginx proxy from the datapath
for the selected domains and turns DNS sampling into a scheduled control-plane
update. It is also weaker than the proxy: once traffic is allowed by IP, Network
Firewall no longer proves that the client used the expected SNI for that
destination. CDN rotation can also make the prefix list stale between Lambda
runs.

For the MVP, failures are conservative: the Lambda only modifies the prefix list
after a complete successful resolution pass. If resolution or publishing fails,
the existing prefix-list entries remain in place.

## Task list

### L1 - Design doc and isolation

- Keep all work in a sibling worktree on `feature/lambda-ip-fallback`.
- Add this document as the MVP task list and tradeoff record.
- State that subdomains, wildcard discovery, observability, scaling, benchmarks,
  and cost work are intentionally out of scope for the MVP.

### L2 - Minimal Terraform shell

- Add gated Terraform variables/resources for the fallback stack.
- Include Lambda IAM role, Lambda function package, CloudWatch log group, and an
  optional EventBridge schedule.
- Keep all resources behind `enable_lambda_ip_fallback = false` by default.
- Keep all resources behind `enable_lambda_ip_fallback = false` by default.
- Do not change nginx proxy, BIND, or shared-DNS behavior.

### L3 - Resolver Lambda MVP

- Read the Terraform-provided exact FQDN list from the Lambda environment.
- Resolve each FQDN through the platform resolver, Cloudflare, and Google.
- Deduplicate IPv4 answers, cap each FQDN at 64 addresses, and produce `/32`
  CIDR entries.

### L4 - Prefix-list publishing

- Create one customer-managed IPv4 prefix list sized for the MVP.
- Replace prefix-list entries with the latest complete successful result.
- Leave existing entries untouched if any resolution or publish step fails.

### L5 - Network Firewall integration

- Add a separate stateful rule group with a TLS pass rule whose destination is
  the fallback prefix-list IP set.
- Attach that rule group to the main firewall policy after the normal SNI/FQDN
  rule group when `enable_lambda_ip_fallback = true`.
- Do not change the existing nginx/SNI allowlist rule group semantics.

## Minimal tests

- Static tests only:
  - fallback feature defaults off
  - fallback FQDN list contains `login.microsoftonline.com` and `wiz.io`
  - Lambda, prefix list, and fallback Network Firewall rule group resources are gated
  - nginx/shared-DNS resources are not required by the fallback MVP

No unit, integration, runtime, benchmark, or cost tests are part of this MVP.
