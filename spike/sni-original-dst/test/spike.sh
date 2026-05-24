#!/usr/bin/env bash
#
# spike.sh - runs the two probes inside the spike container.
#
# Expects to be exec'd *inside* the running spike container, e.g.:
#
#   docker run --rm -it --cap-add=NET_ADMIN \
#       --name sni-spike -d sni-spike
#   docker exec -it sni-spike bash /test/spike.sh
#
# (Mount this script in or COPY it into the image - see README.)
#
# What it does:
#   1. Picks a real IP for the SNI host by letting curl use the container's
#      normal DNS path.
#   2. Uses an unrelated IP as the spoof destination.
#   3. Connection A - curl to the real host.
#      Expected: TLS handshake completes; default runtime stays quiet.
#   4. Connection B - curl with SNI forced to the spoof destination.
#      Expected: TLS handshake is dropped; logs show sni_spoofing_detected.
#
# We don't assert on curl's HTTP status (the upstream may not serve content),
# only on the TLS handshake outcome and the spike's own warning log line.

set -uo pipefail

SNI="${SNI:-www.google.com}"

# RFC5737 TEST-NET-1: not routed, guaranteed not in any real DNS answer.
# Using it as the spoof IP makes the mismatch case deterministic.
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
# the IP curl picked. Default runtime does not emit an allow log line.
curl --max-time 8 -sv "https://${SNI}/" -o /dev/null \
    2>&1 | grep -E "Connected to|SSL connection|TLS|Server certificate|HTTP|reset|closed|failure" || true

echo
echo "===== Probe B: spoof (SNI=$SNI forced to $SPOOF_IP) ====="
# 192.0.2.1 cannot appear in any real resolution of $SNI, so this is an
# unambiguous mismatch. Expected log line: event="sni_spoofing_detected".
curl --max-time 8 -sv --resolve "${SNI}:443:${SPOOF_IP}" "https://${SNI}/" -o /dev/null \
    2>&1 | grep -E "Connected to|SSL connection|TLS|Server certificate|HTTP|reset|closed|failure" || true

echo
echo "===== Done. Check 'docker logs sni-spike' for sni_spoofing_detected. ====="
