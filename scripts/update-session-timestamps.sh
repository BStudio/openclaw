#!/usr/bin/env bash
#
# Update Session Timestamps
#
# Keeps active sessions alive by updating their updatedAt timestamp.
# This script updates ALL sessions to prevent idle timeout.
#
# Usage:
#   ./scripts/update-session-timestamps.sh [agent_id|all]
#
# If agent_id is "all" or omitted, updates all agents.
#

set -euo pipefail

AGENT_ID="${1:-all}"
OPENCLAW_DIR="$HOME/.openclaw"
TOTAL_UPDATED=0

# Get current timestamp in milliseconds
NOW="$(date +%s)000"

update_agent_sessions() {
  local agent="$1"
  local session_store="$OPENCLAW_DIR/agents/$agent/sessions/sessions.json"

  if [ ! -f "$session_store" ]; then
    return 0
  fi

  # Update all sessions' updatedAt timestamp using jq
  local temp_file=$(mktemp)
  jq --argjson now "$NOW" '
    to_entries |
    map(.value.updatedAt = $now) |
    from_entries
  ' "$session_store" > "$temp_file"

  # Atomic replace
  mv "$temp_file" "$session_store"

  # Count sessions
  local count=$(jq 'length' "$session_store")
  TOTAL_UPDATED=$((TOTAL_UPDATED + count))

  if [ "$count" -gt 0 ]; then
    echo "  ✓ $agent: $count session(s)"
  fi
}

if [ "$AGENT_ID" = "all" ]; then
  # Update all agents
  if [ -d "$OPENCLAW_DIR/agents" ]; then
    for agent_dir in "$OPENCLAW_DIR/agents"/*; do
      if [ -d "$agent_dir" ]; then
        agent="$(basename "$agent_dir")"
        update_agent_sessions "$agent"
      fi
    done
  fi
else
  # Update specific agent
  update_agent_sessions "$AGENT_ID"
fi

if [ "$TOTAL_UPDATED" -gt 0 ]; then
  echo "✅ Updated $TOTAL_UPDATED session(s) total at $(date '+%H:%M:%S')"
else
  echo "ℹ️  No sessions found to update"
fi
