# Ruleset generator - MVP task list

This is a parallel experimental path, not a primary replacement for the
nginx/OpenResty proxy. The ruleset generator resolves a small Terraform-owned
list of exact FQDNs, publishes the observed IPv4 addresses into
customer-managed VPC prefix lists, and lets AWS Network Firewall reference those
prefix lists through a separate IP-based stateful rule group.

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
- The Terraform feature flag defaults off: `enable_ruleset_generator = false`.
- Terraform lives in the main `terraform/` root and the main state owns the
  Lambda, prefix list, rule group, and firewall-policy attachment.
- The ruleset-generator rule group is separate from the normal SNI/FQDN rule
  group, so behavior stays isolated even though state ownership is unified.
- Ruleset-generator FQDNs must not also appear in `allowed_fqdns`; the broad
  SNI-only allowlist would otherwise pass spoofed destinations before the
  generated SNI+IP binding matters.

## Tradeoffs

The ruleset generator is attractive because it removes the nginx proxy from the
datapath for selected domains and turns DNS sampling into a scheduled
control-plane update. For the MVP, each generated rule requires both exact SNI
and membership in that FQDN's generated prefix list. CDN rotation can still make
the prefix list stale between Lambda runs, and per-FQDN prefix lists will not
scale indefinitely.

For the MVP, failures are conservative: the Lambda only modifies prefix lists
after a complete successful resolution pass. If resolution or publishing fails,
the existing prefix-list entries remain in place.

## Task list

### L1 - Design doc and isolation

- Keep this document as the MVP task list and tradeoff record.
- State that subdomains, wildcard discovery, observability, scaling, benchmarks,
  and cost work are intentionally out of scope for the MVP.

### L2 - Minimal Terraform shell

- Add gated Terraform variables/resources for the ruleset-generator stack.
- Include Lambda IAM role, Lambda function package, CloudWatch log group, and an
  optional EventBridge schedule.
- Keep all resources behind `enable_ruleset_generator = false` by default.
- Do not change nginx proxy, BIND, or shared-DNS behavior.

### L3 - Resolver Lambda MVP

- Read the Terraform-provided exact FQDN list from the Lambda environment.
- Resolve each FQDN through the platform resolver, Cloudflare, and Google.
- Deduplicate IPv4 answers, cap each FQDN at 64 addresses, and produce `/32`
  CIDR entries.

### L4 - Prefix-list publishing

- Create customer-managed IPv4 prefix lists sized for the MVP.
- Replace prefix-list entries with the latest complete successful result.
- Leave existing entries untouched if any resolution or publish step fails.

### L5 - Network Firewall integration

- Add a separate stateful rule group with TLS pass rules whose destinations are
  per-FQDN ruleset-generator prefix-list IP sets and whose `tls.sni` condition
  exactly matches that same FQDN.
- Attach that rule group to the main firewall policy after the normal SNI/FQDN
  rule group when `enable_ruleset_generator = true`.
- Do not change the existing nginx/SNI allowlist rule group semantics.

## Minimal tests

- Static tests only:
  - ruleset-generator feature defaults off
  - FQDN list contains `login.microsoftonline.com` and `wiz.io`
  - Lambda, prefix list, and Network Firewall rule group resources are gated
  - nginx/shared-DNS resources are not required by the MVP

No unit, integration, runtime, benchmark, or cost tests are part of this MVP.
