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

# --- Start the gateway if not already running ---
if ! pgrep -f "openclaw.*gateway" > /dev/null 2>&1; then
  TOKEN_FILE="/home/claude/.claude/remote/.session_ingress_token"
  if [ -f "$TOKEN_FILE" ]; then
    export ANTHROPIC_OAUTH_TOKEN=$(cat "$TOKEN_FILE")
  fi
  nohup node "$CLAUDE_PROJECT_DIR/dist/index.js" gateway > /tmp/openclaw-gateway.log 2>&1 &
  echo "[session-start] OpenClaw Gateway started (PID $!)" >&2
fi

exit 0
