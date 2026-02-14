#!/usr/bin/env bash
# Sync session-ingress token to all agent auth files
# This ensures all agents use the same fresh token

set -euo pipefail

OPENCLAW_ROOT="${OPENCLAW_ROOT:-$HOME/.openclaw}"
SESSION_TOKEN_FILE="${OPENCLAW_SESSION_TOKEN_FILE:-/home/claude/.claude/remote/.session_ingress_token}"
AGENTS_DIR="$OPENCLAW_ROOT/agents"

# Check if session token file exists
if [[ ! -f "$SESSION_TOKEN_FILE" ]]; then
  echo "⚠️  Session token file not found: $SESSION_TOKEN_FILE"
  exit 1
fi

# Read the fresh token
FRESH_TOKEN=$(cat "$SESSION_TOKEN_FILE" | tr -d '\n' | tr -d ' ')

if [[ -z "$FRESH_TOKEN" ]]; then
  echo "⚠️  Session token file is empty"
  exit 1
fi

# Extract expiry from JWT
TOKEN_PAYLOAD=$(echo "$FRESH_TOKEN" | cut -d'.' -f2)
TOKEN_EXP=$(echo "$TOKEN_PAYLOAD" | base64 -d 2>/dev/null | jq -r '.exp // empty')
TOKEN_IAT=$(echo "$TOKEN_PAYLOAD" | base64 -d 2>/dev/null | jq -r '.iat // empty')

if [[ -z "$TOKEN_EXP" ]]; then
  echo "⚠️  Could not parse token expiry"
  exit 1
fi

# Convert to milliseconds for auth.json format
TOKEN_EXP_MS=$((TOKEN_EXP * 1000))

echo "📡 Syncing session-ingress token to all agents..."
echo "   Token IAT: $TOKEN_IAT"
echo "   Token EXP: $TOKEN_EXP"
echo ""

# Update all agent auth files
UPDATED_COUNT=0
SKIPPED_COUNT=0

for agent_dir in "$AGENTS_DIR"/*; do
  if [[ ! -d "$agent_dir/agent" ]]; then
    continue
  fi

  AGENT_ID=$(basename "$agent_dir")
  AUTH_JSON="$agent_dir/agent/auth.json"
  AUTH_PROFILES_JSON="$agent_dir/agent/auth-profiles.json"

  # Update auth.json
  if [[ -f "$AUTH_JSON" ]]; then
    # Check if current token is different
    CURRENT_TOKEN=$(jq -r '.anthropic.access // empty' "$AUTH_JSON")

    if [[ "$CURRENT_TOKEN" == "$FRESH_TOKEN" ]]; then
      echo "✓ $AGENT_ID: token already up-to-date (auth.json)"
      ((SKIPPED_COUNT++))
    else
      # Update the token and expiry
      jq --arg token "$FRESH_TOKEN" \
         --argjson exp "$TOKEN_EXP_MS" \
         '.anthropic.access = $token | .anthropic.expires = $exp' \
         "$AUTH_JSON" > "$AUTH_JSON.tmp" && mv "$AUTH_JSON.tmp" "$AUTH_JSON"
      echo "✓ $AGENT_ID: updated auth.json"
      ((UPDATED_COUNT++))
    fi
  fi

  # Update auth-profiles.json
  if [[ -f "$AUTH_PROFILES_JSON" ]]; then
    # Check if session-ingress profile exists
    if jq -e '.profiles."session-ingress"' "$AUTH_PROFILES_JSON" > /dev/null 2>&1; then
      CURRENT_TOKEN=$(jq -r '.profiles."session-ingress".token // empty' "$AUTH_PROFILES_JSON")

      if [[ "$CURRENT_TOKEN" != "$FRESH_TOKEN" ]]; then
        # Update the token
        jq --arg token "$FRESH_TOKEN" \
           '.profiles."session-ingress".token = $token |
            del(.usageStats."session-ingress".lastFailureAt)' \
           "$AUTH_PROFILES_JSON" > "$AUTH_PROFILES_JSON.tmp" && \
           mv "$AUTH_PROFILES_JSON.tmp" "$AUTH_PROFILES_JSON"
        echo "✓ $AGENT_ID: updated auth-profiles.json"
      fi
    fi
  fi
done

echo ""
echo "✅ Token sync complete!"
echo "   Updated: $UPDATED_COUNT agents"
echo "   Skipped: $SKIPPED_COUNT agents (already up-to-date)"
