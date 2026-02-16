#!/usr/bin/env bash
#
# Auto-Commit Watcher
#
# Monitors the OpenClaw repo for file changes and automatically
# commits and pushes when modifications are detected.
#
# Usage:
#   ./scripts/auto-commit-watcher.sh [options]
#
# Options:
#   -i, --interval SECONDS   Poll interval (default: 30)
#   -b, --branch BRANCH      Target branch (default: current branch)
#   -d, --dry-run             Show what would be committed without doing it
#   -q, --quiet               Suppress verbose output
#   -h, --help                Show this help
#
# Examples:
#   ./scripts/auto-commit-watcher.sh                     # defaults
#   ./scripts/auto-commit-watcher.sh -i 60               # check every 60s
#   ./scripts/auto-commit-watcher.sh -b claude/my-branch # push to specific branch
#   ./scripts/auto-commit-watcher.sh -d                  # dry run
#

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INTERVAL=30
BRANCH=""
DRY_RUN=false
QUIET=false
LOG_FILE="/tmp/openclaw-auto-commit.log"
MAX_RETRIES=4
PUSH_RETRY_DELAYS=(2 4 8 16)
OPENCLAW_SRC="$HOME/.openclaw/workspace"
OPENCLAW_DEST="$REPO_DIR/.openclaw-workspace"

# ── Parse args ────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--interval) INTERVAL="$2"; shift 2 ;;
    -b|--branch)   BRANCH="$2"; shift 2 ;;
    -d|--dry-run)  DRY_RUN=true; shift ;;
    -q|--quiet)    QUIET=true; shift ;;
    -h|--help)
      sed -n '2,/^$/{ s/^# //; s/^#//; p }' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────
ts() { date '+%H:%M:%S'; }

log() {
  local msg="[$(ts)] $1"
  echo "$msg" | tee -a "$LOG_FILE"
}

log_quiet() {
  if ! $QUIET; then
    log "$1"
  else
    echo "[$(ts)] $1" >> "$LOG_FILE"
  fi
}

# ── Resolve branch ────────────────────────────────────────
cd "$REPO_DIR"

if [ -z "$BRANCH" ]; then
  BRANCH="$(git branch --show-current)"
fi

if [ -z "$BRANCH" ]; then
  log "ERROR: Not on any branch (detached HEAD?). Use -b to specify."
  exit 1
fi

# ── Cleanup handler ───────────────────────────────────────
COMMIT_COUNT=0
START_TIME=$(date +%s)

cleanup() {
  echo ""
  log "Session summary: $COMMIT_COUNT commit(s) pushed in $(($(date +%s) - START_TIME))s"
  log "Auto-commit watcher stopped"
  exit 0
}

trap cleanup SIGINT SIGTERM

# ── Sync ~/.openclaw/workspace/ into repo ────────────────
# Only watches workspace files (SOUL.md, AGENTS.md, MEMORY.md, etc.)
should_exclude() {
  local rel="$1"
  case "$rel" in
    *.bak) return 0 ;;
  esac
  return 1
}

sync_openclaw() {
  [ -d "$OPENCLAW_SRC" ] || return 0
  mkdir -p "$OPENCLAW_DEST"

  # Walk source and copy non-excluded files
  while IFS= read -r src_file; do
    local rel="${src_file#$OPENCLAW_SRC/}"
    should_exclude "$rel" && continue
    local dest="$OPENCLAW_DEST/$rel"
    mkdir -p "$(dirname "$dest")"
    cp -f "$src_file" "$dest"
  done < <(find "$OPENCLAW_SRC" -type f 2>/dev/null)

  # Clean up dest files that no longer exist in source or now excluded
  while IFS= read -r dest_file; do
    local rel="${dest_file#$OPENCLAW_DEST/}"
    if should_exclude "$rel" || [ ! -f "$OPENCLAW_SRC/$rel" ]; then
      rm -f "$dest_file"
    fi
  done < <(find "$OPENCLAW_DEST" -type f 2>/dev/null)

  # Remove empty dirs in dest
  find "$OPENCLAW_DEST" -type d -empty -delete 2>/dev/null || true
}

# ── Push with retry ───────────────────────────────────────
push_with_retry() {
  local attempt=0
  while [ $attempt -lt $MAX_RETRIES ]; do
    if git push -u origin "$BRANCH" 2>&1 | tee -a "$LOG_FILE"; then
      return 0
    fi
    local delay=${PUSH_RETRY_DELAYS[$attempt]}
    attempt=$((attempt + 1))
    log "Push failed (attempt $attempt/$MAX_RETRIES). Retrying in ${delay}s..."
    sleep "$delay"
  done
  log "ERROR: Push failed after $MAX_RETRIES attempts"
  return 1
}

# ── Generate commit message ──────────────────────────────
generate_commit_message() {
  local added modified deleted renamed
  added=$(git diff --cached --name-only --diff-filter=A | wc -l)
  modified=$(git diff --cached --name-only --diff-filter=M | wc -l)
  deleted=$(git diff --cached --name-only --diff-filter=D | wc -l)
  renamed=$(git diff --cached --name-only --diff-filter=R | wc -l)

  local parts=()
  [ "$added" -gt 0 ] && parts+=("${added} added")
  [ "$modified" -gt 0 ] && parts+=("${modified} modified")
  [ "$deleted" -gt 0 ] && parts+=("${deleted} deleted")
  [ "$renamed" -gt 0 ] && parts+=("${renamed} renamed")

  local summary
  summary=$(IFS=', '; echo "${parts[*]}")

  # Show which files changed (up to 5)
  local files
  files=$(git diff --cached --name-only | head -5 | xargs -I{} basename {} | paste -sd ', ')
  local total
  total=$(git diff --cached --name-only | wc -l)

  local file_note="$files"
  if [ "$total" -gt 5 ]; then
    file_note="$files, ... (+$((total - 5)) more)"
  fi

  echo "auto: ${summary} [${file_note}]"
}

# ── Main loop ─────────────────────────────────────────────
log "Auto-commit watcher started"
log "  Repo:     $REPO_DIR"
log "  Branch:   $BRANCH"
log "  Interval: ${INTERVAL}s"
log "  Dry run:  $DRY_RUN"
log "  Log:      $LOG_FILE"
echo ""

while true; do
  # Sync ~/.openclaw/workspace/ into the repo
  sync_openclaw

  # Check for workspace changes only (staged, unstaged, or untracked)
  has_staged=$(git diff --cached --quiet -- "$OPENCLAW_DEST" 2>/dev/null && echo no || echo yes)
  has_unstaged=$(git diff --quiet -- "$OPENCLAW_DEST" 2>/dev/null && echo no || echo yes)
  has_untracked=$(git ls-files --others --exclude-standard -- "$OPENCLAW_DEST" | head -1)

  if [ "$has_staged" = "yes" ] || [ "$has_unstaged" = "yes" ] || [ -n "$has_untracked" ]; then
    log "Changes detected!"

    # Show what changed
    if ! $QUIET; then
      [ "$has_staged" = "yes" ] && log "  Staged changes found"
      [ "$has_unstaged" = "yes" ] && log "  Unstaged changes found"
      [ -n "$has_untracked" ] && log "  Untracked files found"

      log "  Changed files:"
      git status --short 2>/dev/null | while IFS= read -r line; do
        log "    $line"
      done
    fi

    if $DRY_RUN; then
      log "[DRY RUN] Would stage, commit, and push the above changes"
    else
      # Stage only workspace changes
      git add "$OPENCLAW_DEST"

      # Check if there's actually anything to commit after staging
      if ! git diff --cached --quiet 2>/dev/null; then
        # Generate descriptive commit message
        COMMIT_MSG=$(generate_commit_message)
        log "Committing: $COMMIT_MSG"

        # Commit
        git commit -m "$COMMIT_MSG" 2>&1 | tee -a "$LOG_FILE"

        # Push with retry
        log "Pushing to origin/$BRANCH..."
        if push_with_retry; then
          COMMIT_COUNT=$((COMMIT_COUNT + 1))
          log "Push successful (#$COMMIT_COUNT)"
        else
          log "WARNING: Push failed, will retry next cycle"
        fi
      else
        log_quiet "No effective changes after staging"
      fi
    fi

    echo ""
  else
    log_quiet "No changes detected"
  fi

  sleep "$INTERVAL"
done
