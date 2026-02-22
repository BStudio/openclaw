#!/bin/bash
set -euo pipefail

# Only run in remote (Claude Code on the web) environments
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "$CLAUDE_PROJECT_DIR"

# --- Set ANTHROPIC_OAUTH_TOKEN early so it's available to all processes ---
TOKEN_FILE="/home/claude/.claude/remote/.session_ingress_token"
if [ -f "$TOKEN_FILE" ]; then
  export ANTHROPIC_OAUTH_TOKEN="$(cat "$TOKEN_FILE")"
  echo "[session-start] ANTHROPIC_OAUTH_TOKEN set early (${#ANTHROPIC_OAUTH_TOKEN} chars)" >&2
fi

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

# --- Ensure internal hooks are enabled for Claude Code sessions ---
if [ -f "$OPENCLAW_STATE/openclaw.json" ]; then
  node -e "
    const fs = require('fs');
    const p = '$OPENCLAW_STATE/openclaw.json';
    const cfg = JSON.parse(fs.readFileSync(p, 'utf-8'));
    if (!cfg.hooks) cfg.hooks = {};
    if (!cfg.hooks.internal) cfg.hooks.internal = {};
    if (cfg.hooks.internal.enabled !== true) {
      cfg.hooks.internal.enabled = true;
      fs.writeFileSync(p, JSON.stringify(cfg, null, 2) + '\n');
      process.stderr.write('[session-start] Enabled hooks.internal for Claude Code session\n');
    }
  " 2>&1 >&2 || true
fi

# --- Reverse-sync: restore workspace files from git repo ---
# The repo (.openclaw-workspace/) is the persistent store across sessions.
# On a fresh container the bootstrap step above only creates template files,
# which may be older/incomplete compared to the repo. Overwrite the live
# workspace with ALL repo files so the persisted state always wins.
REPO_WORKSPACE="$CLAUDE_PROJECT_DIR/.openclaw-workspace"
LIVE_WORKSPACE="$OPENCLAW_STATE/workspace"
if [ -d "$REPO_WORKSPACE" ]; then
  mkdir -p "$LIVE_WORKSPACE"
  while IFS= read -r src_file; do
    rel="${src_file#$REPO_WORKSPACE/}"
    dest="$LIVE_WORKSPACE/$rel"
    mkdir -p "$(dirname "$dest")"
    cp -f "$src_file" "$dest"
  done < <(find "$REPO_WORKSPACE" -type f 2>/dev/null)
  echo "[session-start] Reverse-synced repo → live workspace" >&2
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

# --- Run auth diagnostic before starting gateway ---
node "$CLAUDE_PROJECT_DIR/.claude/hooks/auth-diagnostic.mjs" 2>&1 | tee /tmp/openclaw-auth-diag.log >&2 || true

# --- (Re)start the gateway with the current session's token ---
# Write a session epoch so the OLD gateway (in an isolated session) can
# detect that a newer session exists and shut itself down gracefully.
# This solves cross-session shutdown when pgrep/pkill can't see other
# session's processes.
EPOCH_FILE="/tmp/openclaw-session-epoch"
date +%s%N > "$EPOCH_FILE"
echo "[session-start] Wrote session epoch to $EPOCH_FILE" >&2

# Kill any same-session gateway (may exist on resume hooks).
if pgrep -f "openclaw.*gateway" > /dev/null 2>&1; then
  echo "[session-start] Killing same-session gateway…" >&2
  pkill -f "openclaw.*gateway" || true
  for _i in 1 2 3; do
    pgrep -f "openclaw.*gateway" > /dev/null 2>&1 || break
    sleep 1
  done
  pkill -9 -f "openclaw.*gateway" 2>/dev/null || true
fi

# Brief pause for old gateway (cross-session) to notice the epoch change
# and close its Telegram connection gracefully.
sleep 3

nohup node "$CLAUDE_PROJECT_DIR/dist/index.js" gateway > /tmp/openclaw-gateway.log 2>&1 &
echo "[session-start] OpenClaw Gateway started (PID $!)" >&2

# --- Ensure clean working tree before Claude starts ---
# The watcher handles .openclaw-workspace/ commits. If the reverse-sync above
# modified the live workspace, the forward-sync (watcher) would dirty the repo
# copy. Do one synchronous sync+commit now so Claude sees a clean tree.
BRANCH="$(git -C "$CLAUDE_PROJECT_DIR" branch --show-current 2>/dev/null || echo "")"
if [ -n "$BRANCH" ]; then
  # Forward-sync: live workspace → repo (same as watcher does)
  if [ -d "$LIVE_WORKSPACE" ] && [ -d "$REPO_WORKSPACE" ]; then
    find "$LIVE_WORKSPACE" -type f 2>/dev/null | while IFS= read -r f; do
      rel="${f#$LIVE_WORKSPACE/}"
      dest="$REPO_WORKSPACE/$rel"
      mkdir -p "$(dirname "$dest")"
      cp -f "$f" "$dest"
    done
  fi

  # Stage and commit workspace changes (additions/modifications only)
  cd "$CLAUDE_PROJECT_DIR"
  git add --ignore-removal .openclaw-workspace/ 2>/dev/null || true
  if ! git diff --cached --quiet 2>/dev/null; then
    git commit -m "auto: sync workspace on session start" 2>&1 >&2 || true
    git push -u origin "$BRANCH" 2>&1 >&2 || true
    echo "[session-start] Committed workspace sync" >&2
  fi

  # Discard any remaining workspace deletions so Claude sees a clean tree
  git checkout -- .openclaw-workspace/ 2>/dev/null || true

  # Mark all tracked workspace files as skip-worktree so git never reports
  # them as changed. This is the definitive fix: Claude cannot see them as
  # dirty, so it cannot commit deletions or modifications.
  git ls-files .openclaw-workspace/ 2>/dev/null | while IFS= read -r f; do
    git update-index --skip-worktree "$f" 2>/dev/null || true
  done
  echo "[session-start] Marked .openclaw-workspace/ as skip-worktree" >&2
fi

# --- Start auto-commit watcher (background) ---
AUTO_COMMIT_PID_FILE="/tmp/openclaw-auto-commit.pid"
if [ -f "$AUTO_COMMIT_PID_FILE" ] && kill -0 "$(cat "$AUTO_COMMIT_PID_FILE")" 2>/dev/null; then
  echo "[session-start] Auto-commit watcher already running (PID $(cat "$AUTO_COMMIT_PID_FILE"))" >&2
else
  if [ -n "$BRANCH" ]; then
    nohup bash "$CLAUDE_PROJECT_DIR/scripts/auto-commit-watcher.sh" -q -b "$BRANCH" > /tmp/openclaw-auto-commit.log 2>&1 &
    echo "$!" > "$AUTO_COMMIT_PID_FILE"
    echo "[session-start] Auto-commit watcher started (PID $!, branch: $BRANCH)" >&2
  else
    echo "[session-start] Skipping auto-commit watcher (no branch detected)" >&2
  fi
fi

exit 0
