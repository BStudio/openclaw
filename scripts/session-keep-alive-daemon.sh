#!/usr/bin/env bash
#
# DEPRECATED: Use the bundled session-lifecycle hook instead.
# See src/hooks/bundled/session-lifecycle/handler.ts
# The in-process hook posts to the session ingress API and monitors the
# command queue directly — this script is kept for reference only.
#
# Session Keep-Alive Daemon
#
# Periodically updates session timestamps to prevent idle timeout.
# Runs indefinitely until stopped.
#
# Usage:
#   ./scripts/session-keep-alive-daemon.sh [interval_seconds]
#
# Default interval: 60 seconds
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERVAL="${1:-60}"
LOG_FILE="/tmp/session-keep-alive.log"

echo "[$(date '+%H:%M:%S')] 🚀 Session keep-alive daemon started" | tee -a "$LOG_FILE"
echo "[$(date '+%H:%M:%S')] ⏱️  Update interval: ${INTERVAL}s" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Cleanup handler
cleanup() {
  echo "" | tee -a "$LOG_FILE"
  echo "[$(date '+%H:%M:%S')] 👋 Session keep-alive daemon stopped" | tee -a "$LOG_FILE"
  exit 0
}

trap cleanup SIGINT SIGTERM EXIT

# Main loop
while true; do
  if bash "$SCRIPT_DIR/update-session-timestamps.sh" 2>&1 | tee -a "$LOG_FILE"; then
    :  # Success
  else
    echo "[$(date '+%H:%M:%S')] ⚠️  Failed to update sessions" | tee -a "$LOG_FILE"
  fi

  sleep "$INTERVAL"
done
