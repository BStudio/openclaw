#!/bin/bash
# C3-PO Bridge Setup
# Run this at the start of a new Claude Code session to set up the
# OpenClaw <-> Claude Code conversation bridge for C3-PO.
#
# Usage:  bash scripts/c3po-bridge-setup.sh
# Then:   Use >> prefix to talk to C3-PO through OpenClaw

set -e

IPC_DIR="/tmp/openclaw-bridge"
mkdir -p "$IPC_DIR"

# Create IPC files
echo '[]' > "$IPC_DIR/inbox.json"
echo '[]' > "$IPC_DIR/outbox.json"
echo '[]' > "$IPC_DIR/conversation.json"

# Create inject helper script
cat > "$IPC_DIR/inject.sh" << 'SCRIPT'
#!/bin/bash
# Usage: ./inject.sh "assistant message text"
set -e
IPC_DIR="/tmp/openclaw-bridge"
CONV="$IPC_DIR/conversation.json"
INBOX="$IPC_DIR/inbox.json"
OUTBOX="$IPC_DIR/outbox.json"
MSG="$1"
REQ_ID="inject-$(date +%s)"

echo '[]' > "$OUTBOX"

python3 -c "
import json, sys
msg = sys.argv[1]
req = [{'requestId': '$REQ_ID', 'method': 'chat.inject', 'params': {'sessionKey': 'agent:dev:main', 'message': msg}}]
with open('$INBOX', 'w') as f:
    json.dump(req, f)
" "$MSG"

sleep 2

python3 -c "
import json, sys
data = json.load(open('$OUTBOX'))
for item in data:
    if item.get('requestId') == '$REQ_ID':
        r = item['response']
        if r.get('ok'):
            print('OK:' + r['payload']['messageId'])
        else:
            print('ERR:' + r.get('error',{}).get('message','unknown'))
            sys.exit(1)
"

python3 -c "
import json, sys
conv = json.load(open('$CONV'))
conv.append({'role': 'assistant', 'text': sys.argv[1]})
with open('$CONV', 'w') as f:
    json.dump(conv, f)
" "$MSG"
SCRIPT

chmod +x "$IPC_DIR/inject.sh"

echo ""
echo "=== C3-PO Bridge Ready ==="
echo ""
echo "IPC dir:      $IPC_DIR"
echo "Conversation: $IPC_DIR/conversation.json"
echo "Inject:       $IPC_DIR/inject.sh"
echo ""
echo "Tell Claude Code:"
echo "  >> message    — routes to C3-PO via OpenClaw"
echo "  >>> message   — same but uses Opus for heavy thinking"
echo "  no prefix     — normal chat with Opus"
echo ""
