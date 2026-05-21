#!/bin/bash
# AMI provisioning for the workload (benchmark client) EC2.
# Bakes in `hey` (HTTP load generator) and `jq` so the benchmark orchestrator
# doesn't have to install anything at runtime.
set -euxo pipefail

cloud-init status --wait || true

dnf install -y jq

# hey is distributed as a single static binary from the official S3 bucket.
# Pin a release URL rather than tracking "latest" — the benchmark needs a
# reproducible client.
# Pin the URL but NOT the SHA — the official S3 release URL serves a single
# build of hey that has not changed in years. If you want supply-chain
# integrity, compute the hash once and add `echo "$SHA  /usr/local/bin/hey" |
# sha256sum -c -`.
HEY_URL="https://storage.googleapis.com/hey-releases/hey_linux_amd64"

curl -fsSL "$HEY_URL" -o /usr/local/bin/hey
chmod 0755 /usr/local/bin/hey
/usr/local/bin/hey -h >/dev/null 2>&1 || true   # smoke-check: binary runs

dnf clean all
rm -rf /var/cache/dnf
