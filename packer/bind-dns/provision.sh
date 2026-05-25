#!/bin/bash
# AMI provisioning for the shared recursive DNS cache:
#   * install BIND/named on AL2023
#   * render a restricted recursive-cache configuration
#   * enable named so instances boot ready to serve workload/proxy DNS
set -euo pipefail

ASSET_ROOT=/tmp/assets
BIND_ALLOW_QUERY_CIDR="${BIND_ALLOW_QUERY_CIDR:-10.0.0.0/16}"
BIND_MIN_CACHE_TTL="${BIND_MIN_CACHE_TTL:-90}"
BIND_STALE_ANSWER_TTL="${BIND_STALE_ANSWER_TTL:-30}"

log_step() {
  echo "[bind-dns-ami] $1"
}

run_quiet() {
  local step="$1"
  local log_file="$2"
  shift 2

  log_step "$step"
  if ! "$@" >"$log_file" 2>&1; then
    echo "$step failed; tail of $log_file:" >&2
    tail -n 200 "$log_file" >&2 || true
    exit 1
  fi
}

require_number() {
  local name="$1"
  local value="$2"

  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "$name must be a whole number of seconds, got: $value" >&2
    exit 1
  fi
}

require_number "BIND_MIN_CACHE_TTL" "$BIND_MIN_CACHE_TTL"
require_number "BIND_STALE_ANSWER_TTL" "$BIND_STALE_ANSWER_TTL"

if (( BIND_MIN_CACHE_TTL > 90 )); then
  echo "BIND_MIN_CACHE_TTL must be <= 90 because BIND caps min-cache-ttl at 90 seconds, got: $BIND_MIN_CACHE_TTL" >&2
  exit 1
fi

# Wait for cloud-init so dnf locks are released.
cloud-init status --wait || true

run_quiet "Installing BIND packages" /var/log/bind-dns-dnf-install.log \
  dnf install -y -q bind bind-utils

log_step "Rendering named.conf"
install -d -m 0755 /etc/named
sed \
  -e "s|__BIND_ALLOW_QUERY_CIDR__|${BIND_ALLOW_QUERY_CIDR}|g" \
  -e "s|__BIND_MIN_CACHE_TTL__|${BIND_MIN_CACHE_TTL}|g" \
  -e "s|__BIND_STALE_ANSWER_TTL__|${BIND_STALE_ANSWER_TTL}|g" \
  "${ASSET_ROOT}/named.conf" > /etc/named.conf
chmod 0644 /etc/named.conf

log_step "Installing named systemd override"
install -d -m 0755 /etc/systemd/system/named.service.d
install -m 0644 "${ASSET_ROOT}/systemd/named.service.d/override.conf" \
  /etc/systemd/system/named.service.d/override.conf

log_step "Preparing named runtime directories"
install -d -o named -g named -m 0750 /var/log/named
install -d -o named -g named -m 0750 /var/named/data
install -d -o named -g named -m 0750 /var/named/dynamic

systemctl daemon-reload

run_quiet "Validating BIND configuration" /var/log/named-checkconf.log \
  named-checkconf -z /etc/named.conf

log_step "Enabling named"
systemctl enable named

run_quiet "Cleaning package manager caches" /var/log/bind-dns-dnf-clean.log dnf clean all
rm -rf \
  /var/cache/dnf \
  /tmp/assets

log_step "BIND DNS AMI provisioning complete"
