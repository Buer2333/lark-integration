#!/usr/bin/env bash
# VPS initial setup script — run as root on fresh Ubuntu 22.04/24.04
# Usage: ssh root@<VPS_IP> 'bash -s' < deploy/setup-server.sh
set -euo pipefail

SSH_PORT=22222
DEPLOY_USER=deploy

echo "=== [1/6] Create deploy user ==="
if ! id "$DEPLOY_USER" &>/dev/null; then
    adduser --disabled-password --gecos "" "$DEPLOY_USER"
    mkdir -p /home/$DEPLOY_USER/.ssh
    # Copy root's authorized_keys to deploy user
    cp /root/.ssh/authorized_keys /home/$DEPLOY_USER/.ssh/authorized_keys
    chown -R $DEPLOY_USER:$DEPLOY_USER /home/$DEPLOY_USER/.ssh
    chmod 700 /home/$DEPLOY_USER/.ssh
    chmod 600 /home/$DEPLOY_USER/.ssh/authorized_keys
    echo "$DEPLOY_USER user created"
else
    echo "$DEPLOY_USER user already exists"
fi

echo "=== [2/6] SSH hardening ==="
sed -i "s/^#\?Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
systemctl restart sshd
echo "SSH: port=$SSH_PORT, root login disabled, password auth disabled"

echo "=== [3/6] UFW firewall ==="
apt-get update -qq
apt-get install -y -qq ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow $SSH_PORT/tcp comment "SSH"
# v2ray port — change if using a different port
ufw allow 443/tcp comment "v2ray/xray"
ufw --force enable
ufw status
echo "UFW enabled"

echo "=== [4/6] fail2ban ==="
apt-get install -y -qq fail2ban
cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = $SSH_PORT
maxretry = 5
bantime = 3600
findtime = 600
EOF
systemctl enable --now fail2ban
echo "fail2ban configured"

echo "=== [5/6] Install runtime dependencies ==="
apt-get install -y -qq python3 python3-venv python3-pip ffmpeg git curl
echo "Runtime deps installed"

echo "=== [6/7] Journal rotation ==="
mkdir -p /etc/systemd/journald.conf.d
cp deploy/journald-larkbot.conf /etc/systemd/journald.conf.d/ 2>/dev/null || true
systemctl restart systemd-journald 2>/dev/null || true
echo "Journal capped at 500M / 30 days"

echo "=== [7/7] Sudoers for deploy user ==="
cat > /etc/sudoers.d/deploy-lark-bot <<EOF
deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart lark-bot-ws
deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop lark-bot-ws
deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl start lark-bot-ws
deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl status lark-bot-ws
deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl daemon-reload
deploy ALL=(ALL) NOPASSWD: /usr/bin/journalctl -u lark-bot-*
deploy ALL=(ALL) NOPASSWD: /usr/bin/journalctl -u lark-bot-ws*
EOF
chmod 440 /etc/sudoers.d/deploy-lark-bot
echo "Sudoers configured"

echo ""
echo "=== Setup complete ==="
echo "IMPORTANT: Test SSH with new port before closing this session:"
echo "  ssh -p $SSH_PORT deploy@<VPS_IP>"
echo ""
echo "Next steps:"
echo "  1. Test SSH as deploy user (keep this root session open!)"
echo "  2. Run deploy/deploy-service.sh from local machine"
