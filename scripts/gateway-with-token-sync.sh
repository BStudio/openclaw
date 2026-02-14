#!/usr/bin/env bash
# OpenClaw Gateway wrapper with automatic token syncing
# This script syncs tokens before starting the gateway and periodically while running

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENCLAW_ROOT="$SCRIPT_DIR/.."

# Sync tokens before starting
echo "🔄 Syncing agent tokens before gateway start..."
bash "$SCRIPT_DIR/sync-agent-tokens.sh" || echo "⚠️  Token sync failed (continuing anyway)"

# Start token sync background process (detached from this shell)
nohup bash -c "
  while true; do
    sleep 120  # Sync every 2 minutes
    bash '$SCRIPT_DIR/sync-agent-tokens.sh' 2>&1 | while IFS= read -r line; do
      echo \"[token-sync] \$line\"
    done
  done
" >> /tmp/openclaw-token-sync.log 2>&1 &
SYNC_PID=$!

# Disown the background process so it survives when this script exits
disown "$SYNC_PID"

echo "✅ Token sync background process started (PID: $SYNC_PID)"
echo "   Logs: /tmp/openclaw-token-sync.log"
echo ""

# Start the gateway (no cleanup needed - sync process is detached)
echo "🚀 Starting OpenClaw gateway..."
cd "$OPENCLAW_ROOT"
exec node scripts/run-node.mjs gateway "$@"
