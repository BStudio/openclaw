# Mac Mini Full Plan v4 — Architecture, Auth & Strategy

_Last updated: 2026-02-22_

---

## Table of Contents

1. [Architecture](#mac-mini-target-architecture)
2. [Phase 1: Prepare](#phase-1-prepare-before-mac-mini-setup) (~15 min)
3. [Phase 2: Mac Mini Base Setup](#phase-2-mac-mini-base-setup) (~45 min)
4. [Phase 3: Auth Setup](#phase-3-auth-setup) (~15 min)
5. [Phase 4: Migrate Workspace](#phase-4-migrate-workspace) (~10 min)
6. [Phase 5: Start & Verify](#phase-5-start--verify) (~15 min)
7. [Phase 6: Auto Token Refresh](#phase-6-auto-token-refresh) (~20 min)
8. [Phase 7: Security Hardening](#phase-7-security-hardening) (~20 min)
9. [Phase 8: Remote Management](#phase-8-remote-management) (~20 min)
10. [Phase 9: Auto-Update Strategy](#phase-9-auto-update-strategy-openclaw--system) (~20 min)
11. [Phase 10: Backup, Monitoring & Disaster Recovery](#phase-10-backup-monitoring--disaster-recovery) (~15 min)
12. [Risk Assessment](#risk-assessment)
13. [Day 2 Operations](#day-2-operations)
14. [Full Checklist](#full-checklist)

**Estimated total setup time: ~3.5 hours** (first time, careful pace)

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
 │   └── Auto-refresh via launchd scheduled task
 │
 ├── Auto-Update: Daily OpenClaw update with safety checks + rollback
 │   └── Your customizations in ~/.openclaw/ are a separate layer, never touched
 │
 ├── Remote Access: Tailscale (SSH key-only, Screen Sharing, Control UI)
 │
 ├── Backup: Time Machine (full) + Git repo (workspace)
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
│  ~/.openclaw/scripts/ — token refresh, auto-update      │
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
| Token refresh      | CC backend auto-rotates    | Automated script                   |
| Persistence        | Dies with session          | Survives reboots                   |
| Process supervisor | None (container lifecycle) | launchd (auto-restart)             |
| Remote access      | N/A                        | Tailscale (SSH + VNC + Control UI) |
| Disk encryption    | N/A (ephemeral)            | FileVault                          |
| Updates            | N/A                        | Daily auto-update with rollback    |
| Cost               | $200/mo Max sub            | $200/mo Max sub + ~$5 electricity  |

---

## Phase 1: Prepare (Before Mac Mini Setup)

_~15 minutes_

### 1.1 Export Workspace from Current Container

Run on current setup to create a portable backup:

```bash
cd /root/.openclaw/workspace
tar czf /tmp/kai-workspace-backup.tar.gz \
  SOUL.md MEMORY.md USER.md IDENTITY.md \
  TOOLS.md AGENTS.md HEARTBEAT.md \
  guides/ memory/
```

Send to Kamil via Telegram or download. **Do this before the CC session dies.**

### 1.2 Export Full OpenClaw State

```bash
# Config (telegram bot token, channel config, gateway settings)
cp /root/.openclaw/openclaw.json /tmp/openclaw-config-backup.json

# Auth profiles (if any API keys configured)
tar czf /tmp/openclaw-auth-backup.tar.gz \
  /root/.openclaw/agents/*/agent/auth-profiles.json 2>/dev/null || true
```

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

- **General → Software Update** → Disable "Install macOS updates automatically" (we handle updates manually — see Phase 9)
- **Energy** → Prevent automatic sleeping when display is off
- **Lock Screen** → Set "Require password after screen saver begins" to a reasonable time (5 min is a good balance for local + security)
- **Users & Groups → Login Options** → Enable automatic login (so the machine comes back after power outage without a password prompt on the login screen)

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
- FileVault uses hardware-accelerated encryption on Apple Silicon — **zero performance impact**
- After enabling, the drive encrypts in the background (takes a few hours, doesn't interrupt use)

> **Important for automatic login:** FileVault requires a password at boot to unlock the disk. With automatic login enabled, macOS will auto-login after the FileVault unlock screen. This means: after a power outage, you'll see the FileVault unlock screen on the monitor. You can either:
>
> - Enter the password locally (monitor attached)
> - Use `fdesetup authrestart` before rebooting (pre-authorizes the next boot)
> - Accept the trade-off: if power fails and you're remote, you need someone local to enter the password OR pre-authorize via SSH before the outage

For a home server with UPS, this is rarely an issue — the UPS buys time for graceful shutdown/restart.

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

This lets you:

- SSH in for CLI work from any device
- VNC in for full GUI access (useful for browser-based auth flows like `claude setup-token`)
- Both work over local network immediately, and over Tailscale from anywhere (Phase 8)

> **We'll harden SSH with key-only auth in Phase 7.** For now, password auth is fine on local network.

### 2.5 Install Dependencies

```bash
# Install Homebrew (if not already installed)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Follow the post-install instructions Homebrew prints (adds brew to PATH)
# On Apple Silicon, typically:
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"

# Install Node.js (latest LTS, must be 22+) and jq
brew install node jq

# Verify
node --version  # must be >= 22.x.x
```

> **Why `brew install node` and not `node@22`?** Versioned formulas like `node@22` are keg-only in Homebrew — they don't link to PATH automatically and require extra steps. `brew install node` installs the latest version (currently 22.x+ LTS) and links it properly. This matches [OpenClaw's official Node docs](https://docs.openclaw.ai/install/node).

**Pin Node.js version** (prevents accidental major version bumps):

```bash
brew pin node
```

> **Why?** Running `brew upgrade` (to get security patches for other packages) would also upgrade Node — potentially jumping from 22.x to 24.x, which could break OpenClaw. `brew pin node` prevents this while letting everything else upgrade freely. When you're ready to upgrade Node deliberately: `brew upgrade --force node`.

**Note the install paths — needed for launchd scripts later:**

```bash
which node      # e.g. /opt/homebrew/bin/node
which npm       # e.g. /opt/homebrew/bin/npm
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
openclaw onboard --install-daemon
```

This interactive wizard will:

- Prompt for auth setup (select "setup-token" and paste the token from 3.1)
- Configure the gateway
- Set up the Telegram channel (paste your bot token)
- Install the launchd daemon automatically

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

Optional — push to a private remote for off-site backup:

```bash
git remote add origin git@github.com:kamil/kai-workspace.git
git push -u origin main
```

---

## Phase 5: Start & Verify

_~15 minutes_

### 5.1 Stop Old Instance

**Critical:** Stop the CC container gateway FIRST. Two instances polling the same Telegram bot = conflict and message loss.

### 5.2 Start Gateway

If `openclaw onboard --install-daemon` was used, it's already a launchd service:

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
openclaw doctor                    # comprehensive health check + auto-fix
openclaw security audit --fix      # fix common security issues
openclaw security audit --deep     # deeper audit
openclaw models status --check     # model auth health
```

### 5.4 Test End-to-End

Send "test" on Telegram. If Kai responds, you're live. 🎉

### 5.5 Verify Daemon Persistence

```bash
openclaw gateway status

# Test restart recovery
openclaw gateway stop
sleep 10
openclaw gateway status  # should show it restarted automatically
```

### 5.6 Check the Control UI

Open `http://127.0.0.1:18789` in a browser on the Mac Mini. This is OpenClaw's built-in web dashboard for config editing, log viewing, session management, and health monitoring.

---

## Phase 6: Auto Token Refresh

_~20 minutes_

### 6.1 Discover Paths First

```bash
echo "HOME: $HOME"
echo "UID: $(id -u)"
which openclaw   # e.g. /opt/homebrew/bin/openclaw
which claude     # e.g. /opt/homebrew/bin/claude
which jq         # e.g. /opt/homebrew/bin/jq
which curl       # e.g. /usr/bin/curl
```

### 6.2 The Refresh Script

```bash
mkdir -p ~/.openclaw/scripts ~/.openclaw/logs
```

Create `~/.openclaw/scripts/refresh-token.sh`:

**⚠️ Replace all paths with your actual paths from 6.1.**

```bash
#!/bin/bash
# Auto-refresh setup token for OpenClaw
# All paths must be absolute — launchd runs with a minimal environment

set -euo pipefail

# === CONFIGURE THESE ABSOLUTE PATHS ===
OPENCLAW="/opt/homebrew/bin/openclaw"
CLAUDE="/opt/homebrew/bin/claude"
JQ="/opt/homebrew/bin/jq"
CURL="/usr/bin/curl"
OPENCLAW_HOME="/Users/kamil/.openclaw"
# ======================================

LOG="$OPENCLAW_HOME/logs/token-refresh.log"
MAX_LOG_SIZE=1048576  # 1MB
mkdir -p "$(dirname "$LOG")"

# Log rotation
if [ -f "$LOG" ] && [ "$(stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt "$MAX_LOG_SIZE" ]; then
    tail -100 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $1" >> "$LOG"; }

alert_kamil() {
    local msg="$1"
    local BOT_TOKEN
    BOT_TOKEN=$("$JQ" -r '.channels.telegram.botToken // empty' "$OPENCLAW_HOME/openclaw.json" 2>/dev/null)
    if [ -n "$BOT_TOKEN" ]; then
        "$CURL" -s "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            -d chat_id="455442541" \
            -d text="$msg" \
            > /dev/null 2>&1
    fi
}

log "Starting token refresh check..."

# Check if token is actually expiring
"$OPENCLAW" models status --check >> "$LOG" 2>&1
STATUS=$?
if [ $STATUS -eq 0 ]; then
    log "Token is healthy (exit 0). Skipping refresh."
    exit 0
fi

log "Token needs refresh (status check exit: $STATUS)"

# Generate new setup token (stderr to log for debugging)
NEW_TOKEN=$("$CLAUDE" setup-token 2>> "$LOG")

if [ -z "$NEW_TOKEN" ]; then
    log "ERROR: Failed to generate new token. Manual refresh needed."
    alert_kamil "⚠️ Kai token refresh failed. Run 'claude setup-token' on the Mac Mini (SSH or Screen Sharing)."
    exit 1
fi

echo "$NEW_TOKEN" | "$OPENCLAW" models auth paste-token --provider anthropic >> "$LOG" 2>&1
"$OPENCLAW" gateway restart >> "$LOG" 2>&1

sleep 5
"$OPENCLAW" models status --check >> "$LOG" 2>&1
VERIFY=$?
if [ $VERIFY -eq 0 ]; then
    log "Token refresh successful ✅"
else
    log "ERROR: Token refresh completed but verification failed (exit: $VERIFY)"
    alert_kamil "⚠️ Kai token refresh failed verification. SSH in and check: ~/.openclaw/logs/token-refresh.log"
    exit 1
fi
```

```bash
chmod +x ~/.openclaw/scripts/refresh-token.sh
```

### 6.3 Schedule via launchd

Create `~/Library/LaunchAgents/com.openclaw.token-refresh.plist`:

**⚠️ Replace `/Users/kamil` and `/opt/homebrew/bin` with your actual paths.**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.openclaw.token-refresh</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Users/kamil/.openclaw/scripts/refresh-token.sh</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key>
        <integer>1</integer>
        <key>Hour</key>
        <integer>4</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>/Users/kamil/.openclaw/logs/token-refresh-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/kamil/.openclaw/logs/token-refresh-stderr.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>/Users/kamil</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
```

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.openclaw.token-refresh.plist
```

To unload: `launchctl bootout gui/$(id -u)/com.openclaw.token-refresh`

Runs every Monday at 4 AM local time. Checks health first — only refreshes if expiring.

### 6.4 Test Manually First

```bash
openclaw models status --check; echo "Exit: $?"
~/.openclaw/scripts/refresh-token.sh
cat ~/.openclaw/logs/token-refresh.log
```

### 6.5 ⚠️ Unknowns to Verify First Week

1. **Does `claude setup-token` work non-interactively?** If it needs browser auth, the script will detect the failure and alert you. VNC in to run it manually.
2. **How long do setup tokens last?** Check `openclaw models status` after a week.
3. **Can the token be piped to `paste-token`?** Test: `echo "TOKEN" | openclaw models auth paste-token --provider anthropic`

---

## Phase 7: Security Hardening

_~20 minutes_

### 7.1 SSH Key-Only Authentication

Password-based SSH is vulnerable to brute-force attacks. Switch to key-only auth.

**Step 1: Generate SSH key on your PC** (if you don't have one):

```bash
ssh-keygen -t ed25519 -C "kamil@pc"
```

**Step 2: Copy your public key to the Mac Mini:**

```bash
ssh-copy-id kamil@<mac-mini-local-ip>
```

**Step 3: Verify key-based login works:**

```bash
ssh kamil@<mac-mini-local-ip>  # should NOT ask for password
```

**Step 4: Disable password authentication:**

```bash
# On the Mac Mini:
sudo nano /etc/ssh/sshd_config

# Find and change (or add) these lines:
# PasswordAuthentication no
# KbdInteractiveAuthentication no
# UsePAM no
```

Then restart SSH:

```bash
sudo launchctl kickstart -k system/com.openssh.sshd
```

**Step 5: Repeat for phone.** Copy your phone SSH key to the Mac Mini too (Termius, Blink, etc. can generate ed25519 keys).

> **⚠️ Test SSH key login from BOTH devices before disabling password auth.** If you lock yourself out, you'll need the monitor + keyboard.

### 7.2 OpenClaw Security Audit

```bash
openclaw security audit --fix      # auto-fix safe issues
openclaw security audit --deep     # deeper checks
```

### 7.3 macOS Firewall

```bash
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setblockall on
```

OpenClaw uses **outbound** connections only (Telegram long-polling, Anthropic API), so blocking all inbound is safe.

> **Note:** `--setblockall on` blocks ALL incoming connections including AirDrop, AirPlay Receiver, and local network discovery. If you use these features, use `--setallowsigned on` instead. Since this is primarily a server, blocking all is the safer default.

> **Tailscale is not affected** — it uses an encrypted tunnel that works through firewalls.

### 7.4 Gateway Auth

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

Generate one: `openssl rand -hex 32`

---

## Phase 8: Remote Management

_~20 minutes_

### 8.1 Install Tailscale

Tailscale creates an encrypted WireGuard VPN between your devices. Free for personal use (up to 100 devices). No port forwarding, no exposed ports, works from anywhere.

**On the Mac Mini:**

```bash
brew install --cask tailscale

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

### 8.2 Remote Access Methods

**From PC — SSH (CLI):**

```bash
ssh kamil@100.x.y.z       # Tailscale IP
ssh kamil@mac-mini         # MagicDNS (if configured)
```

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
// In openclaw.json
{
  gateway: {
    bind: "loopback",
    tailscale: { mode: "serve" },
    auth: { allowTailscale: true },
  },
}
```

Access via `https://mac-mini.your-tailnet.ts.net/`

### 8.3 Startup Ordering (After Power Outage)

After a power outage, launchd starts services before Wi-Fi/DNS may be ready. OpenClaw handles network unavailability gracefully (retries), but to avoid noisy crash loops in logs:

Create `~/.openclaw/scripts/gateway-start-delay.sh`:

```bash
#!/bin/bash
# Wait for network before starting gateway (launchd helper)
for i in $(seq 1 30); do
    if /sbin/ping -c 1 -W 1 1.1.1.1 >/dev/null 2>&1; then
        exec /opt/homebrew/bin/openclaw gateway run
    fi
    sleep 2
done
# Start anyway after 60s — let OpenClaw handle retries
exec /opt/homebrew/bin/openclaw gateway run
```

```bash
chmod +x ~/.openclaw/scripts/gateway-start-delay.sh
```

> **Note:** This is optional. OpenClaw's Telegram plugin uses long-polling with built-in reconnection — it handles network flaps. The delay script just makes boot-time logs cleaner.

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

### 9.2 The Auto-Update Script

Create `~/.openclaw/scripts/auto-update.sh`:

**⚠️ Replace paths with your actual absolute paths.**

```bash
#!/bin/bash
# Daily OpenClaw auto-update with safety checks and rollback
# Runs via launchd at 5 AM daily

set -euo pipefail

# === CONFIGURE THESE ABSOLUTE PATHS ===
NPM="/opt/homebrew/bin/npm"
OPENCLAW="/opt/homebrew/bin/openclaw"
JQ="/opt/homebrew/bin/jq"
CURL="/usr/bin/curl"
OPENCLAW_HOME="/Users/kamil/.openclaw"
# ======================================

LOG="$OPENCLAW_HOME/logs/auto-update.log"
MAX_LOG_SIZE=2097152  # 2MB
mkdir -p "$(dirname "$LOG")"

# Log rotation
if [ -f "$LOG" ] && [ "$(stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt "$MAX_LOG_SIZE" ]; then
    tail -200 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $1" >> "$LOG"; }

alert_kamil() {
    local msg="$1"
    local BOT_TOKEN
    BOT_TOKEN=$("$JQ" -r '.channels.telegram.botToken // empty' "$OPENCLAW_HOME/openclaw.json" 2>/dev/null)
    if [ -n "$BOT_TOKEN" ]; then
        "$CURL" -s "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            -d chat_id="455442541" \
            -d text="$msg" \
            > /dev/null 2>&1
    fi
}

log "=== Starting auto-update check ==="

# Step 1: Record current version (for rollback)
CURRENT_VERSION=$("$OPENCLAW" --version 2>/dev/null || echo "unknown")
log "Current version: $CURRENT_VERSION"

# Step 2: Check if update is available
LATEST_VERSION=$("$NPM" view openclaw version 2>/dev/null || echo "")
if [ -z "$LATEST_VERSION" ]; then
    log "Failed to check npm registry. Network issue? Skipping."
    exit 0
fi

log "Latest version on npm: $LATEST_VERSION"

if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
    log "Already on latest version. Nothing to do."
    exit 0
fi

log "Update available: $CURRENT_VERSION → $LATEST_VERSION"

# Step 3: Pre-update health check
"$OPENCLAW" models status --check >> "$LOG" 2>&1
PRE_STATUS=$?
log "Pre-update auth status: exit $PRE_STATUS"

# Step 4: Install the update
log "Installing openclaw@latest..."
"$NPM" install -g openclaw@latest >> "$LOG" 2>&1
INSTALL_EXIT=$?

if [ $INSTALL_EXIT -ne 0 ]; then
    log "ERROR: npm install failed (exit $INSTALL_EXIT)"
    alert_kamil "⚠️ OpenClaw auto-update failed during npm install. SSH in and check: ~/.openclaw/logs/auto-update.log"
    exit 1
fi

NEW_VERSION=$("$OPENCLAW" --version 2>/dev/null || echo "unknown")
log "Installed version: $NEW_VERSION"

# Step 5: Run doctor (handles config migrations)
log "Running openclaw doctor..."
"$OPENCLAW" doctor --yes >> "$LOG" 2>&1 || true

# Step 6: Restart gateway
log "Restarting gateway..."
"$OPENCLAW" gateway restart >> "$LOG" 2>&1
sleep 10

# Step 7: Post-update health check
"$OPENCLAW" gateway status >> "$LOG" 2>&1
GATEWAY_OK=$?

"$OPENCLAW" models status --check >> "$LOG" 2>&1
POST_STATUS=$?

if [ $GATEWAY_OK -ne 0 ] || [ $POST_STATUS -eq 1 ]; then
    log "ERROR: Post-update health check failed (gateway: $GATEWAY_OK, auth: $POST_STATUS)"
    log "Rolling back to $CURRENT_VERSION..."

    # Rollback
    "$NPM" install -g "openclaw@$CURRENT_VERSION" >> "$LOG" 2>&1
    "$OPENCLAW" gateway restart >> "$LOG" 2>&1
    sleep 5

    # Verify rollback
    ROLLBACK_VERSION=$("$OPENCLAW" --version 2>/dev/null || echo "unknown")
    log "Rolled back to: $ROLLBACK_VERSION"

    alert_kamil "⚠️ OpenClaw update to $NEW_VERSION failed health checks. Auto-rolled back to $CURRENT_VERSION. Check logs: ~/.openclaw/logs/auto-update.log"
    exit 1
fi

log "Update successful: $CURRENT_VERSION → $NEW_VERSION ✅"
alert_kamil "✅ OpenClaw updated: $CURRENT_VERSION → $NEW_VERSION"
```

```bash
chmod +x ~/.openclaw/scripts/auto-update.sh
```

### 9.3 Schedule Daily Auto-Update

Create `~/Library/LaunchAgents/com.openclaw.auto-update.plist`:

**⚠️ Replace `/Users/kamil` and `/opt/homebrew/bin` with your actual paths.**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.openclaw.auto-update</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Users/kamil/.openclaw/scripts/auto-update.sh</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>5</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>/Users/kamil/.openclaw/logs/auto-update-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/kamil/.openclaw/logs/auto-update-stderr.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>/Users/kamil</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
```

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.openclaw.auto-update.plist
```

**What this does daily at 5 AM:**

1. Checks npm registry for new OpenClaw version
2. If no update → exits silently
3. Records current version (for rollback)
4. Installs update via npm
5. Runs `openclaw doctor --yes` (handles config migrations)
6. Restarts the gateway
7. Runs health checks (gateway status + auth check)
8. If health checks fail → **automatically rolls back** to previous version
9. Alerts you on Telegram (success or failure)

### 9.4 Manual Update (when you want control)

```bash
# Check what's available
npm view openclaw version

# Update manually
npm install -g openclaw@latest
openclaw doctor
openclaw gateway restart
openclaw models status --check

# Or use the installer (also handles Node updates)
curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard
```

**Pin to a specific version** (if latest is broken):

```bash
npm install -g openclaw@2026.2.13
openclaw gateway restart
```

**Switch update channels:**

```bash
openclaw update --channel stable   # default, recommended
openclaw update --channel beta     # cutting edge
```

### 9.5 Node.js Update Strategy

Node.js updates are separate from OpenClaw and require more care:

```bash
# Check current Node version
node --version

# Update Node (when you're ready)
HOMEBREW_NO_AUTO_UPDATE=0 brew upgrade node
openclaw doctor
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

### 9.6 macOS Update Strategy

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
5. If it requires a reboot, the Mac Mini will restart, FileVault will unlock (if you pre-authorized with `sudo fdesetup authrestart`), launchd will start OpenClaw, and Kai comes back.
6. Verify: `ssh kamil@<tailscale-ip> "openclaw gateway status"`

**Security-only updates** (no reboot needed) — apply these promptly:

```bash
sudo softwareupdate --install --recommended --no-scan
```

### 9.7 Claude Code CLI Update Strategy

Update separately from OpenClaw (different package):

```bash
npm install -g @anthropic-ai/claude-code@latest
```

Only matters for the token refresh script (`claude setup-token`). Update monthly or when Anthropic announces changes.

---

## Phase 10: Backup, Monitoring & Disaster Recovery

_~15 minutes_

### 10.1 Time Machine (Full System Backup)

Enable Time Machine in **System Settings → General → Time Machine**.

Backs up the entire `~/.openclaw` directory:

- Auth profiles and tokens
- Session data and history
- Cron jobs and device pairings
- Workspace files
- Gateway config

Plug in an external drive or use a NAS.

### 10.2 Workspace Git

Commit periodically (Kai does this during heartbeats):

```bash
cd ~/.openclaw/workspace
git add SOUL.md MEMORY.md USER.md IDENTITY.md TOOLS.md AGENTS.md HEARTBEAT.md
git add guides/ memory/
git commit -m "Workspace update $(date +%Y-%m-%d)"
```

**Never `git add -A` or `git add .`** — specific files only.

### 10.3 Network Down Alerting

**Option A: UptimeRobot (simplest):**

- Free tier at [uptimerobot.com](https://uptimerobot.com)
- Monitor Mac Mini's Tailscale IP
- Alerts via email/SMS/push when unreachable

**Option B: Tailscale status:**

- The Tailscale app on your phone shows device online/offline
- Quick glance to check

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
- Node.js npm cache (`npm cache clean --force`)

### 10.5 Log Management

OpenClaw writes rolling daily logs to `/tmp/openclaw/openclaw-YYYY-MM-DD.log` (cleared on reboot).

For persistent logs:

```json5
{
  logging: {
    file: "~/.openclaw/logs/gateway.log",
    level: "info",
  },
}
```

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
   openclaw onboard --install-daemon
   ```

3. **Restore workspace from git:**
   ```bash
   cd ~/.openclaw
   git clone git@github.com:kamil/kai-workspace.git workspace
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
   # Re-create refresh-token.sh and auto-update.sh from this guide
   # Or restore from a backup
   ```
6. **Re-install launchd plists:**
   ```bash
   # Copy plists to ~/Library/LaunchAgents/
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.openclaw.token-refresh.plist
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.openclaw.auto-update.plist
   ```
7. **Re-harden (Phase 7):** SSH keys, firewall, FileVault
8. **Re-install Tailscale (Phase 8):** `brew install --cask tailscale`, authenticate
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

1. ✅ Setup token as PRIMARY auth
2. 🔄 API key configured as automatic FALLBACK
3. 💰 Budget $50-100/mo API credits as insurance
4. 🧠 Use Sonnet for routine/sub-agent tasks (cheaper if fallback triggers)
5. 📋 Refresh only when needed (health check first)
6. 🚫 Reasonable usage
7. 🔧 Swapping auth method = one config change
8. 📊 `openclaw models status --check` for early warning

---

## Monthly Cost

| Item                         | Cost                                 |
| ---------------------------- | ------------------------------------ |
| Claude Max sub               | $200                                 |
| Mac Mini electricity         | ~$5                                  |
| UPS (one-time ~$60, then $0) | $0/mo                                |
| Telegram bot                 | free                                 |
| Tailscale                    | free (personal)                      |
| UptimeRobot                  | free tier                            |
| API fallback budget          | $50-100 (insurance, may not be used) |
| **Total**                    | **~$205-305/mo**                     |

---

## Day 2 Operations

### Quick Status Check (remote)

```bash
ssh kamil@<tailscale-ip> "openclaw gateway status && openclaw models status --check && df -h /"
```

### Manual Update

```bash
npm install -g openclaw@latest && openclaw doctor && openclaw gateway restart
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
openclaw logs --follow               # gateway logs
cat ~/.openclaw/logs/auto-update.log # update log
cat ~/.openclaw/logs/token-refresh.log # token refresh log
```

### Remote Access Quick Reference

```bash
ssh kamil@<tailscale-ip>                # CLI
open vnc://<tailscale-ip>              # GUI (from macOS)
# http://<tailscale-ip>:18789          # Control UI (any browser)
```

### Troubleshooting

| Problem                     | Check                              | Fix                                                                   |
| --------------------------- | ---------------------------------- | --------------------------------------------------------------------- |
| Kai not responding          | `openclaw gateway status`          | `openclaw gateway restart`                                            |
| Auth errors                 | `openclaw models status --check`   | `claude setup-token` + `paste-token`                                  |
| Telegram not working        | `openclaw doctor`                  | Check bot token, one instance only                                    |
| Mac Mini sleeping           | `pmset -g`                         | `sudo pmset -a sleep 0`                                               |
| After power outage          | `openclaw gateway status`          | launchd auto-restarts; verify                                         |
| Config issues               | `openclaw doctor`                  | `openclaw doctor --fix`                                               |
| Update broke things         | `~/.openclaw/logs/auto-update.log` | `npm install -g openclaw@<old-version>`                               |
| Disk full                   | `df -h /`                          | `brew cleanup && npm cache clean --force`                             |
| Can't SSH remotely          | Tailscale app on phone             | Check both devices on same tailnet                                    |
| FileVault lock after reboot | Monitor on Mac Mini                | Enter password locally, or pre-authorize: `sudo fdesetup authrestart` |
| Node version mismatch       | `node --version`                   | `brew install node` (check OpenClaw reqs first)                       |

---

## Full Checklist

### Pre-Migration

- [ ] Export workspace backup (tar.gz)
- [ ] Export openclaw.json config backup
- [ ] Export auth profiles backup
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
- [ ] Enable automatic login
- [ ] **Enable FileVault** — save recovery key securely
- [ ] Enable Remote Login (SSH)
- [ ] Enable Screen Sharing (VNC)
- [ ] Install Homebrew
- [ ] Disable Homebrew auto-update (`HOMEBREW_NO_AUTO_UPDATE=1`)
- [ ] Install Node.js and jq (`brew install node jq`)
- [ ] Verify Node >= 22

### Install Tools (~10 min)

- [ ] Install OpenClaw — note path
- [ ] Install Claude Code CLI — note path
- [ ] Note all binary paths (`which openclaw claude node npm jq curl`)

### Auth & Config (~15 min)

- [ ] Generate setup token (`claude setup-token`)
- [ ] Run `openclaw onboard --install-daemon`
- [ ] Verify auth (`--check` and `--probe`)
- [ ] Add fallback API key

### Migration (~10 min)

- [ ] **Stop old CC container gateway**
- [ ] Restore workspace from backup
- [ ] Restore/merge config
- [ ] Init git repo (specific files only)

### Launch (~15 min)

- [ ] Start gateway
- [ ] Run `openclaw doctor`
- [ ] Run `openclaw security audit --fix`
- [ ] Check Control UI at `http://127.0.0.1:18789`
- [ ] Test Telegram
- [ ] Verify daemon auto-restart

### Token Refresh (~10 min)

- [ ] Create `refresh-token.sh` with absolute paths
- [ ] `chmod +x`
- [ ] Create + load launchd plist
- [ ] Test manually

### Security Hardening (~20 min)

- [ ] Generate SSH key on PC
- [ ] Copy to Mac Mini (`ssh-copy-id`)
- [ ] Verify key login works
- [ ] Generate SSH key on phone, copy to Mac Mini
- [ ] Disable SSH password auth
- [ ] Test SSH from both devices after disabling passwords
- [ ] Enable macOS firewall (`--setblockall on`)
- [ ] Verify Tailscale still works after firewall
- [ ] Set strong gateway auth token

### Remote Management (~15 min)

- [ ] Install Tailscale on Mac Mini
- [ ] Install Tailscale on PC + phone
- [ ] Note Mac Mini's Tailscale IP
- [ ] Test SSH via Tailscale from PC
- [ ] Test VNC via Tailscale from PC
- [ ] Test SSH from phone
- [ ] Test Control UI via `http://<tailscale-ip>:18789`
- [ ] Optional: Tailscale Serve for HTTPS

### Auto-Update (~10 min)

- [ ] Create `auto-update.sh` with absolute paths
- [ ] `chmod +x`
- [ ] Create + load launchd plist
- [ ] Test manually: `~/.openclaw/scripts/auto-update.sh`
- [ ] Check log: `cat ~/.openclaw/logs/auto-update.log`

### Backup & Monitoring (~10 min)

- [ ] Enable Time Machine
- [ ] Optional: Push workspace git to private remote
- [ ] Optional: Set up UptimeRobot
- [ ] Optional: Add disk space check to HEARTBEAT.md

### Verify Unknowns (first week)

- [ ] Does `claude setup-token` work non-interactively?
- [ ] How long do setup tokens last?
- [ ] Can token be piped to `paste-token`?
- [ ] Does gateway hot-reload after token change or need restart?
- [ ] Verify auto-update ran successfully (check log next morning)

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
  - **Homebrew version pinning** — `HOMEBREW_NO_AUTO_UPDATE=1` prevents accidental Node major version bumps
  - **Node.js update strategy** — when and when not to update, manual approach
  - **macOS update strategy** — monthly maintenance window approach with pre-authorized FileVault restart
  - **Claude Code CLI update strategy** — separate from OpenClaw, monthly
  - **Startup ordering** — network-wait helper script for clean boot after power outage
  - **Disk space monitoring** — what accumulates, how to clean
  - **Disaster recovery procedure** — full step-by-step rebuild from Time Machine or from scratch
  - **Table of contents** with estimated times per phase
  - **Estimated total setup time** (~3.5 hours)
  - **Expanded checklist** with time estimates per section
