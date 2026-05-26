# Pre-submission cleanup tasks

Findings to address before submitting this repo. Each item is a **removal/fix
candidate** — the *why* is noted so the keep/cut decision is informed.

Context: the repo evolved through three designs (resolve-and-block →
planned shared-DNS-cache → the current **override proxy + async detection**).
Most items below are leftover sediment from those pivots. The cleanest
submission keeps only what matches the current README architecture.

---

## A. Embarrassing — raw AI/working artifacts committed as "docs"

- [ ] **`docs/override-async-alert-proxy.md`** — Literally the raw LLM prompt:
  opens with `**Original prompt for goal**: You are working in the existing
  aws-firewall-proxy repository...` + a pasted implementation plan. Reveals the
  feature was AI-prompted. Also uses `eu-west-1a` examples (project is
  `eu-north-1`).
- [ ] **`docs/SNI Spoofing Abuse Research Plan.md`** — "Deep research" dump:
  inline citation-number artifacts fused into prose (`...dilemma.1`,
  `...handshake.3`), 60 footnote links all "accessed on May 25, 2026", title
  wrapped in literal markdown asterisks, **filename has spaces**. Titled
  "Research *Plan*" but it's a finished report.
- [ ] **`docs/observability-v3.md`** — Untitled raw bullet-dump (no `#`
  heading), reads like scratch notes. "v3" implies a v1/v2 that don't exist; the
  real doc is `observability.md`.

## B. Stale docs that contradict what was actually built

The README/implementation is "override proxy + async detection." These docs
describe rejected or never-built designs and confuse what's real.

- [ ] **`docs/shared-dns-cache.md`** — §3 explicitly **rejects "override mode"**,
  which is exactly the implemented default. Describes a BIND9 + second-VPC +
  Route 53 Resolver tier that was never built (a test asserts it's absent).
- [ ] **`docs/shared-dns-cache-tasks.md`** — Task list for that same un-built
  BIND feature.
- [ ] **`docs/certificate-validation-probe-tradeoffs.md`** — Recommends "shared
  DNS cache" as the *final* architecture; contains presentation meta
  ("**Suggested slide wording**", "for a product or **assignment** narrative",
  first-person "I would position this").
- [ ] **`docs/product.md`** — Still describes the OLD resolve-and-block model
  ("Drops packets where IP ≠ resolved IPs", "Squid/Envoy"). Cross-ref to
  `production-grade-plan.md §12` is wrong (§12 is allowlist change-mgmt, not the
  TLS-termination rationale it claims).
- [ ] **`docs/lambda-ip-fallback-tasks.md`** — Uses the old "lambda-ip-fallback"
  name (since renamed to "ruleset_generator").
- [ ] **`docs/scaling-in-production.md`** — Still leads with the old live
  Lua-DNS-per-connection bottleneck (`check_sni.lua`, no Lua cache). The current
  TLS override path is `ssl_preread` + nginx resolver + async detection, so this
  doc should either be rewritten around the implemented path or moved to
  old-design notes.
- [ ] **`docs/production-grade-plan.md`** — Re-check the observability guidance:
  recommendations like sparse security-event logging may conflict with the
  current async detection pipeline, which depends on override-observation events.
- [ ] **Current README/Packer README runtime-policy drift** — `README.md` still
  lists legacy-looking AppConfig knobs (`nginx_allowed_snis`,
  `proxy_dns_queries_per_sni`, `proxy_enforcement_mode`), while
  `packer/nginx-proxy/README.md` explains Lua metrics/runtime-policy behavior in
  detail. Keep only what is true for the current TLS override architecture, or
  clearly label HTTP-only/helper behavior.

## C. Dead/orphaned code from the override-proxy pivot

- [ ] **`packer/nginx-proxy/assets/nginx/lua/check_sni.lua`** (639 lines) — Heart
  of the *old* design. No longer wired into `nginx.conf.template` (the `8443`
  server uses `ssl_preread` + `proxy_pass`, no Lua; a test asserts `check_sni.lua`
  is NOT referenced). Still installed by `provision.sh`. **Dead** — also drop its
  install line in `provision.sh`.
- [ ] **`terraform/dns_firewall.tf`** — Entire 58-line file is commented out.
- [ ] **`variable "enable_dns_firewall"`** (`terraform/variables.tf`) — Orphaned;
  only "consumer" is the commented-out file above.
- [ ] **`terraform/ruleset_generator_moved.tf`** — Terraform `moved{}` rename
  scaffolding. Only useful to migrate *existing* state; in a fresh submission it
  references resource names that no longer exist.
- [ ] *(judgment call)* `packer/nginx-proxy/assets/nginx/lua/debug_log_by_lua.lua`
  — Dev-only "uncomment to enable" hook, unreferenced.
- [ ] **Old CloudWatch/Lua observability residue** — `terraform/observability.tf`
  still defines log groups, metric filters, and dashboard widgets for old
  `sni_spoofing`, `policy_denied`, and Lua StatsD metrics. Decide whether these
  are still produced by the current TLS override path, HTTP-only residue, or
  dead dashboard noise.
- [ ] **CloudWatch agent log tail list** —
  `packer/nginx-proxy/assets/cloudwatch/amazon-cloudwatch-agent.json` still tails
  `sni_spoofing.log`, `policy_denied.log`, and `access.log`. Confirm whether each
  log is still intentionally emitted; otherwise drop the tail entry and matching
  CloudWatch resources.
- [ ] **Old nginx Lua-decision variables/log formats** —
  `nginx.conf.template` still contains variables and log formats for
  `$proxy_decision`, `$client_sni`, `$resolved_ips`, `$dst_ip`,
  `$proxy_target`, `policy_denied_log_format`, and related policy-denied access
  logging. Remove or explicitly mark as HTTP-only if the experimental HTTP path
  survives.
- [ ] **AppConfig runtime policy leftovers** — `nginx_allowed_snis`,
  `proxy_dns_queries_per_sni`, `proxy_enforcement_mode`, related outputs,
  runtime policy schema fields, and AppConfig JSON content appear tied to the old
  on-host guard or the experimental HTTP path. Remove them or document them as
  HTTP-only before submission.
- [ ] **Lua metrics modules** — `init_metrics.lua`, `log_metrics.lua`, and
  `proxy_metrics.lua` look like old request-path metric plumbing. Verify whether
  the TLS override path still calls them; if not, remove the modules, install
  lines, CloudWatch dashboard panels, and tests together.

## D. Orphaned BIND / shared-DNS infrastructure (never deployed)

- [x] **`packer/bind-dns/`** (whole dir) — Builds a BIND9 AMI for the shared-DNS
  feature that was never wired into Terraform. No `packer-build-bind` target, not
  in `packer-build-all`/`deploy-all`, and a test asserts the BIND Terraform was
  removed. **Orphaned.**
- [x] **Makefile BIND remnants** — `PACKER_BIND_*` vars + `packer-validate-bind`
  target (no build target), supporting the above.

## E. Stale / zombie tests

- [x] **`tests/test_sni_spoofing.py`** — Wholly skipped; references removed log
  group `/aws/firewall-proxy/nginx/sni-spoofing`, metric `SpoofingDetected`,
  namespace `AwsFirewallProxy/Nginx` (all old design).
- [x] **`tests/test_policy_enforcement.py`** — Wholly skipped ("deferred for
  override-proxy architecture"), old design.
- [x] **`tests/test_proxy_metrics.py`** — Wholly skipped, old Lua-metrics design.
- [x] **`tests/test_terraform_static.py::test_dns_firewall_association_can_be_temporarily_disabled`**
  — **Zombie test**: "passes" by regex-matching text *inside the fully
  commented-out* `dns_firewall.tf` — i.e. asserts the behavior of disabled code.
- [x] **`tests/conftest.py` runtime-policy fixtures** — Still derive test inputs
  from `nginx_allowed_snis` and `proxy_enforcement_mode`, which are old on-host
  guard assumptions unless the HTTP path is intentionally kept.
- [x] **`tests/test_appconfig_policy_schema.py`** — Comments/test intent still
  reference `check_sni.lua` re-validating the runtime policy bounds.
- [x] **Terraform static observability tests** — Dashboard assertions still expect
  old Lua/StatsD metrics such as `SniMismatchCount` and
  `P50ProxyDecisionLatencyMs`. Rewrite around the implemented async detection
  signals or delete with the old metrics.
- [x] **BIND-removal assertions** — Broadened the existing "BIND Terraform
  removed" test to cover stale Packer/Makefile BIND remnants too.

## F. Privacy / professionalism

- [x] **Hardcoded real AWS account ID** baked into the state-bucket name in
  **`terraform/versions.tf`** and **`terraform/packer-bootstrap/main.tf`**.
  Leaked an account-specific identifier; fixed by moving the bucket name to
  `terraform init -backend-config`.
  *(The `137112412989` owner IDs in the Packer files are Amazon's public AL2023
  owner — not a leak.)*
- [x] **Local Terraform state hygiene** — Verify `terraform/.terraform/` and
  `terraform/packer-bootstrap/.terraform/` are ignored and not tracked. Local
  state files can contain account IDs, ARNs, and environment-specific metadata.

## G. Minor / judgment calls

- [ ] **`benchmark/lambda_bench/`** (run.py docstring + README) — Reference
  `terraform/lambda_ip_fallback.tf`, renamed to `lambda_ruleset_generator.tf`.
  Doc-stale (the `FQDNS` env var it pokes still matches, so not broken).
- [ ] **`benchmark/lambda_bench/` naming drift** — The benchmark still refers to
  old Terraform outputs/config such as `lambda_ip_fallback_function_name`,
  `lambda_ip_fallback_prefix_list_id`, and `enable_lambda_ip_fallback`. Rename to
  the current ruleset-generator outputs/config if this benchmark is kept.
- [ ] **`benchmark/workload_bench/results/sample/summary.md`** — Committed
  "illustrative" (made-up) benchmark numbers. Honestly labeled, low concern.
- [ ] **Generated/local artifacts** — Check whether `tests/.venv/`,
  `__pycache__/`, non-sample benchmark result directories, and other generated
  outputs are ignored and untracked. If any are tracked, remove them from git
  while preserving local working copies as needed.
- [ ] **Experimental HTTP path** (`8081` + `check_http_host.lua`) — Half-finished
  prototype baked into the AMI but undocumented in the README (README is
  TLS-only). Not dead, but an incomplete feature in the submission — conscious
  keep/cut decision.
