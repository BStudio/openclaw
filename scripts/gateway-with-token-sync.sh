#!/usr/bin/env bash
# OpenClaw Gateway wrapper with automatic token syncing
# This script syncs tokens before starting the gateway and periodically while running

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENCLAW_ROOT="$SCRIPT_DIR/.."

# Sync tokens before starting
echo "🔄 Syncing agent tokens before gateway start..."
bash "$SCRIPT_DIR/sync-agent-tokens.sh" || echo "⚠️  Token sync failed (continuing anyway)"

# Start token sync background process
(
  while true; do
    sleep 120  # Sync every 2 minutes
    bash "$SCRIPT_DIR/sync-agent-tokens.sh" 2>&1 | while IFS= read -r line; do
      echo "[token-sync] $line"
    done
  done
) &
SYNC_PID=$!

echo "✅ Token sync background process started (PID: $SYNC_PID)"
echo ""

# Cleanup function
cleanup() {
  echo ""
  echo "🛑 Stopping token sync background process..."
  kill "$SYNC_PID" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# Start the gateway
echo "🚀 Starting OpenClaw gateway..."
cd "$OPENCLAW_ROOT"
exec node scripts/run-node.mjs gateway "$@"
