#!/usr/bin/env bash
#
# Session Keep-Alive Monitor
#
# Keeps active sessions alive by periodically updating their updatedAt timestamp.
# This prevents idle timeout for sessions that are currently being used.
#
# Usage:
#   ./scripts/keep-alive-sessions.sh [interval_seconds]
#
# Default interval: 60 seconds (1 minute)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_FILE="/tmp/keep-alive-sessions.log"
ACTIVITY_THRESHOLD_MINUTES=10  # Only keep alive sessions active in last 10 minutes
INTERVAL="${1:-60}"  # Default: check every 60 seconds

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log() {
  local level="$1"
  shift
  local timestamp
  timestamp="$(date '+%H:%M:%S')"
  echo -e "${timestamp} [$level] $*" | tee -a "$LOG_FILE"
}

log_info() {
  log "INFO" "$@"
}

log_success() {
  log "✓" "${GREEN}$*${NC}"
}

log_error() {
  log "ERROR" "${RED}$*${NC}"
}

# Get list of active sessions (updated within threshold)
get_active_sessions() {
  local now
  now="$(date +%s)000"  # Convert to milliseconds
  local threshold_ms=$((ACTIVITY_THRESHOLD_MINUTES * 60 * 1000))
  local cutoff=$((now - threshold_ms))

  # Use openclaw sessions command to get active sessions
  # Filter to sessions updated within the activity threshold
  openclaw sessions --json 2>/dev/null | \
    jq -r --argjson cutoff "$cutoff" \
      '.[] | select(.updatedAt >= $cutoff) | .sessionKey' 2>/dev/null || true
}

# Update session timestamp to keep it alive
update_session_timestamp() {
  local session_key="$1"
  local store_path="$HOME/.openclaw/agents/default/sessions/sessions.json"

  # Use Node.js to atomically update the session timestamp
  node --input-type=module --eval "
    import fs from 'fs';
    import path from 'path';

    const storePath = '$store_path';
    const sessionKey = '$session_key';
    const now = Date.now();

    try {
      if (!fs.existsSync(storePath)) {
        process.exit(0);
      }

      const data = JSON.parse(fs.readFileSync(storePath, 'utf-8'));

      if (data[sessionKey]) {
        data[sessionKey].updatedAt = now;
        fs.writeFileSync(storePath, JSON.stringify(data, null, 2));
        console.log('updated');
      }
    } catch (err) {
      process.stderr.write('error: ' + err.message + '\n');
      process.exit(1);
    }
  " 2>/dev/null
}

# Main monitoring loop
monitor_sessions() {
  log_info "${BLUE}Starting session keep-alive monitor${NC}"
  log_info "Activity threshold: ${ACTIVITY_THRESHOLD_MINUTES} minutes"
  log_info "Check interval: ${INTERVAL} seconds"
  log_info "Log file: $LOG_FILE"
  echo ""

  local iteration=0

  while true; do
    iteration=$((iteration + 1))

    # Get active sessions
    local sessions
    sessions="$(get_active_sessions)"

    if [ -z "$sessions" ]; then
      log_info "No active sessions found"
    else
      local count=0
      while IFS= read -r session_key; do
        [ -z "$session_key" ] && continue

        local result
        result="$(update_session_timestamp "$session_key")"

        if [ "$result" = "updated" ]; then
          count=$((count + 1))
          log_success "Kept alive: $session_key"
        fi
      done <<< "$sessions"

      if [ "$count" -gt 0 ]; then
        log_success "Updated $count session(s)"
      fi
    fi

    # Sleep for the specified interval
    sleep "$INTERVAL"
  done
}

# Handle cleanup on exit
cleanup() {
  log_info "Session keep-alive monitor stopped"
  exit 0
}

trap cleanup SIGINT SIGTERM EXIT

# Start monitoring
monitor_sessions
