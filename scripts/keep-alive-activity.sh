#!/usr/bin/env bash
# DEPRECATED: Use the bundled session-lifecycle hook instead.
# See src/hooks/bundled/session-lifecycle/handler.ts
# The in-process hook posts to the session ingress API and monitors the
# command queue directly — this bash script is kept for reference only.
#
# Activity-based keep-alive monitor for OpenClaw gateway
# Keeps session alive while agents are working
# Exits after 5 minutes of idle time

IDLE_TIMEOUT=300  # 5 minutes in seconds
CHECK_INTERVAL=10  # Check every 10 seconds
ACTIVITY_LOG="/tmp/openclaw-activity.log"

# Initialize
LAST_ACTIVITY=$(date +%s)
IDLE_START=0
IS_IDLE=false

echo "[keep-alive] 🚀 Activity-based monitor started at $(date)"
echo "[keep-alive] 💤 Will exit after ${IDLE_TIMEOUT}s of idle time"
echo "[keep-alive] 🔍 Checking every ${CHECK_INTERVAL}s"
echo ""

# Function to detect activity
detect_activity() {
  local activity_found=false

  # Check 1: Gateway process running
  local gateway_pid=$(pgrep -f "openclaw-gateway" | head -1)
  if [ -z "$gateway_pid" ]; then
    echo "[keep-alive] ❌ Gateway NOT running - exiting"
    exit 1
  fi

  # Check 2: Recent HTTP connections (last 30 seconds)
  local recent_connections=$(ss -tn state established '( dport = :9339 or sport = :9339 )' 2>/dev/null | wc -l)
  if [ "$recent_connections" -gt 1 ]; then
    activity_found=true
    echo "[keep-alive] 🌐 Active connections: $((recent_connections - 1))"
  fi

  # Check 3: Gateway process CPU usage (>1% means active)
  local cpu_usage=$(ps -p "$gateway_pid" -o %cpu= 2>/dev/null | awk '{print int($1)}')
  if [ "$cpu_usage" -gt 1 ]; then
    activity_found=true
    echo "[keep-alive] ⚡ Gateway CPU: ${cpu_usage}%"
  fi

  # Check 4: Log file changes (if exists)
  if [ -f "/tmp/openclaw-gateway.log" ]; then
    local log_mtime=$(stat -c %Y "/tmp/openclaw-gateway.log" 2>/dev/null || echo 0)
    local now=$(date +%s)
    local log_age=$((now - log_mtime))

    if [ "$log_age" -lt 30 ]; then
      activity_found=true
      echo "[keep-alive] 📝 Recent log activity (${log_age}s ago)"
    fi
  fi

  # Check 5: Child processes (tool execution)
  local child_count=$(pgrep -P "$gateway_pid" 2>/dev/null | wc -l)
  if [ "$child_count" -gt 0 ]; then
    activity_found=true
    echo "[keep-alive] 🔧 Active child processes: $child_count"
  fi

  if $activity_found; then
    return 0  # Activity detected
  else
    return 1  # Idle
  fi
}

# Main monitoring loop
while true; do
  CURRENT_TIME=$(date +%s)

  # Detect current activity
  if detect_activity; then
    # Activity detected
    LAST_ACTIVITY=$CURRENT_TIME

    if $IS_IDLE; then
      echo "[keep-alive] 🎯 Activity resumed! Resetting idle timer"
      IS_IDLE=false
      IDLE_START=0
    fi

    echo "[keep-alive] ✅ Gateway active (PID: $(pgrep -f "openclaw-gateway" | head -1)) | $(date '+%H:%M:%S')"

  else
    # No activity detected
    if ! $IS_IDLE; then
      # Just became idle
      IS_IDLE=true
      IDLE_START=$CURRENT_TIME
      echo ""
      echo "[keep-alive] 💤 No activity detected - starting idle countdown"
    fi

    # Calculate idle duration
    IDLE_DURATION=$((CURRENT_TIME - IDLE_START))
    IDLE_REMAINING=$((IDLE_TIMEOUT - IDLE_DURATION))

    if [ $IDLE_DURATION -ge $IDLE_TIMEOUT ]; then
      echo ""
      echo "[keep-alive] ⏰ Idle timeout reached (${IDLE_DURATION}s)"
      echo "[keep-alive] ✨ Shutting down gracefully at $(date)"
      break
    fi

    echo "[keep-alive] 💤 Idle: ${IDLE_DURATION}s / ${IDLE_TIMEOUT}s (${IDLE_REMAINING}s remaining) | $(date '+%H:%M:%S')"
  fi

  echo ""
  sleep $CHECK_INTERVAL
done

# Calculate total runtime
TOTAL_RUNTIME=$((CURRENT_TIME - $(date +%s -r "$0" 2>/dev/null || date +%s)))
echo "[keep-alive] 📊 Total session time: ${TOTAL_RUNTIME}s"
echo "[keep-alive] 👋 Monitor exiting at $(date)"
