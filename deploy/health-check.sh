#!/usr/bin/env bash
# Health check cron — alerts to Feishu webhook if lark-bot-ws is down
# Install: crontab -e → */30 * * * * /home/deploy/services/lark-bot/deploy/health-check.sh
set -euo pipefail

WEBHOOK_ID="${FEISHU_WEBHOOK_HEALTH:-}"
SERVICE="lark-bot-ws"

if [ -z "$WEBHOOK_ID" ]; then
    # Read from .env if not set
    ENV_FILE="/home/deploy/services/lark-bot/.env"
    if [ -f "$ENV_FILE" ]; then
        WEBHOOK_ID=$(grep -oP 'FEISHU_WEBHOOK_HEALTH=\K.*' "$ENV_FILE" 2>/dev/null || true)
    fi
fi

if systemctl is-active --quiet "$SERVICE"; then
    exit 0
fi

# Service is down — attempt restart
sudo systemctl restart "$SERVICE"
sleep 5

if systemctl is-active --quiet "$SERVICE"; then
    STATUS="auto-restarted"
else
    STATUS="DOWN (restart failed)"
fi

# Alert via Feishu webhook
if [ -n "$WEBHOOK_ID" ]; then
    HOSTNAME=$(hostname)
    curl -s -X POST \
        "https://open.feishu.cn/open-apis/bot/v2/hook/$WEBHOOK_ID" \
        -H "Content-Type: application/json" \
        -d "{\"msg_type\":\"text\",\"content\":{\"text\":\"[$HOSTNAME] $SERVICE: $STATUS\"}}" \
        >/dev/null 2>&1
fi
