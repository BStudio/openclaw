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
  # 1. Set ANTHROPIC_OAUTH_TOKEN globally so pi-ai's getEnvApiKey() always
  #    picks it up as a Bearer token (env fallback, works for every process).
  export ANTHROPIC_OAUTH_TOKEN="$SESSION_TOKEN"
  echo "export ANTHROPIC_OAUTH_TOKEN='$SESSION_TOKEN'" >> "$HOME/.bashrc"
  echo "[session-start] Set ANTHROPIC_OAUTH_TOKEN (${#SESSION_TOKEN} chars)" >&2

  # 2. Write auth-profiles.json in the agent directory so the embedded runner
  #    resolves the token with type "token" → mode "token" → Bearer auth.
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

  # 3. Write pi-coding-agent's auth.json directly so AuthStorage.getApiKey()
  #    returns the token without relying on the OpenClaw profile resolution chain.
  AUTH_JSON="$AGENT_DIR/auth.json"
  EXPIRES_MS=$(( $(date +%s) * 1000 + 86400000 ))
  cat > "$AUTH_JSON" <<AUTHJSONEOF
{
  "anthropic": {
    "type": "oauth",
    "access": "$SESSION_TOKEN",
    "refresh": "",
    "expires": $EXPIRES_MS
  }
}
AUTHJSONEOF
  chmod 600 "$AUTH_JSON"
  echo "[session-start] Wrote auth.json for pi-coding-agent" >&2
fi

# --- Start the gateway if not already running ---
if ! pgrep -f "openclaw.*gateway" > /dev/null 2>&1; then
  nohup node "$CLAUDE_PROJECT_DIR/dist/index.js" gateway > /tmp/openclaw-gateway.log 2>&1 &
  echo "[session-start] OpenClaw Gateway started (PID $!)" >&2
fi

exit 0
