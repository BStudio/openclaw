#!/usr/bin/env bash
#
# Start Session Keep-Alive Service
#
# Starts the session keep-alive service in the background to prevent
# active sessions from timing out.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_FILE="/tmp/session-keep-alive.log"
PID_FILE="/tmp/session-keep-alive.pid"

# Check if already running
if [ -f "$PID_FILE" ]; then
  OLD_PID="$(cat "$PID_FILE")"
  if kill -0 "$OLD_PID" 2>/dev/null; then
    echo "✓ Session keep-alive already running (PID: $OLD_PID)"
    echo "  Log: $LOG_FILE"
    exit 0
  fi
  # Stale PID file, remove it
  rm -f "$PID_FILE"
fi

echo "🚀 Starting session keep-alive service..."

# Start the keep-alive service in the background
nohup node --import tsx "$SCRIPT_DIR/session-keep-alive.ts" \
  --interval=60 \
  --activity-threshold=10 \
  > "$LOG_FILE" 2>&1 &

PID=$!
echo "$PID" > "$PID_FILE"

# Wait a moment to check if it started successfully
sleep 1

if kill -0 "$PID" 2>/dev/null; then
  echo "✅ Session keep-alive started successfully"
  echo "   PID: $PID"
  echo "   Log: $LOG_FILE"
  echo ""
  echo "📊 Status:"
  tail -5 "$LOG_FILE" 2>/dev/null || echo "   (no output yet)"
  echo ""
  echo "💡 To view logs:"
  echo "   tail -f $LOG_FILE"
  echo ""
  echo "🛑 To stop:"
  echo "   kill $PID"
else
  echo "❌ Failed to start session keep-alive"
  [ -f "$LOG_FILE" ] && cat "$LOG_FILE"
  rm -f "$PID_FILE"
  exit 1
fi
