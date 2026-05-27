#!/bin/bash
set -euo pipefail

TEMPLATE_FILE=/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json.template
OUTPUT_FILE=/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

install -m 0644 "$TEMPLATE_FILE" "$OUTPUT_FILE"
