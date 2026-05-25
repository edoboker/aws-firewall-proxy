# BIND DNS AMI assets

This directory contains the runtime files copied into the shared recursive DNS cache AMI.

- `named.conf` is a template rendered by `provision.sh`.
- `systemd/named.service.d/override.conf` makes the resolver restart on transient failures.

The rendered resolver is intentionally recursive-only. It listens on port 53, allows
queries only from localhost and the workload VPC CIDR passed as `bind_allow_query_cidr`,
forwards cache misses to the DNS VPC's Route 53 Resolver, and keeps short-lived positive
answers around with BIND's maximum `min-cache-ttl` setting plus serve-stale behavior.
BIND-side DNSSEC validation is disabled for this forwarder-cache mode to avoid SERVFAIL
on otherwise valid answers from AmazonProvidedDNS.
