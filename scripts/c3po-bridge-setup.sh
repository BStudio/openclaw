#!/bin/bash
# Multi-bot Bridge Setup
# Reads scripts/bots.json and creates per-bot IPC directories under /tmp/openclaw-bridge/.
# Each bot gets its own conversation.json, inbox.json, outbox.json, and inject.sh.
#
# Usage:  bash scripts/c3po-bridge-setup.sh
# Bots:   Define in scripts/bots.json

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOTS_FILE="$SCRIPT_DIR/bots.json"
BRIDGE_ROOT="/tmp/openclaw-bridge"

mkdir -p "$BRIDGE_ROOT"

if [ ! -f "$BOTS_FILE" ]; then
  echo "ERROR: $BOTS_FILE not found" >&2
  exit 1
fi

# Parse bots.json and set up each bot
BOT_COUNT=$(python3 -c "import json; print(len(json.load(open('$BOTS_FILE'))))")

for i in $(seq 0 $((BOT_COUNT - 1))); do
  BOT_ID=$(python3 -c "import json; print(json.load(open('$BOTS_FILE'))[$i]['id'])")
  BOT_PREFIX=$(python3 -c "import json; print(json.load(open('$BOTS_FILE'))[$i]['prefix'])")
  BOT_MODEL=$(python3 -c "import json; print(json.load(open('$BOTS_FILE'))[$i]['model'])")
  BOT_SESSION_KEY=$(python3 -c "import json; print(json.load(open('$BOTS_FILE'))[$i].get('sessionKey', 'agent:dev:main'))")

  IPC_DIR="$BRIDGE_ROOT/$BOT_ID"
  mkdir -p "$IPC_DIR"

  # Create IPC files (preserve conversation history if it exists)
  echo '[]' > "$IPC_DIR/inbox.json"
  echo '[]' > "$IPC_DIR/outbox.json"
  [ -f "$IPC_DIR/conversation.json" ] || echo '[]' > "$IPC_DIR/conversation.json"

  # Create per-bot inject helper
  cat > "$IPC_DIR/inject.sh" << SCRIPT
#!/bin/bash
# Usage: ./inject.sh "assistant message text"
set -e
IPC_DIR="$IPC_DIR"
CONV="\$IPC_DIR/conversation.json"
INBOX="$BRIDGE_ROOT/inbox.json"
OUTBOX="$BRIDGE_ROOT/outbox.json"
MSG="\$1"
REQ_ID="inject-$BOT_ID-\$(date +%s)"

echo '[]' > "\$OUTBOX"

python3 -c "
import json, sys
msg = sys.argv[1]
req = [{'requestId': '\$REQ_ID', 'method': 'chat.inject', 'params': {'sessionKey': '$BOT_SESSION_KEY', 'message': msg}}]
with open('\$INBOX', 'w') as f:
    json.dump(req, f)
" "\$MSG"

sleep 2

python3 -c "
import json, sys
data = json.load(open('\$OUTBOX'))
for item in data:
    if item.get('requestId') == '\$REQ_ID':
        r = item['response']
        if r.get('ok'):
            print('OK:' + r['payload']['messageId'])
        else:
            print('ERR:' + r.get('error',{}).get('message','unknown'))
            sys.exit(1)
"

python3 -c "
import json, sys
conv = json.load(open('\$CONV'))
conv.append({'role': 'assistant', 'text': sys.argv[1]})
with open('\$CONV', 'w') as f:
    json.dump(conv, f)
" "\$MSG"
SCRIPT

  chmod +x "$IPC_DIR/inject.sh"

  echo "  [$BOT_ID] prefix=$BOT_PREFIX model=$BOT_MODEL dir=$IPC_DIR"
done

# Also keep root-level IPC files for the shared bridge.mjs WebSocket
echo '[]' > "$BRIDGE_ROOT/inbox.json"
echo '[]' > "$BRIDGE_ROOT/outbox.json"

echo ""
echo "=== Multi-Bot Bridge Ready ==="
echo ""
echo "Bridge root:  $BRIDGE_ROOT"
echo "Bots config:  $BOTS_FILE"
echo "Bots online:  $BOT_COUNT"
echo ""
