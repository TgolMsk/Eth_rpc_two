#!/usr/bin/env bash
#
# Initial setup script for Ethereum RPC Service on Ubuntu 24.04 LTS
# Run as root or with sudo
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ─── Pre-flight checks ───────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    err "Please run this script as root (sudo ./setup.sh)"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

log "=== Ethereum RPC Service Setup ==="
log "Project directory: $PROJECT_DIR"

# ─── 1. System updates ───────────────────────────────────────
log "Updating system packages..."
apt-get update -qq
apt-get upgrade -y -qq

# ─── 2. Install dependencies ─────────────────────────────────
log "Installing dependencies..."
apt-get install -y -qq \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common \
    ufw \
    jq \
    htop \
    iotop \
    chrony

# ─── 3. Install Docker ───────────────────────────────────────
if command -v docker &>/dev/null; then
    log "Docker already installed: $(docker --version)"
else
    log "Installing Docker..."
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    log "Docker installed: $(docker --version)"
fi

# ─── 4. Create data directories ──────────────────────────────
DATA_BASE="/data/ethereum"
log "Creating data directories at $DATA_BASE..."
mkdir -p "$DATA_BASE/geth"
mkdir -p "$DATA_BASE/lighthouse"

# ─── 5. Generate JWT secret ──────────────────────────────────
JWT_DIR="$PROJECT_DIR/jwt"
JWT_FILE="$JWT_DIR/jwt.hex"
mkdir -p "$JWT_DIR"

if [[ -f "$JWT_FILE" ]]; then
    log "JWT secret already exists at $JWT_FILE"
else
    log "Generating JWT secret..."
    openssl rand -hex 32 > "$JWT_FILE"
    chmod 600 "$JWT_FILE"
    log "JWT secret generated at $JWT_FILE"
fi

# ─── 6. Create .env from template ────────────────────────────
ENV_FILE="$PROJECT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
    log ".env file already exists, skipping..."
else
    log "Creating .env from template..."
    cp "$PROJECT_DIR/.env.example" "$ENV_FILE"
    warn "Please edit $ENV_FILE to customize your configuration"
fi

# ─── 7. Create SSL directory ─────────────────────────────────
SSL_DIR="$PROJECT_DIR/nginx/ssl"
mkdir -p "$SSL_DIR"
if [[ ! -f "$SSL_DIR/self-signed.crt" ]]; then
    log "Generating self-signed SSL certificate (replace with real cert in production)..."
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$SSL_DIR/self-signed.key" \
        -out "$SSL_DIR/self-signed.crt" \
        -subj "/C=US/ST=State/L=City/O=Org/CN=eth-rpc.local" 2>/dev/null
fi

# ─── 8. System tuning ────────────────────────────────────────
log "Applying system tuning..."
SYSCTL_CONF="/etc/sysctl.d/99-ethereum.conf"
cat > "$SYSCTL_CONF" <<'SYSCTL'
# Network tuning for Ethereum nodes
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 1024 65535
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216

# File descriptors
fs.file-max = 2097152
fs.nr_open = 2097152

# VM tuning
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
SYSCTL
sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1

# Increase open file limits
cat > /etc/security/limits.d/99-ethereum.conf <<'LIMITS'
*    soft    nofile    65536
*    hard    nofile    65536
root soft    nofile    65536
root hard    nofile    65536
LIMITS

# ─── 9. Configure firewall ───────────────────────────────────
log "Configuring UFW firewall..."
ufw --force reset >/dev/null 2>&1
ufw default deny incoming
ufw default allow outgoing

# SSH
ufw allow 22/tcp comment "SSH"

# Ethereum P2P
ufw allow 30303/tcp comment "Geth P2P"
ufw allow 30303/udp comment "Geth P2P"
ufw allow 9000/tcp comment "Lighthouse P2P"
ufw allow 9000/udp comment "Lighthouse P2P"

# RPC (HTTP only, restrict in production)
ufw allow 80/tcp comment "Nginx HTTP"
# ufw allow 443/tcp comment "Nginx HTTPS"  # Uncomment if using HTTPS

# Monitoring (restrict to specific IPs in production)
# ufw allow from <MONITOR_IP> to any port 3000 comment "Grafana"
# ufw allow from <MONITOR_IP> to any port 9090 comment "Prometheus"

ufw --force enable
log "Firewall configured"

# ─── 10. Configure NTP ───────────────────────────────────────
log "Ensuring time synchronization..."
systemctl enable --now chrony
chronyc makestep >/dev/null 2>&1 || true

# ─── 11. Install systemd service ─────────────────────────────
SYSTEMD_SRC="$PROJECT_DIR/systemd/eth-rpc.service"
SYSTEMD_DST="/etc/systemd/system/eth-rpc.service"
if [[ -f "$SYSTEMD_SRC" ]]; then
    log "Installing systemd service..."
    cp "$SYSTEMD_SRC" "$SYSTEMD_DST"
    sed -i "s|__PROJECT_DIR__|$PROJECT_DIR|g" "$SYSTEMD_DST"
    systemctl daemon-reload
    systemctl enable eth-rpc.service
    log "Systemd service installed and enabled"
fi

# ─── Summary ─────────────────────────────────────────────────
echo ""
log "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  1. Edit configuration:   nano $PROJECT_DIR/.env"
echo "  2. Start the service:    cd $PROJECT_DIR && docker compose up -d"
echo "  3. Check status:         docker compose ps"
echo "  4. View logs:            docker compose logs -f geth"
echo "  5. Monitor sync:         curl -s http://localhost/health | jq"
echo ""
warn "Geth mainnet sync requires ~2TB NVMe SSD and takes 6-12 hours (snap sync)"
warn "Lighthouse checkpoint sync takes ~5-15 minutes"
