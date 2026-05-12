#!/bin/sh
set -e

# Flush existing rules to ensure idempotency on container restart
iptables -t nat -F PREROUTING
iptables -t nat -F OUTPUT

# Redirect all inbound TCP:443 traffic (from workload EC2) to nginx on port 8443.
# Note: AWS Security Groups are evaluated before iptables, so the SG must allow
# TCP 443 inbound (not 8443) from the workload subnet.
iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8443

# Loop prevention: nginx's own outbound connections to upstream servers on port 443
# must NOT be redirected back to 8443. Match by the nginx process UID.
NGINX_UID=$(id -u nginx)
iptables -t nat -A OUTPUT -p tcp --dport 443 -m owner --uid-owner "$NGINX_UID" -j RETURN

exec nginx -g 'daemon off;'
