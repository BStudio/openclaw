# Mac Mini Full Plan v5.1 — Architecture, Auth & Strategy

_Last updated: 2026-06-22_

---

## Table of Contents

1. [Architecture](#mac-mini-target-architecture)
2. [Phase 1: Prepare](#phase-1-prepare-before-mac-mini-setup) (~15 min)
3. [Phase 2: Mac Mini Base Setup](#phase-2-mac-mini-base-setup) (~45 min)
4. [Phase 3: Auth Setup](#phase-3-auth-setup) (~15 min)
5. [Phase 4: Migrate Workspace](#phase-4-migrate-workspace) (~10 min)
6. [Phase 5: Start & Verify](#phase-5-start--verify) (~15 min)
7. [Phase 6: Auto Token Management](#phase-6-auto-token-management) (~25 min)
8. [Phase 7: Remote Management](#phase-7-remote-management) (~20 min)
9. [Phase 8: Security Hardening](#phase-8-security-hardening) (~25 min)
10. [Phase 9: Auto-Update Strategy](#phase-9-auto-update-strategy-openclaw--system) (~20 min)
11. [Phase 10: Backup, Monitoring & Disaster Recovery](#phase-10-backup-monitoring--disaster-recovery) (~20 min)
12. [Risk Assessment](#risk-assessment)
13. [Day 2 Operations](#day-2-operations)
14. [Full Checklist](#full-checklist)

**Estimated total setup time: ~4 hours** (first time, careful pace)

---

## Current Setup (for reference)

```
Claude Code Remote Container (Anthropic cloud, disposable)
 │
 ├── Claude Opus 4.6 (powered by Max sub $200/mo)
 ├── sk-ant-si-* token (4hr JWT, auto-refreshed by CC backend)
 ├── OpenClaw reads token from disk on every API call
 ├── Keepalive hook prevents session timeout
 └── Kai → Telegram → Kamil

⚠️ Session-coupled: CC session ends = token dies = Kai dies
See: cc-remote-container-setup.md for full details
```

## Mac Mini Target Architecture

```
📱 Kamil (anywhere — PC, phone, or local at the Mac Mini)
 │
 ├── Telegram (primary chat interface)
 ├── Tailscale (secure remote SSH + VNC + Control UI from anywhere)
 │
 ▼
🖥️ Mac Mini M4 24GB 512GB SSD (always on, Kamil's home, monitor attached)
 │
 ├── UPS (recommended — protects against power outage data corruption)
 │
 ├── FileVault (full-disk encryption — protects data at rest)
 │
 ├── launchd (auto-restart on boot/crash)
 │   └── OpenClaw Gateway (daemon, via `openclaw gateway install`)
 │       ├── Telegram plugin (long-polling, no webhook needed)
 │       ├── Cron scheduler
 │       ├── Control UI (http://127.0.0.1:18789 — local or via Tailscale)
 │       └── Kai (main agent)
 │           ├── SOUL.md, MEMORY.md, workspace/
 │           └── future sub-agents
 │
 ├── Auth: Setup Token (sk-ant-oat01-*) → Max sub ($200/mo flat)
 │   └── Monitoring + manual refresh via launchd scheduled alerts
 │
 ├── Maintenance: Daily OpenClaw update + token health check at 4AM
 │   └── Your customizations in ~/.openclaw/ are a separate layer, never touched
 │
 ├── Remote Access: Tailscale (SSH key-only, Screen Sharing, Control UI)
 │
 ├── Backup: Encrypted Time Machine (full) + Git repo (workspace)
 │
 └── Claude Code CLI (dev/debug tool only, NOT runtime)
```

### Layer Separation (why updates are safe)

```
┌─────────────────────────────────────────────────────────┐
│  LAYER 4: Kai's workspace (you control)                 │
│  ~/.openclaw/workspace/ — SOUL.md, MEMORY.md, guides/   │
│  Git-tracked, never touched by updates                  │
├─────────────────────────────────────────────────────────┤
│  LAYER 3: Your scripts (you control)                    │
│  ~/.openclaw/scripts/ — token refresh, maintenance      │
│  Custom automation, never touched by updates            │
├─────────────────────────────────────────────────────────┤
│  LAYER 2: Your config + auth (you control)              │
│  ~/.openclaw/openclaw.json — channels, models, gateway  │
│  ~/.openclaw/agents/*/auth-profiles.json — API keys     │
│  OpenClaw migrates config schema via `doctor`, never    │
│  deletes your settings                                  │
├─────────────────────────────────────────────────────────┤
│  LAYER 1: OpenClaw core (upstream, auto-updated)        │
│  /opt/homebrew/lib/node_modules/openclaw/               │
│  npm package — replaced entirely on update              │
│  Your layers are untouched                              │
└─────────────────────────────────────────────────────────┘
```

**Key insight:** OpenClaw is installed as an npm global package. Updates replace the package code (Layer 1). Your config, auth, workspace, and scripts (Layers 2-4) live in `~/.openclaw/` which npm never touches. `openclaw doctor` handles config schema migrations between versions automatically.

### Key Difference from Current

|                    | Current (CC Remote)        | Mac Mini (Target)                  |
| ------------------ | -------------------------- | ---------------------------------- |
| Infrastructure     | Anthropic cloud container  | Your hardware                      |
| Token type         | sk-ant-si-\* (4hr JWT)     | sk-ant-oat01-\* (long-lived)       |
| Token refresh      | CC backend auto-rotates    | Monitored script + manual refresh  |
| Persistence        | Dies with session          | Survives reboots                   |
| Process supervisor | None (container lifecycle) | launchd (auto-restart)             |
| Remote access      | N/A                        | Tailscale (SSH + VNC + Control UI) |
| Disk encryption    | N/A (ephemeral)            | FileVault (encrypted)              |
| Updates            | N/A                        | Daily auto-update with rollback    |
| Cost               | $200/mo Max sub            | $200/mo Max sub + ~$5 electricity  |

---

## Phase 1: Prepare (Before Mac Mini Setup)

_~15 minutes_

### 1.1 Export Workspace from Current Container

**Optional but recommended:** Update OpenClaw on the CC container before migrating to ensure config compatibility:

```bash
npm install -g openclaw@latest
openclaw doctor --non-interactive
```

Run on current setup to create a portable backup:

```bash
cd /root/.openclaw/workspace
tar czf /tmp/kai-workspace-backup.tar.gz \
  SOUL.md MEMORY.md USER.md IDENTITY.md \
  TOOLS.md AGENTS.md HEARTBEAT.md \
  guides/ memory/
```

Send to Kamil via Telegram or download. **Do this before the CC session dies.**

> **Security note:** The auth backup (1.2) contains API keys and tokens. After downloading it from Telegram, delete the message — no need to leave secrets sitting in chat history.

### 1.2 Export Full OpenClaw State

**Option A: Clean migration (recommended)**

This starts fresh sessions and cron jobs but preserves auth and core config:

```bash
# Config (telegram bot token, channel config, gateway settings)
cp /root/.openclaw/openclaw.json /tmp/openclaw-config-backup.json

# Auth profiles and credentials
tar czf /tmp/openclaw-auth-backup.tar.gz \
  /root/.openclaw/agents/*/agent/auth-profiles.json \
  /root/.openclaw/credentials/ 2>/dev/null || true
```

**Option B: Full migration**

If you want complete session continuity (history, cron jobs, device pairings):

```bash
# Complete state backup
tar czf /tmp/openclaw-full-backup.tar.gz \
  /root/.openclaw/ \
  --exclude=/root/.openclaw/workspace/ \
  --exclude=/root/.openclaw/logs/
```

> **Note:** This preserves everything including session data and active cron jobs. The workspace is excluded because we handle it separately in 1.1.

### 1.3 Note the Telegram Bot Token

The bot token is in `openclaw.json` under `channels.telegram.botToken`. You'll need it on the Mac Mini. **Only one instance can poll Telegram at a time** — stop the old gateway before starting the new one.

---

## Phase 2: Mac Mini Base Setup

_~45 minutes_

### 2.1 Hardware: UPS (Recommended)

Get a basic UPS (~$50-80). The Mac Mini is a 24/7 server now — a power outage mid-write can corrupt OpenClaw's SQLite database or auth files. A UPS gives you clean shutdown time.

### 2.2 macOS System Config

The Mac Mini M4 ships with macOS 15 Sequoia (check for updates: System Settings → General → Software Update — apply security patches first, then disable auto-updates).

**Set timezone first** (affects all scheduled tasks including launchd):

```bash
# Check current timezone
sudo systemsetup -gettimezone

# Set timezone (example — use yours)
sudo systemsetup -settimezone "America/Toronto"
```

**Prevent system sleep** (keep machine running 24/7):

```bash
# Prevent system sleep (this is the critical one for a 24/7 server)
sudo pmset -a sleep 0

# Allow display to sleep after 10 min (saves energy — monitor is there for local use only)
sudo pmset -a displaysleep 10

# Auto-restart after power failure
sudo pmset -a autorestart 1

# Verify
pmset -g
```

> **Note:** `disablesleep 1` is for laptops (prevents sleep on lid close). Mac Mini has no lid — `sleep 0` alone is sufficient.

**System Settings (GUI):**

- **General → Software Update → Automatic Updates:**
  - "Check for updates" → ON
  - "Download new updates when available" → ON
  - "Install macOS updates" → **OFF** (we handle these manually — see Phase 9)
  - "Install application updates from the App Store" → personal preference
  - "Install Security Responses and system files" → **ON** (Rapid Security Responses are small, targeted patches that don't reboot. Leaving this on protects against critical vulnerabilities between manual updates.)
- **Energy** → Prevent automatic sleeping when display is off
- **Lock Screen** → Set "Require password after screen saver begins" to a reasonable time (5 min is a good balance for local + security)

> **⚠️ Never log out of the macOS session.** The maintenance scripts run as LaunchAgents (user-level), which stop when you log out. Just lock the screen or let the display sleep. Fast User Switching to a different account has the same problem.

### 2.3 Enable FileVault (Disk Encryption)

**This is critical.** Without FileVault, if the Mac Mini is stolen, all tokens, API keys, bot tokens, conversation history, and memory files are plaintext on disk.

```
System Settings → Privacy & Security → FileVault → Turn On
```

Or via CLI:

```bash
sudo fdesetup enable
```

- **Save the recovery key** somewhere safe (password manager, printed, NOT on the Mac Mini itself)
- **Consider iCloud escrow:** If you use iCloud, escrowing the key to iCloud is convenient and secure for a home server
- FileVault uses hardware-accelerated encryption on Apple Silicon — **zero performance impact**
- After enabling, the drive encrypts in the background (takes a few hours, doesn't interrupt use)

> **⚠️ FileVault disables automatic login.** This is a macOS security requirement — you can't have full-disk encryption AND skip the password. After every boot (including power outages), you must enter your password once at the FileVault unlock screen. This password both unlocks the disk and logs you in (one step, not two).
>
> **What this means for a 24/7 server:**
>
> - **Planned reboots (macOS updates, maintenance):** SSH in first and run `sudo fdesetup authrestart` — this pre-authorizes the next boot to skip the FileVault screen once. The machine reboots and comes back unattended.
> - **Unexpected power loss:** The Mac Mini boots to the FileVault unlock screen and waits. You must **physically walk to the monitor and type the password.** VNC/Screen Sharing is NOT available at the FileVault pre-boot screen — macOS hasn't loaded yet, so networking and Screen Sharing aren't running.
> - **Why this is OK:** The UPS buys time — if power flickers, the UPS keeps the machine running. For a true extended outage, the UPS eventually shuts down gracefully (no data corruption). When power returns, you enter the password once. This is a reasonable trade-off: physical theft protection vs. minor inconvenience on rare power failures.
>
> **Do NOT enable automatic login** (System Settings → Users & Groups → Login Options). It won't work with FileVault and the conflicting settings can cause confusion.

### 2.4 Enable Remote Access (SSH + Screen Sharing)

**Do this early so you can finish the rest remotely if needed.**

**Enable SSH (Remote Login):**

```
System Settings → General → Sharing → Remote Login → Enable
```

Or via CLI:

```bash
sudo systemsetup -setremotelogin on
```

**Enable Screen Sharing (VNC):**

```
System Settings → General → Sharing → Screen Sharing → Enable
```

> **VNC Authentication:** Use "Use system username and password" (macOS account credentials). This is more secure than VNC-only passwords and integrates with macOS account management.

This lets you:

- SSH in for CLI work from any device
- VNC in for full GUI access (useful for browser-based auth flows like `claude setup-token`)
- Both work over local network immediately, and over Tailscale from anywhere (Phase 7)

> **We'll harden SSH with key-only auth in Phase 8.** For now, password auth is fine on local network.

### 2.5 Install Dependencies

```bash
# Install Xcode Command Line Tools (needed for native npm dependencies like sharp)
# This downloads several GB and takes 5-15 minutes depending on internet speed
xcode-select --install
# Follow the prompt. If already installed, it'll say so.

# Install Homebrew (if not already installed)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Follow the post-install instructions Homebrew prints (adds brew to PATH)
# On Apple Silicon, typically:
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"

# Check what Homebrew will install
brew info node | head -5

# If version shown is 22.x → brew install node jq
# If version shown is 23.x or higher → use node@22 instead:
#   brew install node@22 jq
#   echo 'export PATH="/opt/homebrew/opt/node@22/bin:$PATH"' >> ~/.zprofile
#   source ~/.zprofile

# Verify
node --version  # must be >= 22.x.x (Very new major versions (24+) may have untested compatibility — check OpenClaw release notes)
```

**Alternative: Node version manager (better for dev workstations):**

```bash
brew install fnm
fnm install 22
fnm use 22
fnm default 22
echo 'eval "$(fnm env --use-on-cd)"' >> ~/.zprofile
```

> **Note:** fnm is better suited for dev workstations, not servers. For a 24/7 server with launchd, recommend `brew install node` or `node@22` directly since launchd needs stable absolute paths. If someone insists on fnm, note they must update the plist PATH to include `$(dirname $(fnm exec which node))`.

**Pin Node.js version** (prevents accidental major version bumps):

```bash
brew pin node  # or 'fnm default 22' if using fnm
```

> **Why?** Running `brew upgrade` (to get security patches for other packages) would also upgrade Node — potentially jumping from 22.x to 24.x, which could break OpenClaw. `brew pin node` prevents this while letting everything else upgrade freely. When you're ready to upgrade Node deliberately: `brew upgrade --force node`.

**Note the install paths — needed for launchd scripts later:**

```bash
which node      # e.g. /opt/homebrew/bin/node or /opt/homebrew/opt/node@22/bin/node
which npm       # e.g. /opt/homebrew/bin/npm or /opt/homebrew/opt/node@22/bin/npm
which jq        # e.g. /opt/homebrew/bin/jq
which curl      # should be /usr/bin/curl
```

### 2.6 Install OpenClaw

**Option A: Installer script (recommended — handles everything):**

```bash
curl -fsSL https://openclaw.ai/install.sh | bash
```

This detects Node, installs OpenClaw, and launches the onboarding wizard. Skip to Phase 3.2.

**Option B: Manual npm install:**

```bash
npm install -g openclaw@latest

# Note the path
which openclaw  # e.g. /opt/homebrew/bin/openclaw
```

### 2.7 Install Claude Code CLI

```bash
npm install -g @anthropic-ai/claude-code

# Note the path
which claude  # e.g. /opt/homebrew/bin/claude
```

---

## Phase 3: Auth Setup

_~15 minutes_

### 3.1 Generate Setup Token

```bash
claude setup-token
```

This authenticates with your Max subscription and outputs a token. Copy it.

> **⚠️ This may open a browser for authentication.** This is why Screen Sharing (Phase 2.4) matters — if you're setting up remotely, VNC in to complete the browser auth flow.

### 3.2 Run OpenClaw Onboard

If you used the installer script (Option A in 2.6), onboarding already ran. Otherwise:

```bash
# Run onboarding (interactive setup)
openclaw onboard

# Install the launchd service separately
openclaw gateway install
```

This interactive wizard will:

- Prompt for auth setup (select "setup-token" and paste the token from 3.1)
- Configure the gateway
- Set up the Telegram channel (paste your bot token)

**Important:** The wizard creates default workspace files (SOUL.md, etc). That's fine — we'll overwrite them with our backup in Phase 4.

### 3.3 Verify Auth

```bash
openclaw models status
```

Check that it shows your Anthropic setup-token profile as active.

```bash
# Scripting check
openclaw models status --check
# Exit 0 = OK, Exit 1 = expired/missing, Exit 2 = expiring within 24h

# Live verification (makes a real API request)
openclaw models status --probe
```

### 3.4 Configure Fallback API Key (Insurance)

```bash
openclaw models auth add
# Select: Anthropic API Key
# Paste your ANTHROPIC_API_KEY
```

This gives you a fallback if setup-token ever breaks. OpenClaw fails over automatically.

---

## Phase 4: Migrate Workspace

_~10 minutes_

### 4.1 Restore Workspace Files (Overwrites Onboard Defaults)

```bash
cd ~/.openclaw/workspace
# Adjust the path if you downloaded from Telegram (likely ~/Downloads/)
tar xzf ~/kai-workspace-backup.tar.gz
```

### 4.2 Restore Config (if needed)

If `openclaw onboard` didn't configure everything, merge settings from your backup:

```bash
diff ~/openclaw-config-backup.json ~/.openclaw/openclaw.json
```

Key settings to ensure are present:

- `channels.telegram.botToken`
- `channels.telegram.allowFrom: ["455442541"]`
- `channels.telegram.dmPolicy: "allowlist"`

You can also edit config via the Control UI at `http://127.0.0.1:18789` (Config tab) once the gateway is running.

### 4.3 Initialize Git for Workspace Persistence

```bash
cd ~/.openclaw/workspace
git init
git add SOUL.md MEMORY.md USER.md IDENTITY.md TOOLS.md AGENTS.md HEARTBEAT.md
git add guides/ memory/
git commit -m "Initial workspace migration from CC container"
```

> **Safety: Never use `git add -A` or `git add .`** — only stage specific known files to avoid committing deletions or sensitive data. See AGENTS.md.

**Add private remote for off-site backup** (required for disaster recovery):

```bash
git remote add origin https://github.com/kamil/kai-workspace.git
git branch -M main
git push -u origin main
```

> **⚠️ This step is required, not optional.** The disaster recovery procedure depends on having the workspace backed up outside the Mac Mini. Note: Using HTTPS since SSH keys don't exist yet (Phase 8). Can switch to SSH after Phase 8 is complete.

---

## Phase 5: Start & Verify

_~15 minutes_

### 5.1 Stop Old Instance

**Critical:** Stop the CC container gateway FIRST. Two instances polling the same Telegram bot = conflict and message loss.

```bash
# In the CC container (before shutting it down):
openclaw gateway stop
```

If the CC session is already dead (container was disposed), that's fine — just make sure it's not running before you start the new gateway. If in doubt, start the new gateway and verify Telegram works — if messages arrive, the old one is gone.

### 5.2 Start Gateway

If `openclaw gateway install` was run, it's already a launchd service:

```bash
openclaw gateway start
openclaw gateway status
```

If not installed as daemon yet:

```bash
openclaw gateway install
openclaw gateway start
```

### 5.3 Run Health Checks

```bash
openclaw doctor                        # comprehensive health check + auto-fix
openclaw security audit               # basic security audit
openclaw security audit --deep        # deeper audit
openclaw models status --check        # model auth health
```

### 5.4 Test End-to-End

Send "test" on Telegram. If Kai responds, you're live. 🎉

### 5.5 Verify Daemon Persistence

```bash
openclaw gateway status

# Test restart recovery — kill the process (not graceful stop)
kill $(pgrep -f "openclaw gateway")
sleep 10
openclaw gateway status  # should show it restarted automatically
```

### 5.6 Check the Control UI

Open `http://127.0.0.1:18789` in a browser on the Mac Mini. This is OpenClaw's built-in web dashboard for config editing, log viewing, session management, and health monitoring.

---

## Phase 6: Auto Token Management

_~25 minutes_

### 6.1 Understanding Token Refresh Reality

The setup-token refresh automation is **likely non-interactive and works reliably**, but we've restructured this phase to be honest about the unknowns and provide both monitoring and manual refresh paths.

**Test interactive behavior first:**

```bash
# macOS-compatible timeout test (macOS doesn't have GNU timeout)
claude setup-token 2>/dev/null &
PID=$!
sleep 10
if kill -0 $PID 2>/dev/null; then
    kill $PID 2>/dev/null
    wait $PID 2>/dev/null
    echo "Timed out — likely needs browser auth. Manual refresh required."
else
    wait $PID
    echo "Exit code: $? (0 = token generated successfully)"
fi
```

If it outputs a token without opening a browser (exit 0), the automation will work. If it times out, hangs, or opens a browser, manual refresh is needed.

### 6.2 Discover Paths First

```bash
echo "HOME: $HOME"
echo "UID: $(id -u)"
which openclaw   # e.g. /opt/homebrew/bin/openclaw
which claude     # e.g. /opt/homebrew/bin/claude
which jq         # e.g. /opt/homebrew/bin/jq
which curl       # e.g. /usr/bin/curl
```

### 6.3 The Maintenance Script

This single script handles both token health monitoring and OpenClaw updates in one daily run to minimize gateway restarts.

```bash
mkdir -p ~/.openclaw/scripts ~/.openclaw/logs
```

Create `~/.openclaw/scripts/daily-maintenance.sh`:

**⚠️ Replace all paths with your actual paths from 6.2.**

```bash
#!/bin/bash
# Daily maintenance: token health check + OpenClaw auto-update
# Runs at 4:00 AM daily via launchd

set -uo pipefail
# NOTE: Do NOT use set -e here. This script checks exit codes explicitly
# ($?), and set -e would kill the script on non-zero exits before we can
# read them (e.g. models status --check returns 1/2 when token is expiring).

# === CONFIGURE THESE ABSOLUTE PATHS ===
OPENCLAW="/opt/homebrew/bin/openclaw"
CLAUDE="/opt/homebrew/bin/claude"
NPM="/opt/homebrew/bin/npm"
JQ="/opt/homebrew/bin/jq"
CURL="/usr/bin/curl"
OPENCLAW_HOME="/Users/kamil/.openclaw"
# ======================================

LOG="$OPENCLAW_HOME/logs/daily-maintenance.log"
MAX_LOG_SIZE=2097152  # 2MB
mkdir -p "$(dirname "$LOG")"

# Log rotation
if [ -f "$LOG" ] && [ "$(stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt "$MAX_LOG_SIZE" ]; then
    tail -200 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $1" >> "$LOG"; }

alert_kamil() {
    local msg="$1"

    # Primary: Direct Telegram API
    local BOT_TOKEN
    BOT_TOKEN=$("$JQ" -r '.channels.telegram.botToken // empty' "$OPENCLAW_HOME/openclaw.json" 2>/dev/null)
    if [ -n "$BOT_TOKEN" ]; then
        "$CURL" -s "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            -d chat_id="455442541" \
            -d text="$msg" \
            > /dev/null 2>&1 && return 0
    fi

    log "ALERT DELIVERY FAILED: $msg"
    # Optional: ping healthchecks.io fail endpoint
    # $CURL -fsS -m 10 "https://hc-ping.com/<uuid>/fail" > /dev/null 2>&1
}

needs_restart=false
UPDATE_SUCCESS=false

log "=== Starting daily maintenance ==="

# PART 1: TOKEN HEALTH CHECK
log "Checking token health..."
"$OPENCLAW" models status --check >> "$LOG" 2>&1
TOKEN_STATUS=$?

case $TOKEN_STATUS in
    0)  log "Token is healthy. Skipping refresh."
        ;;
    1)  log "Token is expired or missing. Attempting refresh..."

        # Try automatic refresh
        NEW_TOKEN=$("$CLAUDE" setup-token 2>> "$LOG")

        if [ -n "$NEW_TOKEN" ]; then
            echo "$NEW_TOKEN" | "$OPENCLAW" models auth paste-token --provider anthropic >> "$LOG" 2>&1

            # Verify the new token
            "$OPENCLAW" models status --check >> "$LOG" 2>&1
            VERIFY=$?
            if [ $VERIFY -eq 0 ]; then
                log "Token refresh successful ✅"
                needs_restart=true
            else
                log "ERROR: Token refresh completed but verification failed (exit: $VERIFY)"
                alert_kamil "⚠️ Kai token refresh failed verification. SSH in and run: claude setup-token + paste manually. Check logs: ~/.openclaw/logs/daily-maintenance.log"
            fi
        else
            log "ERROR: claude setup-token returned empty token (likely needs browser auth)"
            alert_kamil "⚠️ Kai token expired and auto-refresh failed (browser auth needed). SSH/VNC in and run: claude setup-token + paste manually. Using API key fallback until fixed."
        fi
        ;;
    2)  log "Token is expiring within 24h. Attempting refresh..."

        NEW_TOKEN=$("$CLAUDE" setup-token 2>> "$LOG")

        if [ -n "$NEW_TOKEN" ]; then
            echo "$NEW_TOKEN" | "$OPENCLAW" models auth paste-token --provider anthropic >> "$LOG" 2>&1
            needs_restart=true
            log "Token preventive refresh successful ✅"
        else
            log "WARNING: Preventive refresh failed, but token still valid for <24h"
            alert_kamil "⚠️ Kai token expires within 24h and auto-refresh failed. SSH/VNC in soon to run: claude setup-token + paste manually."
        fi
        ;;
    *)  log "Unexpected token status exit code: $TOKEN_STATUS"
        ;;
esac

# PART 2: OPENCLAW UPDATE CHECK
log "Checking for OpenClaw updates..."

# Record current version for rollback
CURRENT_VERSION=$("$NPM" list -g openclaw --json 2>/dev/null | "$JQ" -r '.dependencies.openclaw.version // empty')
if [ -z "$CURRENT_VERSION" ]; then
    CURRENT_VERSION=$("$OPENCLAW" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
fi
log "Current OpenClaw version: $CURRENT_VERSION"

if [ "$CURRENT_VERSION" = "unknown" ] || [ -z "$CURRENT_VERSION" ]; then
    log "ERROR: Cannot determine current version. Skipping update (rollback would be impossible)."
    alert_kamil "⚠️ OpenClaw auto-update skipped: couldn't determine current version. SSH in and check."
else
    # Check if update is available
    LATEST_VERSION=$("$NPM" view openclaw version 2>/dev/null || echo "")
    if [ -z "$LATEST_VERSION" ]; then
        log "Failed to check npm registry. Network issue? Skipping update check."
    elif [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
        log "Already on latest version ($LATEST_VERSION). No update needed."
    else
        log "Update available: $CURRENT_VERSION → $LATEST_VERSION"

        # Check for version hold
        if [ -f "$OPENCLAW_HOME/HOLD_VERSION" ]; then
            log "Found HOLD_VERSION file. Skipping automatic update."
            alert_kamil "📌 OpenClaw update available ($CURRENT_VERSION → $LATEST_VERSION) but HOLD_VERSION file present. Delete ~/.openclaw/HOLD_VERSION to resume auto-updates."
        else
            # Install the update
            log "Installing openclaw@latest..."
            "$NPM" install -g openclaw@latest >> "$LOG" 2>&1
            INSTALL_EXIT=$?

            if [ $INSTALL_EXIT -ne 0 ]; then
                log "ERROR: npm install failed (exit $INSTALL_EXIT)"
                alert_kamil "⚠️ OpenClaw auto-update failed during npm install. SSH in and check: ~/.openclaw/logs/daily-maintenance.log"
            else
                NEW_VERSION=$("$OPENCLAW" --version 2>/dev/null || echo "unknown")
                log "Installed version: $NEW_VERSION"

                # Run doctor (handles config migrations) - non-interactive mode
                log "Running openclaw doctor..."
                "$OPENCLAW" doctor --non-interactive >> "$LOG" 2>&1
                DOCTOR_EXIT=$?
                if [ $DOCTOR_EXIT -ne 0 ]; then
                    log "WARNING: doctor found issues (exit $DOCTOR_EXIT). May need manual review."
                    alert_kamil "⚠️ OpenClaw updated to $NEW_VERSION but doctor found issues. SSH in and run: openclaw doctor --fix if needed. Check logs: ~/.openclaw/logs/daily-maintenance.log"
                fi

                needs_restart=true

                # Post-update health checks will happen after restart
                UPDATE_SUCCESS=true
            fi
        fi
    fi
fi

# PART 3: SINGLE RESTART & VERIFICATION
if [ "$needs_restart" = true ]; then
    log "Restarting gateway (token refresh or update)..."
    "$OPENCLAW" gateway restart >> "$LOG" 2>&1
    sleep 10

    # Post-restart health checks
    "$OPENCLAW" gateway status >> "$LOG" 2>&1
    GATEWAY_OK=$?

    "$OPENCLAW" models status --check >> "$LOG" 2>&1
    POST_TOKEN_STATUS=$?

    if [ $GATEWAY_OK -ne 0 ] || [ $POST_TOKEN_STATUS -eq 1 ]; then
        log "ERROR: Post-restart health check failed (gateway: $GATEWAY_OK, auth: $POST_TOKEN_STATUS)"

        # If we updated, try rolling back
        if [ "$UPDATE_SUCCESS" = true ] && [ -n "$CURRENT_VERSION" ] && [ "$CURRENT_VERSION" != "unknown" ]; then
            log "Rolling back OpenClaw to $CURRENT_VERSION..."
            "$NPM" install -g "openclaw@$CURRENT_VERSION" >> "$LOG" 2>&1
            "$OPENCLAW" gateway restart >> "$LOG" 2>&1
            sleep 5

            ROLLBACK_VERSION=$("$OPENCLAW" --version 2>/dev/null || echo "unknown")
            log "Rolled back to: $ROLLBACK_VERSION"

            # Verify rollback succeeded
            if [ "$ROLLBACK_VERSION" != "$CURRENT_VERSION" ]; then
                log "ERROR: Rollback verification failed. Expected $CURRENT_VERSION, got $ROLLBACK_VERSION"
                alert_kamil "⚠️ OpenClaw rollback failed. Expected $CURRENT_VERSION, got $ROLLBACK_VERSION. Manual intervention needed."
            else
                alert_kamil "⚠️ OpenClaw update to $NEW_VERSION failed health checks. Auto-rolled back to $CURRENT_VERSION. Check logs: ~/.openclaw/logs/daily-maintenance.log"
            fi
        else
            alert_kamil "⚠️ OpenClaw gateway failed health checks after maintenance. SSH in and investigate. Check logs: ~/.openclaw/logs/daily-maintenance.log"
        fi
    else
        if [ "$UPDATE_SUCCESS" = true ]; then
            log "Update successful: $CURRENT_VERSION → $NEW_VERSION ✅"
            # Only alert on updates, not routine token refresh
            alert_kamil "✅ OpenClaw updated: $CURRENT_VERSION → $NEW_VERSION"
        else
            log "Daily maintenance completed successfully"
        fi
    fi
else
    log "Daily maintenance completed - no restart needed"
fi

log "=== Daily maintenance finished ==="
```

```bash
chmod +x ~/.openclaw/scripts/daily-maintenance.sh
```

### 6.4 Schedule via launchd

Create `~/Library/LaunchAgents/com.openclaw.daily-maintenance.plist`:

**⚠️ Replace `/Users/kamil` and paths with your actual paths.**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.openclaw.daily-maintenance</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Users/kamil/.openclaw/scripts/daily-maintenance.sh</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>4</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>/Users/kamil/.openclaw/logs/maintenance-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/kamil/.openclaw/logs/maintenance-stderr.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>/Users/kamil</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/opt/homebrew/opt/node@22/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
```

> **Note:** Update the PATH entry to include `/opt/homebrew/opt/node@22/bin` if you used the keg-only Node install.

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.openclaw.daily-maintenance.plist
```

To unload: `launchctl bootout gui/$(id -u)/com.openclaw.daily-maintenance`

### 6.5 Test Manually First

```bash
# Test token check behavior
openclaw models status --check; echo "Exit: $?"

# Test the full script
~/.openclaw/scripts/daily-maintenance.sh

# Check logs
cat ~/.openclaw/logs/daily-maintenance.log
```

### 6.6 Version Hold Mechanism

To temporarily stop auto-updates (before a trip, etc.):

```bash
# Pause auto-updates
touch ~/.openclaw/HOLD_VERSION

# Resume auto-updates
rm ~/.openclaw/HOLD_VERSION
```

The script checks for this file and skips updates when present, sending you a Telegram alert about the available update.

### 6.7 Setup Token Deprecation Plan

If Anthropic deprecates setup-token:

1. **Monitor sources:** Anthropic changelogs, OpenClaw Discord, release notes
2. **Check available auth methods:** `openclaw models auth add` shows current options
3. **Prepared fallback:** API key is already configured and will auto-activate
4. **Update auth method:** OpenClaw will add support for new Anthropic auth as it becomes available

---

## Phase 7: Remote Management

_~20 minutes — do this BEFORE security hardening so you have remote access as a safety net_

### 7.1 Install Tailscale

Tailscale creates an encrypted WireGuard VPN between your devices. Free for personal use (up to 100 devices). No port forwarding, no exposed ports, works from anywhere.

**On the Mac Mini:**

```bash
# Option A: Homebrew cask (manual updates via brew upgrade --cask)
brew install --cask tailscale

# Option B: Mac App Store version (auto-updates)
# Install Tailscale from the Mac App Store instead

# Start and authenticate
open /Applications/Tailscale.app
```

**On your other devices:**

- **PC (Windows/Mac/Linux):** [tailscale.com/download](https://tailscale.com/download)
- **Phone (iOS/Android):** Tailscale app from your app store

Once all devices are on the same tailnet, they can reach each other securely from anywhere.

```bash
# Find your Mac Mini's Tailscale IP
tailscale ip -4  # e.g. 100.x.y.z
```

### 7.2 Remote Access Methods

**From PC — SSH (CLI):**

```bash
ssh kamil@100.x.y.z       # Tailscale IP
ssh kamil@mac-mini         # MagicDNS (if configured)
```

**SSH Convenience Config:**

Create `~/.ssh/config` on your PC:

```
Host mac-mini
    HostName 100.x.y.z
    User kamil
    IdentityFile ~/.ssh/id_ed25519
```

Then just `ssh mac-mini` from anywhere.

**From PC — Screen Sharing (full GUI):**

- **macOS:** Finder → Go → Connect to Server → `vnc://100.x.y.z`
- **Windows:** RealVNC / TightVNC → `100.x.y.z:5900`
- **Linux:** `vncviewer 100.x.y.z` or Remmina

**From Phone — SSH:**

- **iOS:** Termius (free), Prompt, or Blink Shell
- **Android:** Termius, JuiceSSH, or ConnectBot

**From Phone — Screen Sharing:**

- **iOS:** Screens 5, or any VNC client
- **Android:** RealVNC Viewer, bVNC

**From anywhere — OpenClaw Control UI:**

```
http://100.x.y.z:18789
```

For HTTPS with Tailscale identity auth (no password needed from tailnet devices):

```json5
// In openclaw.json — verify config keys on your version
// Run `openclaw config schema` to check available gateway.tailscale options
{
  gateway: {
    bind: "loopback",
    tailscale: { mode: "serve" },
    auth: { allowTailscale: true },
  },
}
```

Access via `https://mac-mini.your-tailnet.ts.net/`

### 7.3 Startup Ordering (After Power Outage)

After a power outage + FileVault unlock, launchd starts the OpenClaw gateway service. If Wi-Fi/DNS isn't ready yet, the gateway's first connection attempts will fail — but **this is handled automatically.** OpenClaw's Telegram plugin uses long-polling with built-in reconnection and exponential backoff. It will retry until the network is available.

You'll see a few connection errors in the first 10-30 seconds of logs after boot. This is normal and resolves itself. No action needed.

---

## Phase 8: Security Hardening

_~25 minutes — do this AFTER Tailscale (Phase 7) so you have remote access as a fallback if SSH config breaks_

### 8.1 File Permissions

Secure the OpenClaw directory and config files:

```bash
chmod 700 ~/.openclaw/
chmod 600 ~/.openclaw/openclaw.json
find ~/.openclaw/agents/*/agent/ -name "auth-profiles.json" -exec chmod 600 {} \;
```

### 8.2 SSH Key-Only Authentication

Password-based SSH is vulnerable to brute-force attacks. Switch to key-only auth.

**Step 1: Generate SSH key on your PC** (if you don't have one):

```bash
ssh-keygen -t ed25519 -C "kamil@pc"
```

**Step 2: Copy your public key to the Mac Mini** (use Tailscale IP):

```bash
ssh-copy-id kamil@100.x.y.z
```

**Step 3: Verify key-based login works from PC:**

```bash
ssh kamil@100.x.y.z  # should NOT ask for password
```

**Step 4: Generate and copy SSH key from your phone.**

Use your phone's SSH app (Termius, Blink, etc.) to generate an ed25519 key, then copy the public key to the Mac Mini:

```bash
ssh kamil@100.x.y.z
# On the Mac Mini, add your phone's public key to ~/.ssh/authorized_keys
```

**Step 5: Test key login from ALL devices** via Tailscale:

- PC via Tailscale: `ssh kamil@100.x.y.z`
- Phone via SSH app → same Tailscale IP
- PC via local network (if applicable): `ssh kamil@<local-ip>`

> **⚠️ Verify SSH keys work from EVERY device you want to use before the next step.** If you lock yourself out of SSH, you'll need physical monitor + keyboard access.

**Step 6: Disable password authentication:**

```bash
sudo nano /etc/ssh/sshd_config
```

Find and change (or add) these lines — **ensure there's no `#` prefix** (commented lines have no effect):

```
PasswordAuthentication no
KbdInteractiveAuthentication no
```

Leave `UsePAM yes` unchanged (required for macOS account integration).

Then restart SSH:

```bash
sudo launchctl kickstart -k system/com.openssh.sshd
```

**Step 7: Test SSH from all devices again** after disabling password auth to confirm it still works.

### 8.3 OpenClaw Security Audit

```bash
openclaw security audit                # basic security checks
# Run 'openclaw security audit --help' to see available flags on your version
```

### 8.4 macOS Firewall

```bash
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setallowsigned on
```

This allows signed system services (SSH, Screen Sharing, Tailscale) while blocking unsigned incoming connections.

> **Why `--setallowsigned` not `--setblockall`?** The `--setblockall` option can interfere with SSH and Screen Sharing over Tailscale by overriding per-app allowances. `--setallowsigned` provides strong security (blocks random unsigned services) while preserving access to essential Apple-signed services.

### 8.5 Gateway Auth

Ensure `openclaw.json` has a strong gateway token:

```json5
{
  gateway: {
    mode: "local",
    auth: {
      mode: "token",
      token: "<strong-random-token>",
    },
  },
}
```

Generate one:

```bash
openssl rand -hex 32
```

After setting the gateway token, run `openclaw gateway restart`. The gateway auth token is a server setting that requires restart.

---

## Phase 9: Auto-Update Strategy (OpenClaw + System)

_~20 minutes_

### 9.1 Architecture: Why Updates Don't Break Your Stuff

OpenClaw is installed as an **npm global package**. It lives in `/opt/homebrew/lib/node_modules/openclaw/`. Your customizations live in `~/.openclaw/`. These are completely separate:

| What               | Where                                      | Updated by                       |
| ------------------ | ------------------------------------------ | -------------------------------- |
| OpenClaw core code | `/opt/homebrew/lib/node_modules/openclaw/` | `npm install -g openclaw@latest` |
| Your config        | `~/.openclaw/openclaw.json`                | You (or `openclaw configure`)    |
| Your auth/tokens   | `~/.openclaw/agents/*/auth-profiles.json`  | `openclaw models auth` commands  |
| Kai's workspace    | `~/.openclaw/workspace/`                   | Kai (git-tracked)                |
| Your scripts       | `~/.openclaw/scripts/`                     | You                              |
| Session data       | `~/.openclaw/state/`                       | OpenClaw (internal)              |
| Cron jobs          | `~/.openclaw/state/cron/`                  | OpenClaw (via cron tool)         |

`npm install -g openclaw@latest` replaces **only** the package in `node_modules/`. It never touches `~/.openclaw/`.

When config schema changes between versions, `openclaw doctor` handles the migration — it adds new fields with safe defaults and renames deprecated keys. It never deletes your settings.

### 9.2 Auto-Update is Already Configured

The daily maintenance script in Phase 6.3 includes OpenClaw auto-update with:

- Version recording for rollback
- Automatic health checks after update
- Rollback on failure
- Telegram alerts for success/failure
- `HOLD_VERSION` file to pause updates when needed

No additional setup is required.

### 9.3 Manual Update (when you want control)

```bash
# Check what's available
npm view openclaw version

# Update manually
npm install -g openclaw@latest
openclaw doctor --non-interactive
openclaw gateway restart
openclaw models status --check

# Or use the installer (also handles Node updates)
curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard
```

**Pin to a specific version** (if latest is broken):

```bash
npm install -g openclaw@2026.6.15
openclaw gateway restart
```

**Check available update channels:**

```bash
# Note: may only work for git installs, not npm installs
openclaw update --channel stable   # default, recommended
openclaw update --channel beta     # cutting edge
```

### 9.4 Node.js Update Strategy

Node.js updates are separate from OpenClaw and require more care:

```bash
# Check current Node version
node --version

# Update Node (when you're ready — bypasses the pin)
brew upgrade --force node
# or if using fnm:
fnm install 22 && fnm use 22 && fnm default 22

openclaw doctor --non-interactive
openclaw gateway restart
```

**When to update Node:**

- Security advisories for your Node major version
- OpenClaw bumps its minimum Node requirement (check release notes)
- Every ~6 months during a maintenance window

**When NOT to update Node:**

- Right before a trip (can't debug if something breaks)
- If you haven't checked OpenClaw release notes for compatibility
- Node major version jump (22 → 24) — wait for OpenClaw to confirm support

### 9.5 macOS Update Strategy

macOS updates can reboot the machine and sometimes break things:

**Monthly maintenance window approach:**

1. Pick a day/time when a 30-min outage is OK (e.g., Sunday morning)
2. Ensure Time Machine backup is current
3. Check [Apple security updates page](https://support.apple.com/en-us/100100) for what's in the update
4. SSH in and apply:
   ```bash
   sudo softwareupdate --list
   sudo softwareupdate --install --recommended
   ```
5. If it requires a reboot, pre-authorize FileVault first:
   ```bash
   sudo fdesetup authrestart
   ```
   The Mac Mini reboots, skips the FileVault password screen (once), launchd starts OpenClaw, Kai comes back — all unattended.
6. Verify: `ssh kamil@100.x.y.z "openclaw gateway status"`

**Security-only updates** (no reboot needed) — apply these promptly:

```bash
sudo softwareupdate --install --recommended --no-scan
```

### 9.6 Claude Code CLI Update Strategy

Update separately from OpenClaw (different package):

```bash
npm install -g @anthropic-ai/claude-code@latest
```

Only matters for the token refresh functionality (`claude setup-token`). Update monthly or when Anthropic announces changes.

---

## Phase 10: Backup, Monitoring & Disaster Recovery

_~20 minutes_

### 10.1 Time Machine (Full System Backup)

Enable Time Machine in **System Settings → General → Time Machine**.

**⚠️ Enable encrypted backups:** Check "Encrypt backups" and set a backup password. Store this password with your FileVault recovery key. Without encryption, all your tokens and keys sit in plaintext on the Time Machine drive, defeating FileVault's protection.

Time Machine backs up the entire `~/.openclaw` directory:

- Auth profiles and tokens
- Session data and history
- Cron jobs and device pairings
- Workspace files
- Gateway config

Use an external drive (~$50-100 one-time cost) or a NAS. This is included in the monthly cost estimate under hardware.

### 10.2 Workspace Git

The daily maintenance script doesn't handle workspace git commits. Workspace git commits should be added to HEARTBEAT.md or done manually until heartbeats are configured. Optionally, add a simple git commit/push to the daily maintenance script for automated workspace backups.

Kai should do this during heartbeats:

```bash
cd ~/.openclaw/workspace
git add SOUL.md MEMORY.md USER.md IDENTITY.md TOOLS.md AGENTS.md HEARTBEAT.md
git add guides/ memory/
git commit -m "Workspace update $(date +%Y-%m-%d)"
git push origin main
```

**Never `git add -A` or `git add .`** — specific files only.

### 10.2.1 Back Up Scripts and Plists to Workspace

Your custom scripts (`~/.openclaw/scripts/`) and launchd plists (`~/Library/LaunchAgents/com.openclaw.*.plist`) aren't in the workspace git by default. Store reference copies so they survive a "from scratch" recovery:

```bash
cd ~/.openclaw/workspace
mkdir -p reference/scripts reference/plists
cp ~/.openclaw/scripts/*.sh reference/scripts/
cp ~/Library/LaunchAgents/com.openclaw.*.plist reference/plists/
git add reference/
git commit -m "Add reference copies of scripts and plists"
git push origin main
```

During recovery, copy them back and update the absolute paths for the new machine.

### 10.3 Network Down Alerting

If home internet drops, Kai goes silent with no way to tell you. Use a dead man's switch pattern:

**Healthchecks.io setup:**

1. Create account at [healthchecks.io](https://healthchecks.io) (free tier: 20 checks)
2. Create a check with 2-hour grace period
3. Copy the ping URL
4. Add to Kai's periodic checks (HEARTBEAT.md):

```bash
# Dead man's switch - ping every 1-2 hours when active
curl -fsS -m 10 --retry 5 https://hc-ping.com/your-uuid-here
```

5. Configure alerts: email, SMS, Slack, etc.

**How it works:** Healthchecks.io expects a ping every ~2 hours. If the ping stops (internet down, Mac Mini dead, Kai crashed), you get an external alert. The monitoring server is outside your network, so it detects the _absence_ of a signal.

**Alternative: Tailscale admin console:**

- [login.tailscale.com/admin/machines](https://login.tailscale.com/admin/machines) shows device online/offline
- The Tailscale app on your phone also shows device status
- Quick manual check — no automated alerts

### 10.4 Disk Space Monitoring

512GB fills up over time. Add this to Kai's periodic checks (HEARTBEAT.md) or create a cron job:

```bash
# Check disk usage (alert if >80%)
USAGE=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
if [ "$USAGE" -gt 80 ]; then
    echo "⚠️ Disk usage at ${USAGE}%"
fi
```

**Things that accumulate:**

- Time Machine local snapshots (`tmutil listlocalsnapshots /`)
- Homebrew cache (`brew cleanup` to clear)
- OpenClaw session data
- Node.js npm cache (`npm cache verify` — gentler than `--force`)

### 10.5 Log Management

OpenClaw writes rolling daily logs to `/tmp/openclaw/openclaw-YYYY-MM-DD.log` (cleared on reboot).

For persistent logs (optional — only if you need logs to survive reboots):

```json5
{
  logging: {
    file: "~/.openclaw/logs/gateway.log",
    level: "info",
  },
}
```

> **⚠️ If you enable persistent logging, consider using OpenClaw's built-in rolling logs** instead of adding external rotation. Change the log directory in config rather than using newsyslog on top.

View logs:

```bash
openclaw logs --follow  # live tail
```

### 10.6 Disaster Recovery: Full Rebuild Procedure

If the Mac Mini dies, gets replaced, or needs a fresh start:

**From Time Machine backup (fastest):**

1. Set up new Mac Mini
2. During macOS Setup Assistant, choose "Restore from Time Machine"
3. This restores everything: OpenClaw, config, workspace, auth, scripts
4. Verify: `openclaw gateway status && openclaw models status --check`
5. Done

**From scratch (when Time Machine isn't available):**

1. **Follow Phase 2** (base setup: Homebrew, Node, OpenClaw, Claude Code CLI)
2. **Restore config:**

   ```bash
   # If you have the config backup file:
   cp openclaw-config-backup.json ~/.openclaw/openclaw.json

   # If not, re-run onboard:
   openclaw onboard
   openclaw gateway install
   ```

3. **Restore workspace from git:**
   ```bash
   cd ~/.openclaw
   # Use HTTPS — SSH keys won't exist on a fresh machine
   # If private repo requires auth, configure git credential helper instead of embedding PAT in URL
   git clone https://github.com/kamil/kai-workspace.git workspace
   ```
4. **Re-authenticate:**
   ```bash
   claude setup-token
   openclaw models auth paste-token --provider anthropic
   openclaw models auth add  # re-add API key fallback
   ```
5. **Restore scripts:**
   ```bash
   mkdir -p ~/.openclaw/scripts ~/.openclaw/logs
   # Copy from workspace/reference/ and update absolute paths
   cp ~/.openclaw/workspace/reference/scripts/* ~/.openclaw/scripts/
   # Edit paths in scripts to match new machine
   ```
6. **Re-install launchd plists:**
   ```bash
   # Copy from workspace/reference/ and update absolute paths
   cp ~/.openclaw/workspace/reference/plists/* ~/Library/LaunchAgents/
   # Edit paths in plists to match new machine
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.openclaw.daily-maintenance.plist
   ```
7. **Re-install Tailscale (Phase 7):** `brew install --cask tailscale`, authenticate
8. **Re-harden (Phase 8):** SSH keys, file permissions, firewall, FileVault
9. **Start gateway:** `openclaw gateway start`
10. **Test:** Send message on Telegram

**Estimated recovery time:** ~1 hour from Time Machine, ~2-3 hours from scratch.

---

## Risk Assessment

### Why Setup Token Should Be Safe

- `claude setup-token` is Anthropic's own official CLI tool
- OpenClaw docs list it as the "preferred Anthropic auth"
- Not a hack — published, documented command
- Official replacement after OAuth was deprecated

### Why It Might Not Last

- Same billing pattern as OAuth (sub → token → third-party → unlimited)
- If mass-abused, Anthropic could restrict it
- Possible: rate limits, client fingerprinting, ToS changes

### Mitigation Strategy

1. ✅ Setup token as PRIMARY auth (monitored + alerting)
2. 🔄 API key configured as automatic FALLBACK
3. 💰 Budget $50-100/mo API credits as insurance
4. 🧠 Use Sonnet for routine/sub-agent tasks (cheaper if fallback triggers)
5. 📋 Monitor health daily, refresh only when needed
6. 🚫 Reasonable usage patterns
7. 🔧 Swapping auth method = one config change
8. 📊 Early warning via `openclaw models status --check`
9. 📡 Monitor Anthropic changelogs and OpenClaw Discord for changes

---

## Monthly Cost

| Item                               | Cost                                 |
| ---------------------------------- | ------------------------------------ |
| Claude Max sub                     | $200                                 |
| Mac Mini electricity               | ~$5                                  |
| UPS (one-time ~$60)                | $0/mo                                |
| Time Machine drive (one-time ~$80) | $0/mo                                |
| Telegram bot                       | free                                 |
| Tailscale                          | free (personal)                      |
| Healthchecks.io                    | free tier                            |
| API fallback budget                | $50-100 (insurance, may not be used) |
| **Total**                          | **~$205 + $50-100 insurance**        |

---

## Day 2 Operations

### Quick Status Check (remote)

```bash
ssh kamil@100.x.y.z "openclaw gateway status && openclaw models status --check && df -h /"
```

### Manual Update

```bash
npm install -g openclaw@latest && openclaw doctor --non-interactive && openclaw gateway restart
```

### Manual Token Refresh

```bash
claude setup-token
openclaw models auth paste-token --provider anthropic
openclaw gateway restart
openclaw models status --check
```

### Checking Logs

```bash
openclaw logs --follow                            # gateway logs
cat ~/.openclaw/logs/daily-maintenance.log        # maintenance log
cat ~/.openclaw/logs/maintenance-stdout.log       # launchd stdout
```

### Remote Access Quick Reference

```bash
ssh kamil@100.x.y.z                    # CLI (or 'ssh mac-mini' with config)
open vnc://100.x.y.z                   # GUI (from macOS)
# http://100.x.y.z:18789               # Control UI (any browser)
```

### Troubleshooting

| Problem                     | Check                                    | Fix                                                                                                                     |
| --------------------------- | ---------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Kai not responding          | `openclaw gateway status`                | `openclaw gateway restart`                                                                                              |
| Auth errors                 | `openclaw models status --check`         | `claude setup-token` + `paste-token`                                                                                    |
| Telegram not working        | `openclaw doctor --non-interactive`      | Check bot token, one instance only                                                                                      |
| Mac Mini sleeping           | `pmset -g`                               | `sudo pmset -a sleep 0`                                                                                                 |
| After power outage          | `openclaw gateway status`                | launchd auto-restarts; verify                                                                                           |
| Config issues               | `openclaw doctor --non-interactive`      | `openclaw doctor --fix` for manual fixes if needed                                                                      |
| Update broke things         | `~/.openclaw/logs/daily-maintenance.log` | `npm install -g openclaw@<old-version>`                                                                                 |
| Disk full                   | `df -h /`                                | `brew cleanup && npm cache verify`                                                                                      |
| Can't SSH remotely          | Tailscale app on phone                   | Check both devices on same tailnet                                                                                      |
| FileVault lock after reboot | Physical monitor + keyboard              | Enter password at FileVault screen (VNC not available pre-boot). For planned reboots: `sudo fdesetup authrestart` first |
| Node version mismatch       | `node --version`                         | `brew upgrade --force node` (check OpenClaw reqs first)                                                                 |
| Keychain issues             | Login keychain                           | Ensure login keychain is unlocked after FileVault boot                                                                  |

---

## Full Checklist

### Pre-Migration

- [ ] Export workspace backup (tar.gz)
- [ ] Export openclaw.json config backup
- [ ] Export auth profiles + credentials backup
- [ ] Note Telegram bot token
- [ ] Send backups to Kamil via Telegram

### Mac Mini Hardware

- [ ] Get a basic UPS ($50-80)
- [ ] Connect Mac Mini to UPS + monitor

### Mac Mini OS Setup (~30 min)

- [ ] Apply latest macOS security updates first
- [ ] Set timezone
- [ ] Prevent system sleep (`pmset -a sleep 0`)
- [ ] Display sleep 10 min (`pmset -a displaysleep 10`)
- [ ] Auto-restart after power failure (`pmset -a autorestart 1`)
- [ ] Disable automatic macOS updates
- [ ] **Enable FileVault** — save recovery key securely (disables automatic login — this is expected)
- [ ] Enable Remote Login (SSH) with system username/password auth
- [ ] Enable Screen Sharing (VNC) with system username/password auth
- [ ] Install Xcode Command Line Tools (`xcode-select --install`) — takes 5-15 min
- [ ] Install Homebrew
- [ ] **Check Node version FIRST:** `brew info node | head -5`
- [ ] Install Node.js and jq (`brew install node jq` or use `node@22`/`fnm` if needed)
- [ ] Verify Node >= 22 (`node --version`)
- [ ] Pin Node.js version (`brew pin node`)

### Install Tools (~10 min)

- [ ] Install OpenClaw — note path
- [ ] Install Claude Code CLI — note path
- [ ] Note all binary paths (`which openclaw claude node npm jq curl`)

### Auth & Config (~15 min)

- [ ] Test `claude setup-token` interactivity (timeout test)
- [ ] Generate setup token (`claude setup-token`)
- [ ] Run `openclaw onboard` (interactive setup)
- [ ] Run `openclaw gateway install` (launchd service)
- [ ] Verify auth (`--check` and `--probe`)
- [ ] Add fallback API key

### Migration (~10 min)

- [ ] **Stop old CC container gateway** (`openclaw gateway stop`)
- [ ] Restore workspace from backup
- [ ] Restore/merge config if needed
- [ ] Init git repo (specific files only)
- [ ] **Add private remote for DR** (required, not optional)
- [ ] Push workspace to remote

### Launch (~15 min)

- [ ] Start gateway
- [ ] Run `openclaw doctor --non-interactive`
- [ ] Run `openclaw security audit` (verify available flags first)
- [ ] Check Control UI at `http://127.0.0.1:18789`
- [ ] Test Telegram
- [ ] Verify daemon auto-restart (kill process, not graceful stop)

### Token Management (~25 min)

- [ ] Create `daily-maintenance.sh` with absolute paths
- [ ] `chmod +x` the script
- [ ] Create + load launchd plist (update PATH if using node@22)
- [ ] Test manually and check logs

### Remote Management (~20 min) — do before security hardening

- [ ] Install Tailscale on Mac Mini (`brew install --cask tailscale` or App Store)
- [ ] Authenticate Tailscale
- [ ] Install Tailscale on PC + phone
- [ ] Note Mac Mini's Tailscale IP (`tailscale ip -4`)
- [ ] Test SSH via Tailscale from PC
- [ ] Test VNC via Tailscale from PC
- [ ] Test SSH from phone via Tailscale
- [ ] Test Control UI via `http://100.x.y.z:18789`
- [ ] Optional: Create SSH config file for convenience
- [ ] Optional: Tailscale Serve for HTTPS

### Security Hardening (~25 min) — do after Tailscale

- [ ] Set file permissions (`chmod 700 ~/.openclaw/`, `chmod 600` config files)
- [ ] Generate SSH key on PC (if needed)
- [ ] Copy to Mac Mini via Tailscale IP (`ssh-copy-id`)
- [ ] Verify key login works from PC
- [ ] Generate SSH key on phone, copy to Mac Mini via Tailscale
- [ ] **Verify key login works from ALL devices via Tailscale**
- [ ] Disable SSH password auth (only after ALL keys verified)
- [ ] Test SSH from all devices again after disabling passwords
- [ ] Enable macOS firewall (`--setallowsigned on`)
- [ ] Verify Tailscale + SSH + VNC still work after firewall
- [ ] Set strong gateway auth token

### Backup & Monitoring (~20 min)

- [ ] Enable Time Machine with **encrypted backups**
- [ ] Copy scripts + plists to `workspace/reference/` and git commit
- [ ] Push workspace reference files to remote
- [ ] Optional: Set up Healthchecks.io dead man's switch
- [ ] Optional: Add disk space check to HEARTBEAT.md

### Verify Week 1

- [ ] Check if `claude setup-token` works non-interactively
- [ ] Monitor token lifetime (how often does it need refresh?)
- [ ] Verify maintenance script ran successfully (check logs next morning)
- [ ] Test complete setup on a weekend before production switchover

---

## Changelog

- **v1:** Basic checklist, pseudocode refresh script
- **v2:** 7 phases, verified CLI commands, launchd plist, security hardening, day 2 ops
- **v3:** Fixed launchd `$HOME` bug (absolute paths), PATH in launchd, `git add -A` → specific files, jq for bot token, UPS, log rotation, network-down alerting, timezone, Phase 3→4 ordering, Time Machine backup
- **v3.1:** Fixed `brew install node@22` keg-only, deprecated `launchctl load`, inconsistent paste-token, `displaysleep 0`, stderr suppression, removed `disablesleep 1`. Added SSH + Screen Sharing, Tailscale remote management, Control UI, installer script, log management
- **v4 (2026-02-22):**
  - **FileVault disk encryption** — full-disk encryption with recovery key management and FileVault + automatic login interaction notes
  - **SSH key-only authentication** — disable password auth, setup for PC and phone
  - **Auto-update strategy (Phase 9)** — daily OpenClaw updates from upstream npm with automatic rollback on health check failure, Telegram alerts on success/failure
  - **Layer separation diagram** — explains why updates never touch your config/workspace/scripts
  - **Node.js version pinning** — `brew pin node` prevents accidental Node major version bumps during `brew upgrade`
  - **Node.js update strategy** — when and when not to update, manual approach
  - **macOS update strategy** — monthly maintenance window approach with pre-authorized FileVault restart
  - **Claude Code CLI update strategy** — separate from OpenClaw, monthly
  - **Startup ordering** — network-wait helper script for clean boot after power outage
  - **Disk space monitoring** — what accumulates, how to clean
  - **Disaster recovery procedure** — full step-by-step rebuild from Time Machine or from scratch
  - **Table of contents** with estimated times per phase
  - **Estimated total setup time** (~3.5 hours)
  - **Expanded checklist** with time estimates per section
  - **v4.1 (2026-02-22):**
    - Fixed `set -euo pipefail` → `set -uo pipefail` in both scripts (set -e killed scripts before $? could be read on non-zero exits — token refresh was completely non-functional)
    - Fixed FileVault vs automatic login contradiction — FileVault disables automatic login on macOS; removed "enable automatic login" instruction, added clear explanation of boot behavior and `fdesetup authrestart` for planned reboots
    - Fixed checklist: `brew pin node` now comes after `brew install node` (can't pin what isn't installed)
    - Fixed auto-update version comparison: now uses `npm list -g --json` for installed version (same format as `npm view`, prevents false mismatch)
    - Fixed SSH hardening: removed `UsePAM no` (breaks macOS account integration); `PasswordAuthentication no` + `KbdInteractiveAuthentication no` is sufficient
    - Removed dead `gateway-start-delay.sh` script (was never wired into launchd plist); replaced with explanation that OpenClaw handles reconnection natively
    - Fixed disaster recovery git clone: SSH → HTTPS (SSH keys won't exist on a fresh machine)
  - **v4.2 (2026-02-22):**
    - Fixed UptimeRobot recommendation — Tailscale IPs aren't reachable from external monitors. Replaced with Healthchecks.io dead man's switch pattern
    - Fixed FileVault VNC claim — VNC is impossible at the pre-boot FileVault screen (macOS not loaded yet). Corrected to: physical keyboard required
    - Changed token refresh from weekly to daily — unknown token lifetime makes weekly a gamble; daily check is near-zero cost (exits instantly if healthy)
    - Swapped Phase 7 ↔ Phase 8: Tailscale (remote management) now comes BEFORE SSH hardening, so you have remote access as a safety net when disabling password auth
    - Added `~/.openclaw/credentials/` to Phase 1 backup (OpenClaw docs explicitly list this for migration)
    - Granular macOS auto-update settings — keep "Security Responses and system files" (RSR) ON for critical patches that don't reboot
    - Added unknown-version guard to auto-update script (skip if current version can't be determined — rollback would be impossible)
    - Added Xcode Command Line Tools install (needed for native npm dependencies like sharp)
    - Added reference copies of scripts + plists in workspace git (recoverable without Time Machine)
    - Fixed `doctor --fix` → `doctor --yes` inconsistency in troubleshooting table
    - Offset auto-update to 5:30 AM (avoids overlap with token refresh at 4 AM)
    - Expanded SSH hardening steps: verify keys from ALL devices via Tailscale before disabling passwords
  - **v4.2.1 (2026-02-22):**
    - Fixed sshd_config formatting — config lines were inside bash comments with `#` prefix, which would make them inactive comments in sshd_config (SSH hardening silently fails). Now shown as plain config with clear instructions and tip for existing entries
    - Fixed FileVault troubleshooting row: "Monitor / local VNC" → "Physical monitor + keyboard" (VNC not available at pre-boot screen)
    - Added specific stop command for Phase 5.1 (old CC container: `openclaw gateway stop`)
    - Added persistent log rotation via macOS newsyslog (without it, custom log path grows unbounded)
    - Added security note to delete auth backup from Telegram after downloading
    - Added path hint for tar extraction (~/Downloads/ if downloaded from Telegram)
- **v5.0 (2026-06-22):**
  - **CRITICAL FIXES:**
    - **C1:** Node version drift — added check for `brew info node`, use `node@22` or `fnm` if version is too new, updated PATH instructions for keg-only install
    - **C2:** Setup-token non-interactive — restructured Phase 6 as monitoring+alerting approach with test-first step, honest about manual refresh likely needed
    - **C3:** Firewall — replaced `--setblockall on` with `--setallowsigned on` to prevent SSH/VNC lockout
    - **C4:** Doctor flags — changed `--yes` to `--non-interactive` to avoid auto-accepting potentially breaking changes
    - **C5:** Combined token refresh + auto-update — single maintenance script at 4AM with one restart to minimize conversation interruption
    - **C6:** Migration backup options — added full backup option, explicit note about what's intentionally left behind in clean migration
    - **C7:** Fixed onboard command — split `--install-daemon` into separate `openclaw onboard` + `openclaw gateway install` commands
  - **SIGNIFICANT FIXES:**
    - **S1:** Added `chmod 600` for config files and auth profiles in security hardening
    - **S2:** Fixed onboard command structure per current CLI
    - **S3:** Added encrypted Time Machine backup requirement and instructions
    - **S4:** Fixed daemon persistence test to kill PID (test crash recovery) vs graceful stop
    - **S5:** Added warning about never logging out (stops LaunchAgents)
    - **S6:** Added dual alert mechanism (OpenClaw message + Telegram API fallback) with error handling
    - **S7:** Added `HOLD_VERSION` file mechanism to pause auto-updates
    - **S8:** Made git remote push non-optional and required for disaster recovery
    - **S9:** Added keychain considerations note
    - **S10:** Added setup-token deprecation pivot plan section
    - **S11:** Clarified config hot-reload vs restart requirements
    - **S12:** Specified VNC auth mechanism (system username/password)
  - **MINOR FIXES:**
    - **M1-M15:** All minor improvements including: CLI deprecation notes, iCloud FileVault escrow option, install time estimates, Tailscale App Store option, SSH config convenience, cost table hardware, Healthchecks.io setup details, gentler npm cache commands, update channel verification, persistent log strategy, alert frequency, parallel testing recommendation, bash portability, GitHub PAT notes, checklist clarity improvements
  - **Updated:** Version to v5.0, date to June 2026, total time estimate to 4 hours, expanded Phase 6 to 25 min and Phase 8 to 25 min, Phase 10 to 20 min
  - **Enhanced:** Architecture diagram with monitoring approach, cost table with hardware, disaster recovery with auth scenarios, troubleshooting with additional scenarios
- **v5.1 (2026-06-22):**
  - **CRITICAL FIXES:**
    - **C1:** Replace `timeout` command with macOS-compatible alternative in Phase 6.1 (macOS doesn't have GNU timeout)
    - **C2:** Fix alert_kamil function - removed dead `openclaw message send` command, use Telegram API as primary with optional healthchecks.io fallback
    - **C3:** Fix git remote URL in Phase 4.3 - change from SSH to HTTPS, add `git branch -M main`, note about switching to SSH after Phase 8
  - **SIGNIFICANT FIXES:**
    - **S1:** Restructure Node install as conditional flow in Phase 2.5 - present version check and alternatives as equal paths, not buried in warning box
    - **S2:** Add fnm PATH note for launchd - fnm better for dev, recommend brew install for servers with stable absolute paths
    - **S3:** Initialize UPDATE_SUCCESS=false in daily-maintenance.sh to prevent undefined variable checks
    - **S4:** Add workspace commit gap note in Phase 10.2 - commits should be in HEARTBEAT.md or manual until heartbeats configured
    - **S5:** Mark Tailscale Serve config as "verify keys" rather than copy-paste ready
    - **S6:** Fix gateway auth restart note in Phase 8.5 - auth token changes require restart, not hot-reloaded
    - **S7:** Fix Node version constraint - change to "must be >= 22.x.x" with note about newer versions
  - **MINOR FIXES:**
    - **M1:** Tighten pgrep pattern in Phase 5.5 - remove .\* wildcard
    - **M2:** Add version check after rollback in maintenance script
    - **M3:** Remove hedging "(if --deep flag exists)" from Phase 5.3
    - **M4:** Fix cost table - minimum $205 not $255, show as "$205 + $50-100 insurance"
    - **M5:** Fix DR git clone - don't embed PAT in URL, use credential helper note
    - **M6:** Add explicit back-reference from Phase 9.2 to Phase 6.3
    - **M7:** Add note about updating OpenClaw on CC container before migrating (optional but recommended)
