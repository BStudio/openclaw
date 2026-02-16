#!/usr/bin/env bash
# convo-watcher.sh — Monitors the OpenClaw Telegram session JSONL and
# exports conversation messages to a dated JSON file every 30 seconds.
#
# Usage: ./convo-watcher.sh [interval_seconds]
# Output: ./conversations/convo-YYYY-MM-DD.json

set -euo pipefail

SESSIONS_DIR="/root/.openclaw/agents/main/sessions"
OUTPUT_DIR="/root/.openclaw/workspace/conversations"
INTERVAL="${1:-30}"

mkdir -p "$OUTPUT_DIR"

extract_messages() {
  local jsonl_file="$1"
  local date_str="$2"
  local out_file="${OUTPUT_DIR}/convo-${date_str}.json"

  python3 -c "
import json, sys

messages = []
with open('$jsonl_file', 'r') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue

        if entry.get('type') != 'message':
            continue

        msg = entry.get('message', {})
        role = msg.get('role', '')
        timestamp = entry.get('timestamp', '')

        # Extract text content
        content = msg.get('content', '')
        if isinstance(content, list):
            texts = [c.get('text', '') for c in content if c.get('type') == 'text']
            content = '\n'.join(texts)

        # Skip system messages and empty content
        if role == 'system' or not content.strip():
            continue

        # Clean up metadata prefix from user messages
        text = content

        messages.append({
            'role': role,
            'timestamp': timestamp,
            'text': text
        })

output = {
    'exported_at': '$date_str',
    'session_file': '$jsonl_file',
    'message_count': len(messages),
    'messages': messages
}

with open('$out_file', 'w') as f:
    json.dump(output, f, indent=2, ensure_ascii=False)

print(f'Exported {len(messages)} messages -> $out_file')
" 2>&1
}

echo "🔍 Convo watcher started (interval: ${INTERVAL}s)"
echo "   Output dir: $OUTPUT_DIR"

last_size=""

while true; do
  # Find the most recent session JSONL
  jsonl_file=$(ls -t "$SESSIONS_DIR"/*.jsonl 2>/dev/null | head -1)

  if [[ -z "$jsonl_file" ]]; then
    echo "No session files found, waiting..."
    sleep "$INTERVAL"
    continue
  fi

  current_size=$(stat -c%s "$jsonl_file" 2>/dev/null || echo "0")
  date_str=$(date -u +%Y-%m-%d)

  if [[ "$current_size" != "$last_size" ]]; then
    extract_messages "$jsonl_file" "$date_str"
    last_size="$current_size"
  fi

  sleep "$INTERVAL"
done
