#!/usr/bin/env bash
# Keep-alive monitor for OpenClaw gateway
# Runs for 30 minutes, checking status every 2 minutes

DURATION=1800  # 30 minutes in seconds
CHECK_INTERVAL=120  # 2 minutes
START_TIME=$(date +%s)
END_TIME=$((START_TIME + DURATION))

echo "[keep-alive] Monitor started at $(date)"
echo "[keep-alive] Will run until $(date -d @${END_TIME})"
echo "[keep-alive] Checking every ${CHECK_INTERVAL} seconds"
echo ""

while [ $(date +%s) -lt $END_TIME ]; do
  CURRENT_TIME=$(date +%s)
  ELAPSED=$((CURRENT_TIME - START_TIME))
  REMAINING=$((END_TIME - CURRENT_TIME))

  echo "[keep-alive] ⏱️  Elapsed: ${ELAPSED}s | Remaining: ${REMAINING}s | $(date '+%H:%M:%S')"

  # Check gateway status
  GATEWAY_PID=$(pgrep -f "openclaw-gateway" | head -1)
  if [ -n "$GATEWAY_PID" ]; then
    echo "[keep-alive] ✅ Gateway running (PID: $GATEWAY_PID)"
  else
    echo "[keep-alive] ❌ Gateway NOT running!"
  fi

  # Check token sync status
  SYNC_PID=$(pgrep -f "sync-agent-tokens" | head -1)
  if [ -n "$SYNC_PID" ]; then
    echo "[keep-alive] ✅ Token sync running (PID: $SYNC_PID)"
  else
    echo "[keep-alive] ⚠️  Token sync NOT running"
  fi

  echo ""

  # Sleep for check interval or until end time
  if [ $REMAINING -lt $CHECK_INTERVAL ]; then
    sleep $REMAINING
    break
  else
    sleep $CHECK_INTERVAL
  fi
done

echo "[keep-alive] ✨ Monitor completed at $(date)"
echo "[keep-alive] Total runtime: $(($(date +%s) - START_TIME)) seconds"
