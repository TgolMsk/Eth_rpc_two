#!/usr/bin/env bash
#
# Backup script for Ethereum node data
# Recommended: run via cron weekly for config, daily for critical state
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

BACKUP_DIR="${BACKUP_DIR:-/data/backups/ethereum}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RETENTION_DAYS="${RETENTION_DAYS:-7}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

mkdir -p "$BACKUP_DIR"

# ─── 1. Backup project config ────────────────────────────────
log "Backing up project configuration..."
CONFIG_BACKUP="$BACKUP_DIR/config_$TIMESTAMP.tar.gz"
tar czf "$CONFIG_BACKUP" \
    -C "$PROJECT_DIR" \
    .env \
    docker-compose.yml \
    nginx/ \
    monitoring/ \
    jwt/ \
    scripts/ \
    systemd/ \
    2>/dev/null || true
log "Config backup: $CONFIG_BACKUP"

# ─── 2. Export Geth node key (critical for peer identity) ────
GETH_DATA="${GETH_DATA_DIR:-/data/ethereum/geth}"
NODEKEY="$GETH_DATA/geth/nodekey"
if [[ -f "$NODEKEY" ]]; then
    log "Backing up Geth nodekey..."
    cp "$NODEKEY" "$BACKUP_DIR/nodekey_$TIMESTAMP"
    chmod 600 "$BACKUP_DIR/nodekey_$TIMESTAMP"
fi

# ─── 3. Export Grafana dashboards ─────────────────────────────
if docker ps --format '{{.Names}}' | grep -q eth-grafana; then
    log "Exporting Grafana dashboards..."
    GRAFANA_BACKUP="$BACKUP_DIR/grafana_$TIMESTAMP"
    mkdir -p "$GRAFANA_BACKUP"
    docker cp eth-grafana:/var/lib/grafana/grafana.db "$GRAFANA_BACKUP/" 2>/dev/null || true
fi

# ─── 4. Cleanup old backups ──────────────────────────────────
log "Cleaning backups older than $RETENTION_DAYS days..."
find "$BACKUP_DIR" -type f -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true
find "$BACKUP_DIR" -type d -empty -delete 2>/dev/null || true

# ─── Summary ─────────────────────────────────────────────────
BACKUP_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
log "Backup complete. Total backup size: $BACKUP_SIZE"
log "Backup directory: $BACKUP_DIR"
