#!/usr/bin/env bash
#
# CLI health check script — useful for cron alerts or manual diagnostics
#
set -euo pipefail

RPC_URL="${RPC_URL:-http://localhost}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-http://localhost:8080}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; }

EXIT_CODE=0

echo "═══════════════════════════════════════════════"
echo "  Ethereum RPC Service — Health Check"
echo "  $(date)"
echo "═══════════════════════════════════════════════"
echo ""

# ─── 1. Docker containers ────────────────────────────────────
echo "▸ Container Status"
for svc in eth-geth eth-lighthouse eth-nginx eth-healthcheck; do
    STATUS=$(docker inspect -f '{{.State.Status}}' "$svc" 2>/dev/null || echo "not found")
    if [[ "$STATUS" == "running" ]]; then
        ok "$svc: running"
    else
        fail "$svc: $STATUS"
        EXIT_CODE=1
    fi
done
echo ""

# ─── 2. RPC connectivity ─────────────────────────────────────
echo "▸ RPC Endpoint"
RPC_RESP=$(curl -s -w "\n%{http_code}" -X POST "$RPC_URL" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    --connect-timeout 5 --max-time 10 2>/dev/null || echo -e "\n000")

HTTP_CODE=$(echo "$RPC_RESP" | tail -1)
BODY=$(echo "$RPC_RESP" | head -1)

if [[ "$HTTP_CODE" == "200" ]]; then
    BLOCK_HEX=$(echo "$BODY" | jq -r '.result // empty' 2>/dev/null)
    if [[ -n "$BLOCK_HEX" ]]; then
        BLOCK_NUM=$((16#${BLOCK_HEX#0x}))
        ok "RPC responding — latest block: $BLOCK_NUM"
    else
        warn "RPC returned 200 but no block number"
    fi
else
    fail "RPC unreachable (HTTP $HTTP_CODE)"
    EXIT_CODE=1
fi
echo ""

# ─── 3. Sync status ──────────────────────────────────────────
echo "▸ Sync Status"
SYNC_RESP=$(curl -s -X POST "$RPC_URL" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' \
    --connect-timeout 5 --max-time 10 2>/dev/null || echo "")

if [[ -n "$SYNC_RESP" ]]; then
    SYNCING=$(echo "$SYNC_RESP" | jq -r '.result' 2>/dev/null)
    if [[ "$SYNCING" == "false" ]]; then
        ok "Execution client: fully synced"
    else
        CURRENT=$(echo "$SYNC_RESP" | jq -r '.result.currentBlock // empty' 2>/dev/null)
        HIGHEST=$(echo "$SYNC_RESP" | jq -r '.result.highestBlock // empty' 2>/dev/null)
        if [[ -n "$CURRENT" && -n "$HIGHEST" ]]; then
            CUR_DEC=$((16#${CURRENT#0x}))
            HIGH_DEC=$((16#${HIGHEST#0x}))
            PCT=$(( CUR_DEC * 100 / HIGH_DEC ))
            warn "Syncing: $CUR_DEC / $HIGH_DEC ($PCT%)"
        else
            warn "Syncing (details unavailable)"
        fi
    fi
fi
echo ""

# ─── 4. Peer count ───────────────────────────────────────────
echo "▸ Network"
PEER_RESP=$(curl -s -X POST "$RPC_URL" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' \
    --connect-timeout 5 --max-time 10 2>/dev/null || echo "")

if [[ -n "$PEER_RESP" ]]; then
    PEER_HEX=$(echo "$PEER_RESP" | jq -r '.result // empty' 2>/dev/null)
    if [[ -n "$PEER_HEX" ]]; then
        PEERS=$((16#${PEER_HEX#0x}))
        if (( PEERS >= 10 )); then
            ok "Peers: $PEERS"
        elif (( PEERS > 0 )); then
            warn "Peers: $PEERS (low peer count)"
        else
            fail "Peers: 0"
            EXIT_CODE=1
        fi
    fi
fi
echo ""

# ─── 5. Health check service ─────────────────────────────────
echo "▸ Health Check Service"
HC_RESP=$(curl -s -w "\n%{http_code}" "$HEALTHCHECK_URL/health" \
    --connect-timeout 5 --max-time 10 2>/dev/null || echo -e "\n000")

HC_CODE=$(echo "$HC_RESP" | tail -1)
HC_BODY=$(echo "$HC_RESP" | head -1)

if [[ "$HC_CODE" == "200" ]]; then
    HC_STATUS=$(echo "$HC_BODY" | jq -r '.status // empty' 2>/dev/null)
    ok "Health service: $HC_STATUS"
elif [[ "$HC_CODE" == "503" ]]; then
    warn "Health service reports degraded/down"
else
    fail "Health service unreachable"
fi
echo ""

# ─── 6. Disk usage ───────────────────────────────────────────
echo "▸ Disk Usage"
for DIR in "/data/ethereum/geth" "/data/ethereum/lighthouse"; do
    if [[ -d "$DIR" ]]; then
        USAGE=$(du -sh "$DIR" 2>/dev/null | awk '{print $1}')
        ok "$DIR: $USAGE"
    fi
done

ROOT_PCT=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
DATA_PCT=$(df /data 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%' || echo "$ROOT_PCT")
if (( DATA_PCT > 90 )); then
    fail "Data partition: ${DATA_PCT}% used — CRITICAL"
    EXIT_CODE=1
elif (( DATA_PCT > 80 )); then
    warn "Data partition: ${DATA_PCT}% used"
else
    ok "Data partition: ${DATA_PCT}% used"
fi
echo ""

echo "═══════════════════════════════════════════════"
if [[ $EXIT_CODE -eq 0 ]]; then
    echo -e "  Overall: ${GREEN}HEALTHY${NC}"
else
    echo -e "  Overall: ${RED}ISSUES DETECTED${NC}"
fi
echo "═══════════════════════════════════════════════"

exit $EXIT_CODE
