#!/bin/bash
set -euo pipefail

LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')]"

# Открываем порт 80 если ufw активен, и закрываем его при любом выходе
UFW_OPENED=0
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    echo "$LOG_PREFIX Opening port 80 for certificate renewal..."
    ufw allow 80/tcp
    UFW_OPENED=1
fi

cleanup() {
    if [[ "$UFW_OPENED" -eq 1 ]]; then
        echo "$LOG_PREFIX Closing port 80..."
        ufw delete allow 80/tcp || true
    fi
}
trap cleanup EXIT

echo "$LOG_PREFIX Renewing certificate for {{DOMAIN}}..."

{{ACME_HOME}}/acme.sh --renew \
    --domain "{{DOMAIN}}" \
    --standalone \
    --httpport 80

{{ACME_HOME}}/acme.sh --install-cert \
    --domain "{{DOMAIN}}" \
    --cert-file      "{{CERT_DIR}}/cert.pem" \
    --key-file       "{{CERT_DIR}}/key.pem" \
    --fullchain-file "{{CERT_DIR}}/fullchain.pem" \
    --reloadcmd      "systemctl restart xray"

echo "$LOG_PREFIX Certificate renewed successfully."
