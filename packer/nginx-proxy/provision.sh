#!/bin/bash
# AMI provisioning:
#   * build and install OpenResty with stream preread support
#   * compile and install the original-dst stream C module
#   * install the Lua SNI/original-dst guard
#   * bake in the SSM allowlist refresh timer and CloudWatch agent config
set -euo pipefail

ASSET_ROOT=/tmp/assets
OPENRESTY_VERSION=1.27.1.1
OPENRESTY_URL="https://openresty.org/download/openresty-${OPENRESTY_VERSION}.tar.gz"
OPENRESTY_SRC="/usr/local/src/openresty-${OPENRESTY_VERSION}"
DNS_RESOLVERS="${DNS_RESOLVERS:-${DNS_RESOLVER:-169.254.169.253}}"
DNS_RESOLVERS_FOR_NGINX="${DNS_RESOLVERS//,/ }"
DNS_QUERIES_PER_SNI="${DNS_QUERIES_PER_SNI:-1}"

log_step() {
  echo "[proxy-ami] $1"
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

# Wait for cloud-init so dnf locks are released.
cloud-init status --wait || true

run_quiet "Installing build and runtime packages" /var/log/proxy-dnf-install.log \
  dnf install -y -q \
  gcc \
  gcc-c++ \
  make \
  perl \
  pcre-devel \
  openssl-devel \
  zlib-devel \
  curl-minimal \
  tar \
  findutils \
  diffutils \
  iptables-services \
  awscli-2 \
  amazon-cloudwatch-agent

if ! id nginx >/dev/null 2>&1; then
  log_step "Creating nginx service account"
  groupadd --system nginx
  useradd --system --gid nginx --home-dir /var/cache/nginx --shell /sbin/nologin nginx
fi

mkdir -p \
  /etc/nginx/conf.d \
  /etc/nginx/lua \
  /usr/local/openresty/nginx/modules \
  /usr/local/src \
  /var/cache/nginx \
  /var/log/nginx

log_step "Fetching OpenResty source"
curl -fsSL "$OPENRESTY_URL" -o /tmp/openresty.tgz
tar -xzf /tmp/openresty.tgz -C /usr/local/src

pushd "$OPENRESTY_SRC"
run_quiet "Configuring OpenResty build" /var/log/openresty-configure.log \
  ./configure \
  --prefix=/usr/local/openresty \
  --conf-path=/etc/nginx/nginx.conf \
  --error-log-path=/var/log/nginx/error.log \
  --http-log-path=/var/log/nginx/access.log \
  --pid-path=/var/run/nginx.pid \
  --lock-path=/var/run/nginx.lock \
  --modules-path=/usr/local/openresty/nginx/modules \
  --with-pcre-jit \
  --with-stream \
  --with-stream_ssl_module \
  --with-stream_ssl_preread_module \
  --with-compat \
  --add-dynamic-module="${ASSET_ROOT}/nginx/c-module"

BUILD_LOG=/var/log/openresty-build.log
INSTALL_LOG=/var/log/openresty-install.log

run_quiet "Building OpenResty" "$BUILD_LOG" make -j"$(nproc)"

run_quiet "Installing OpenResty" "$INSTALL_LOG" make install
popd

log_step "Installing original-dst module and runtime assets"
install -m 0755 "$(find "$OPENRESTY_SRC" -path '*/objs/ngx_stream_original_dst_module.so' | head -n 1)" \
  /usr/local/openresty/nginx/modules/ngx_stream_original_dst_module.so
ln -sf /usr/local/openresty/nginx/sbin/nginx /usr/sbin/nginx

# IP forwarding for the transparent proxy.
echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-proxy.conf

# Persistent PREROUTING redirect (workload's :443 -> OpenResty :8443).
cat > /etc/sysconfig/iptables << 'EOF'
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8443
COMMIT
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
COMMIT
EOF
chmod 600 /etc/sysconfig/iptables

sed "s|__DNS_RESOLVERS__|$DNS_RESOLVERS_FOR_NGINX|g" \
  "${ASSET_ROOT}/nginx/conf/nginx.conf.template" \
  > /etc/nginx/nginx.conf
chmod 0644 /etc/nginx/nginx.conf

install -m 0644 "${ASSET_ROOT}/nginx/lua/check_sni.lua" /etc/nginx/lua/check_sni.lua
install -m 0644 "${ASSET_ROOT}/nginx/lua/debug_log_by_lua.lua" /etc/nginx/lua/debug_log_by_lua.lua
install -m 0755 "${ASSET_ROOT}/scripts/refresh-sni-allowlist.sh" /usr/local/sbin/refresh-sni-allowlist.sh
install -m 0644 "${ASSET_ROOT}/systemd/refresh-sni-allowlist.service" /etc/systemd/system/refresh-sni-allowlist.service
install -m 0644 "${ASSET_ROOT}/systemd/refresh-sni-allowlist.timer" /etc/systemd/system/refresh-sni-allowlist.timer
install -m 0644 "${ASSET_ROOT}/systemd/nginx.service" /etc/systemd/system/nginx.service
install -m 0644 "${ASSET_ROOT}/cloudwatch/amazon-cloudwatch-agent.json" \
  /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

# Persist runtime env that the service exports to the OpenResty master process.
cat > /etc/sysconfig/aws-firewall-proxy-runtime << EOF
DNS_RESOLVERS=$DNS_RESOLVERS
DNS_QUERIES_PER_SNI=$DNS_QUERIES_PER_SNI
ENFORCE=1
SPIKE_DEBUG=0
EOF
chmod 0644 /etc/sysconfig/aws-firewall-proxy-runtime

# Seed an empty allowlist snippet so nginx -t passes before the first SSM fetch.
# The default map entry denies all SNIs until refresh-sni-allowlist.service runs.
cat > /etc/nginx/conf.d/sni_allowlist.conf << 'EOF'
# Populated by /usr/local/sbin/refresh-sni-allowlist.sh from SSM Parameter Store.
map $spike_sni $sni_allowed {
    hostnames;
    default 0;
}
EOF

systemctl daemon-reload

# Validate now so a broken AMI fails the Packer build.
log_step "Validating nginx configuration"
nginx -t

log_step "Enabling services"
systemctl enable iptables
systemctl enable nginx
systemctl enable refresh-sni-allowlist.timer
systemctl enable amazon-cloudwatch-agent

run_quiet "Cleaning package manager caches" /var/log/proxy-dnf-clean.log dnf clean all
rm -rf \
  /var/cache/dnf \
  /tmp/openresty.tgz \
  "$OPENRESTY_SRC" \
  /tmp/assets

log_step "Proxy AMI provisioning complete"
