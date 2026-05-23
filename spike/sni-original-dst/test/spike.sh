#!/usr/bin/env bash
#
# spike.sh — runs the two probes inside the spike container.
#
# Expects to be exec'd *inside* the running spike container, e.g.:
#
#   docker run --rm -it --cap-add=NET_ADMIN \
#       --name sni-spike -d sni-spike
#   docker exec -it sni-spike bash /test/spike.sh
#
# (Mount this script in or COPY it into the image — see README.)
#
# What it does:
#   1. Picks a real IP for example.com (allowed FQDN here is just example.com).
#   2. Picks an unrelated IP (cloudflare.com's) to use as the spoof dst.
#   3. Connection A — curl example.com forced to its real IP via --resolve.
#      Expected: TLS handshake completes; log shows spike_decision="allow".
#   4. Connection B — curl example.com forced to cloudflare.com's IP.
#      Expected: TLS handshake is dropped; log shows spike_decision="mismatch".
#
# We don't assert on curl's HTTP status (the upstream may not serve content),
# only on the TLS handshake outcome and the spike's own log line.

set -uo pipefail

SNI="${SNI:-www.google.com}"

# RFC5737 TEST-NET-1: not routed, guaranteed not in any real DNS answer.
# Using it as the spoof IP makes the mismatch case deterministic regardless
# of which Cloudflare-anycast IP example.com happens to return this second.
SPOOF_IP="${SPOOF_IP:-192.0.2.1}"

echo "[probe] SNI=$SNI spoof_ip=$SPOOF_IP"

echo
echo "===== Waiting for OpenResty readiness ====="
until curl -fsS http://127.0.0.1:8080/ready >/dev/null 2>&1; do
    sleep 0.2
done

echo
echo "===== Probe A: happy path (no --resolve, container DNS picks the dst) ====="
# By not pinning the IP, curl asks the container's resolver right before connect,
# and check_sni.lua resolves the same SNI via its configured resolver moments
# later. Even with anycast rotation, the resolved sets nearly always overlap on
# the IP curl picked. Expected log line: spike_decision="allow".
curl --max-time 8 -sv "https://${SNI}/" -o /dev/null \
    2>&1 | grep -E "Connected to|SSL connection|TLS|Server certificate|HTTP|reset|closed|failure" || true

echo
echo "===== Probe B: spoof (SNI=$SNI forced to $SPOOF_IP) ====="
# 192.0.2.1 cannot appear in any real resolution of $SNI, so this is an
# unambiguous mismatch. Expected log line: spike_decision="mismatch".
curl --max-time 8 -sv --resolve "${SNI}:443:${SPOOF_IP}" "https://${SNI}/" -o /dev/null \
    2>&1 | grep -E "Connected to|SSL connection|TLS|Server certificate|HTTP|reset|closed|failure" || true

echo
echo "===== Done. Check 'docker logs sni-spike' for spike_decision lines. ====="
