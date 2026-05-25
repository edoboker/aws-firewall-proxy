#!/bin/bash
# AMI provisioning:
#   * build and install OpenResty with stream preread support
#   * compile and install the original-dst stream C module
#   * install the Lua SNI/original-dst guard
#   * bake in the AppConfig-backed runtime policy sync and CloudWatch config
set -euo pipefail

ASSET_ROOT=/tmp/assets
OPENRESTY_VERSION=1.27.1.1
OPENRESTY_URL="https://openresty.org/download/openresty-${OPENRESTY_VERSION}.tar.gz"
OPENRESTY_SRC="/usr/local/src/openresty-${OPENRESTY_VERSION}"

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
  jq \
  tar \
  findutils \
  diffutils \
  iptables-services \
  amazon-cloudwatch-agent

if ! id nginx >/dev/null 2>&1; then
  log_step "Creating nginx service account"
  groupadd --system nginx
  useradd --system --gid nginx --home-dir /var/cache/nginx --shell /sbin/nologin nginx
fi

mkdir -p \
  /etc/nginx/conf.d \
  /etc/nginx/lua \
  /etc/systemd/system/aws-appconfig-agent.service.d \
  /usr/local/openresty/nginx/modules \
  /usr/local/src \
  /var/lib/aws-firewall-proxy \
  /var/log/aws \
  /var/log/aws-firewall-proxy \
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

# Persistent PREROUTING redirects:
#   * workload :443 -> OpenResty :8443 for TLS/SNI enforcement
#   * workload :80  -> OpenResty :8081 for experimental HTTP Host enforcement
cat > /etc/sysconfig/iptables << 'EOF'
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8443
-A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8081
COMMIT
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
COMMIT
EOF
chmod 600 /etc/sysconfig/iptables

cp "${ASSET_ROOT}/nginx/conf/nginx.conf.template" /etc/nginx/nginx.conf
chmod 0644 /etc/nginx/nginx.conf

run_quiet "Installing AWS AppConfig Agent" /var/log/aws-appconfig-agent-install.log \
  dnf install -y -q https://s3.amazonaws.com/aws-appconfig-downloads/aws-appconfig-agent/linux/x86_64/latest/aws-appconfig-agent.rpm

install -m 0644 "${ASSET_ROOT}/nginx/lua/check_sni.lua" /etc/nginx/lua/check_sni.lua
install -m 0644 "${ASSET_ROOT}/nginx/lua/check_http_host.lua" /etc/nginx/lua/check_http_host.lua
install -m 0644 "${ASSET_ROOT}/nginx/lua/init_metrics.lua" /etc/nginx/lua/init_metrics.lua
install -m 0644 "${ASSET_ROOT}/nginx/lua/log_metrics.lua" /etc/nginx/lua/log_metrics.lua
install -m 0644 "${ASSET_ROOT}/nginx/lua/proxy_metrics.lua" /etc/nginx/lua/proxy_metrics.lua
install -m 0644 "${ASSET_ROOT}/nginx/lua/debug_log_by_lua.lua" /etc/nginx/lua/debug_log_by_lua.lua
install -m 0644 "${ASSET_ROOT}/nginx/lua/proxy_runtime_policy.lua" /etc/nginx/lua/proxy_runtime_policy.lua
install -m 0755 "${ASSET_ROOT}/scripts/refresh-proxy-runtime-policy.sh" /usr/local/sbin/refresh-proxy-runtime-policy.sh
install -m 0755 "${ASSET_ROOT}/scripts/render-cloudwatch-agent-config.sh" /usr/local/sbin/render-cloudwatch-agent-config.sh
install -m 0644 "${ASSET_ROOT}/systemd/refresh-proxy-runtime-policy.service" /etc/systemd/system/refresh-proxy-runtime-policy.service
install -m 0644 "${ASSET_ROOT}/systemd/refresh-proxy-runtime-policy.timer" /etc/systemd/system/refresh-proxy-runtime-policy.timer
install -m 0644 "${ASSET_ROOT}/systemd/aws-appconfig-agent.override.conf" /etc/systemd/system/aws-appconfig-agent.service.d/override.conf
install -m 0644 "${ASSET_ROOT}/systemd/nginx.service" /etc/systemd/system/nginx.service
install -m 0644 "${ASSET_ROOT}/systemd/render-cloudwatch-agent-config.service" /etc/systemd/system/render-cloudwatch-agent-config.service
install -m 0644 "${ASSET_ROOT}/cloudwatch/amazon-cloudwatch-agent.json" \
  /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json.template

# Persist the stable local-only nginx env. Mutable traffic policy comes from
# AppConfig and is rendered to disk by refresh-proxy-runtime-policy.sh.
cat > /etc/sysconfig/aws-firewall-proxy-runtime << EOF
PROXY_DEBUG=0
METRICS_PUBLISH_INTERVAL_SECONDS=20
EOF
chmod 0644 /etc/sysconfig/aws-firewall-proxy-runtime

# Seed empty runtime config files so nginx -t passes in the AMI build. The
# first real policy render must happen on instance boot before nginx starts.
cat > /etc/nginx/conf.d/sni_allowlist.conf << 'EOF'
# Populated by /usr/local/sbin/refresh-proxy-runtime-policy.sh.
map $client_sni $sni_allowed {
    hostnames;
    default 0;
}
EOF

cat > /etc/nginx/conf.d/proxy_resolver.conf << 'EOF'
# Populated by /usr/local/sbin/refresh-proxy-runtime-policy.sh.
resolver 169.254.169.253 valid=10s ipv6=off;
resolver_timeout 5s;
EOF

cat > /etc/sysconfig/aws-appconfig-agent << 'EOF'
SERVICE_REGION=
PREFETCH_LIST=
EOF
chmod 0644 /etc/sysconfig/aws-appconfig-agent

cat > /etc/sysconfig/proxy-runtime-sync << 'EOF'
APPCONFIG_APPLICATION=
APPCONFIG_ENVIRONMENT=
APPCONFIG_CONFIGURATION_PROFILE=
APPCONFIG_AGENT_HOST=localhost
APPCONFIG_AGENT_PORT=2772
EOF
chmod 0644 /etc/sysconfig/proxy-runtime-sync

systemctl daemon-reload

# Validate now so a broken AMI fails the Packer build.
log_step "Validating nginx configuration"
nginx -t
log_step "Rendering default CloudWatch agent configuration"
/usr/local/sbin/render-cloudwatch-agent-config.sh

log_step "Enabling services"
systemctl enable iptables
systemctl enable aws-appconfig-agent
systemctl enable nginx
systemctl enable refresh-proxy-runtime-policy.timer
systemctl enable render-cloudwatch-agent-config.service
systemctl enable amazon-cloudwatch-agent

run_quiet "Cleaning package manager caches" /var/log/proxy-dnf-clean.log dnf clean all
rm -rf \
  /var/cache/dnf \
  /tmp/openresty.tgz \
  "$OPENRESTY_SRC" \
  /tmp/assets

log_step "Proxy AMI provisioning complete"
