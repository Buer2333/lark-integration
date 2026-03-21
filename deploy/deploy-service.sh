#!/usr/bin/env bash
# Deploy lark-bot to VPS — run from local machine
# Usage: deploy/deploy-service.sh <VPS_IP> [SSH_PORT]
# Note: This script lives in lark-integration but deploys lark-bot code.
set -euo pipefail

VPS_IP="${1:?Usage: $0 <VPS_IP> [SSH_PORT]}"
SSH_PORT="${2:-22222}"
DEPLOY_USER="deploy"
REMOTE_DIR="/home/$DEPLOY_USER/services/lark-bot"
# lark-bot source is a sibling repo
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_DIR="${LARK_BOT_DIR:-$(cd "$SCRIPT_DIR/../../lark-bot" && pwd)}"

SSH_CMD="ssh -p $SSH_PORT $DEPLOY_USER@$VPS_IP"
SCP_CMD="scp -P $SSH_PORT"

echo "=== Deploying lark-bot to $DEPLOY_USER@$VPS_IP:$SSH_PORT ==="

echo "[1/5] Syncing code..."
rsync -az --delete \
    --exclude '.venv' \
    --exclude '__pycache__' \
    --exclude '.env' \
    --exclude '*.pyc' \
    --exclude '.git' \
    -e "ssh -p $SSH_PORT" \
    "$LOCAL_DIR/" "$DEPLOY_USER@$VPS_IP:$REMOTE_DIR/"

echo "[2/5] Setting up venv & deps..."
$SSH_CMD "cd $REMOTE_DIR && python3 -m venv .venv && .venv/bin/pip install -q --upgrade pip && .venv/bin/pip install -q -r requirements.txt && .venv/bin/pip install -q yt-dlp curl_cffi"

echo "[3/5] Verifying imports..."
$SSH_CMD "cd $REMOTE_DIR && .venv/bin/python -c 'import lark_oapi; from core.bootstrap import init; print(\"OK: imports work\")'"

echo "[4/5] Installing systemd service..."
$SSH_CMD "sudo cp $REMOTE_DIR/deploy/lark-bot-ws.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable lark-bot-ws"

echo "[5/5] Restarting service..."
$SSH_CMD "sudo systemctl restart lark-bot-ws"

echo ""
echo "=== Deploy complete ==="
echo "Check status: $SSH_CMD 'sudo systemctl status lark-bot-ws'"
echo "View logs:    $SSH_CMD 'sudo journalctl -u lark-bot-ws -f'"
