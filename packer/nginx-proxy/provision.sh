#!/bin/bash
# AMI provisioning: install nginx + stream module, iptables-services, awscli,
# bake in the proxy config and the SSM allowlist-refresh systemd unit.
set -euxo pipefail

# Wait for cloud-init so dnf locks are released
cloud-init status --wait || true

# Pinned packages — bump intentionally, not at boot. awscli v2 is shipped as
# `awscli-2` in AL2023 repos.
dnf install -y \
  nginx \
  nginx-mod-stream \
  iptables-services \
  awscli-2

# IP forwarding for the transparent proxy
echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-proxy.conf

# Persistent PREROUTING redirect (workload's :443 → nginx :8443). iptables-services
# loads /etc/sysconfig/iptables at boot.
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

# nginx config + allowlist conf.d directory
install -m 0644 /tmp/nginx.conf /etc/nginx/nginx.conf
mkdir -p /etc/nginx/conf.d
# Seed an empty allowlist snippet so nginx -t passes before first SSM fetch.
# The default map entry (0) denies all SNIs until the refresh script runs.
cat > /etc/nginx/conf.d/sni_allowlist.conf << 'EOF'
# Populated by /usr/local/sbin/refresh-sni-allowlist.sh from SSM Parameter Store.
map $ssl_preread_server_name $sni_allowed {
    hostnames;
    default 0;
}
EOF

# SSM allowlist refresher
install -m 0755 /tmp/refresh-sni-allowlist.sh /usr/local/sbin/refresh-sni-allowlist.sh
install -m 0644 /tmp/refresh-sni-allowlist.service /etc/systemd/system/refresh-sni-allowlist.service
install -m 0644 /tmp/refresh-sni-allowlist.timer   /etc/systemd/system/refresh-sni-allowlist.timer

# Validate nginx config now so a broken AMI fails the Packer build.
nginx -t

systemctl enable iptables
systemctl enable nginx
systemctl enable refresh-sni-allowlist.timer

# Clean up dnf cache to shrink the AMI
dnf clean all
rm -rf /var/cache/dnf /tmp/nginx.conf /tmp/refresh-sni-allowlist.*
