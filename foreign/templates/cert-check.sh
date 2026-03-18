#!/bin/bash
set -euo pipefail

CERT_FILE="{{CERT_DIR}}/fullchain.pem"
RENEW_SCRIPT="{{CERT_RENEW_SCRIPT}}"
THRESHOLD={{CERT_RENEW_DAYS}}

EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_FILE" | sed 's/notAfter=//')
DAYS_LEFT=$(( ( $(date -d "$EXPIRY" +%s) - $(date +%s) ) / 86400 ))

echo "[$(date)] Days until expiry: $DAYS_LEFT (threshold: $THRESHOLD)"

if [ "$DAYS_LEFT" -le "$THRESHOLD" ]; then
    "$RENEW_SCRIPT"
else
    echo "[$(date)] Renewal not needed yet."
fi
