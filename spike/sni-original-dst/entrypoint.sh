#!/usr/bin/env bash
set -euo pipefail

# Redirect anything hitting 443 inside this container's network namespace
# to nginx on 8443. This is what makes SO_ORIGINAL_DST hold the *original*
# (pre-NAT) destination address.
#
# Container must be started with --cap-add=NET_ADMIN.

DNS_RESOLVER="${DNS_RESOLVER:-1.1.1.1}"
export DNS_RESOLVER
echo "[entrypoint] rendering nginx.conf with DNS_RESOLVER=$DNS_RESOLVER"
sed "s|__DNS_RESOLVER__|$DNS_RESOLVER|g" \
    /usr/local/openresty/nginx/conf/nginx.conf.template \
    > /usr/local/openresty/nginx/conf/nginx.conf

# Identify the nginx worker UID so we can exclude its upstream connections
# from the OUTPUT REDIRECT (otherwise nginx redirects to itself in a loop).
NGINX_USER="$(
  awk '/^user / { gsub(/;/, "", $2); print $2; found=1; exit } END { if (!found) print "nobody" }' \
    /usr/local/openresty/nginx/conf/nginx.conf
)"
NGINX_UID="$(id -u "$NGINX_USER" 2>/dev/null || echo 65534)"
echo "[entrypoint] excluding uid=$NGINX_UID ($NGINX_USER) from OUTPUT REDIRECT"

iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8443
iptables -t nat -A OUTPUT     -p tcp --dport 443 ! -d 127.0.0.0/8 \
         -m owner ! --uid-owner "$NGINX_UID" -j REDIRECT --to-port 8443

echo "[entrypoint] iptables REDIRECT 443 -> 8443 installed"
iptables -t nat -L PREROUTING -n
iptables -t nat -L OUTPUT     -n

exec /usr/local/openresty/bin/openresty -g 'daemon off;'
