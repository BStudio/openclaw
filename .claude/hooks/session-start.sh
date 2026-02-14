#!/bin/bash
set -euo pipefail

# Only run in remote (Claude Code on the web) environments
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "$CLAUDE_PROJECT_DIR"

# Install pnpm workspace dependencies (idempotent, uses cache)
pnpm install

# Build the project so CLI, tests, and linter work
pnpm build

# --- Bootstrap OpenClaw state if missing (fresh container) ---
OPENCLAW_STATE="$HOME/.openclaw"
BOOTSTRAP_DIR="$CLAUDE_PROJECT_DIR/.claude/bootstrap"

# Config
if [ ! -f "$OPENCLAW_STATE/openclaw.json" ] && [ -f "$BOOTSTRAP_DIR/openclaw.json" ]; then
  mkdir -p "$OPENCLAW_STATE"
  cp "$BOOTSTRAP_DIR/openclaw.json" "$OPENCLAW_STATE/openclaw.json"
  echo "[session-start] Bootstrapped openclaw.json" >&2
fi

# Agent workspace
if [ ! -d "$OPENCLAW_STATE/workspace" ] && [ -d "$BOOTSTRAP_DIR/workspace" ]; then
  mkdir -p "$OPENCLAW_STATE/workspace/memory"
  cp "$BOOTSTRAP_DIR/workspace/"*.md "$OPENCLAW_STATE/workspace/" 2>/dev/null || true
  echo "[session-start] Bootstrapped agent workspace" >&2
fi

# --- Bootstrap Anthropic auth from session ingress token ---
TOKEN_FILE="/home/claude/.claude/remote/.session_ingress_token"
SESSION_TOKEN=""

if [ -f "$TOKEN_FILE" ]; then
  SESSION_TOKEN=$(cat "$TOKEN_FILE")
  echo "[session-start] Found session ingress token (${#SESSION_TOKEN} chars)" >&2
else
  echo "[session-start] WARNING: No session ingress token at $TOKEN_FILE" >&2
fi

if [ -n "$SESSION_TOKEN" ]; then
  # Write auth-profiles.json in the agent directory so the embedded runner
  # resolves the token with type "token" → mode "token" → Bearer auth.
  AGENT_DIR="$OPENCLAW_STATE/agents/main/agent"
  AUTH_PROFILES="$AGENT_DIR/auth-profiles.json"
  mkdir -p "$AGENT_DIR"
  cat > "$AUTH_PROFILES" <<AUTHEOF
{
  "version": 1,
  "profiles": {
    "session-ingress": {
      "type": "token",
      "provider": "anthropic",
      "token": "$SESSION_TOKEN"
    }
  }
}
AUTHEOF
  chmod 600 "$AUTH_PROFILES"
  echo "[session-start] Wrote auth-profiles.json for Anthropic (token type)" >&2
fi

# --- Start the gateway if not already running ---
if ! pgrep -f "openclaw.*gateway" > /dev/null 2>&1; then
  if [ -n "$SESSION_TOKEN" ]; then
    export ANTHROPIC_OAUTH_TOKEN="$SESSION_TOKEN"
  fi
  nohup node "$CLAUDE_PROJECT_DIR/dist/index.js" gateway > /tmp/openclaw-gateway.log 2>&1 &
  echo "[session-start] OpenClaw Gateway started (PID $!)" >&2
fi

exit 0
