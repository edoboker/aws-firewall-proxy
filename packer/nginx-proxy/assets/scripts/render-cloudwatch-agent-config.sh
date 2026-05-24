#!/bin/bash
set -euo pipefail

CONFIG_FILE=/etc/sysconfig/aws-firewall-proxy-runtime
TEMPLATE_FILE=/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json.template
OUTPUT_FILE=/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
DEFAULT_INTERVAL=20

if [[ -r "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

INTERVAL="${METRICS_PUBLISH_INTERVAL_SECONDS:-$DEFAULT_INTERVAL}"
if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || (( INTERVAL < 10 || INTERVAL > 900 )); then
    echo "invalid METRICS_PUBLISH_INTERVAL_SECONDS=$INTERVAL" >&2
    exit 1
fi

sed "s/__METRICS_PUBLISH_INTERVAL_SECONDS__/${INTERVAL}/g" "$TEMPLATE_FILE" > "$OUTPUT_FILE"
