# Mac Mini Full Plan v3.1 — Architecture, Auth & Strategy

_Last updated: 2026-02-22_

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
 ├── Remote Access: Tailscale (SSH, Screen Sharing, Control UI)
 │
 ├── Backup: Time Machine (full) + Git repo (workspace)
 │
 └── Claude Code CLI (dev/debug tool only, NOT runtime)
```

## Key Difference from Current

|                    | Current (CC Remote)        | Mac Mini (Target)                  |
| ------------------ | -------------------------- | ---------------------------------- |
| Infrastructure     | Anthropic cloud container  | Your hardware                      |
| Token type         | sk-ant-si-\* (4hr JWT)     | sk-ant-oat01-\* (long-lived)       |
| Token refresh      | CC backend auto-rotates    | Automated script                   |
| Persistence        | Dies with session          | Survives reboots                   |
| Process supervisor | None (container lifecycle) | launchd (auto-restart)             |
| Remote access      | N/A                        | Tailscale (SSH + VNC + Control UI) |
| Cost               | $200/mo Max sub            | $200/mo Max sub + ~$5 electricity  |

---

## Phase 1: Prepare (Before Mac Mini Setup)

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

### 2.1 Hardware: UPS (Recommended)

Get a basic UPS (~$50-80). The Mac Mini is a 24/7 server now — a power outage mid-write can corrupt OpenClaw's SQLite database or auth files. A UPS gives you clean shutdown time.

### 2.2 macOS System Config

The Mac Mini M4 ships with macOS 15 Sequoia (or later if updated). Check for the latest macOS updates before proceeding.

**Set timezone first** (affects all scheduled tasks including launchd):

```bash
# Check current timezone
sudo systemsetup -gettimezone

# Set timezone (example — use yours)
sudo systemsetup -settimezone "America/Toronto"
```

**Prevent system sleep** (keep machine running 24/7):

```bash
# Prevent system sleep (this is the critical one)
sudo pmset -a sleep 0

# Allow display to sleep after 10 min (saves energy, monitor is there for local use)
sudo pmset -a displaysleep 10

# Auto-restart after power failure
sudo pmset -a autorestart 1

# Verify
pmset -g
```

> **Note:** `disablesleep 1` is for laptops (prevents sleep on lid close). Mac Mini has no lid — `sleep 0` is sufficient.

**Also in System Settings:**

- **General → Software Update** → Disable "Install macOS updates automatically" (prevent surprise reboots — update manually on your schedule)
- **Energy** → Prevent automatic sleeping when display is off
- **Lock Screen** → Set "Require password after screen saver begins" to a reasonable time (not "immediately" if you want easy local access, but not "never" either)
- **Users & Groups → Login Options** → Enable automatic login (so it comes back up after power outage without needing a password on the login screen)

### 2.3 Enable Remote Access (SSH + Screen Sharing)

**Critical for remote management.** Do this early so you can finish the rest remotely if needed.

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
- Both work over local network immediately, and over Tailscale from anywhere (set up in Phase 7)

### 2.4 Install Dependencies

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

**Note the install paths — needed for launchd scripts later:**

```bash
which node      # e.g. /opt/homebrew/bin/node
which npm       # e.g. /opt/homebrew/bin/npm
which jq        # e.g. /opt/homebrew/bin/jq
which curl      # should be /usr/bin/curl
```

### 2.5 Install OpenClaw

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

If you get `EACCES` permission errors, see [OpenClaw Node docs](https://docs.openclaw.ai/install/node) for the fix.

### 2.6 Install Claude Code CLI

```bash
npm install -g @anthropic-ai/claude-code

# Note the path
which claude  # e.g. /opt/homebrew/bin/claude
```

---

## Phase 3: Auth Setup

### 3.1 Generate Setup Token

```bash
claude setup-token
```

This authenticates with your Max subscription and outputs a token. Copy it.

> **⚠️ This may open a browser for authentication.** This is why Screen Sharing (Phase 2.3) is important — if you're setting up remotely, you can VNC in to complete the browser auth flow.

### 3.2 Run OpenClaw Onboard

If you used the installer script (Option A in 2.5), onboarding already ran. Otherwise:

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

Check that it shows your Anthropic setup-token profile as active. Use `--check` for scripting:

```bash
openclaw models status --check
# Exit 0 = OK
# Exit 1 = expired or missing credentials
# Exit 2 = expiring within 24h
```

Use `--probe` for a live verification (makes a real API request):

```bash
openclaw models status --probe
```

### 3.4 Configure Fallback API Key (Insurance)

```bash
openclaw models auth add
# Select: Anthropic API Key
# Paste your ANTHROPIC_API_KEY
```

This gives you a fallback if setup-token ever breaks. OpenClaw will fail over automatically.

---

## Phase 4: Migrate Workspace

### 4.1 Restore Workspace Files (Overwrites Onboard Defaults)

```bash
# Extract the backup from Phase 1 — this overwrites the default files onboard created
cd ~/.openclaw/workspace
tar xzf ~/kai-workspace-backup.tar.gz
```

### 4.2 Restore Config (if needed)

If `openclaw onboard` didn't configure everything, merge settings from your backup:

```bash
# Compare configs
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

This gives you version history. Kai can commit specific file changes during heartbeats.

> **Safety: Never use `git add -A` or `git add .`** — only stage specific known files to avoid committing deletions or sensitive data. See AGENTS.md.

Optional — push to a private remote for off-site backup:

```bash
git remote add origin git@github.com:kamil/kai-workspace.git
git push -u origin main
```

---

## Phase 5: Start & Verify

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
# Comprehensive health check + auto-fix config issues
openclaw doctor

# Security audit
openclaw security audit

# Fix common security issues automatically
openclaw security audit --fix

# Deep security audit (more checks)
openclaw security audit --deep

# Model auth health
openclaw models status --check
```

### 5.4 Test End-to-End

Send "test" on Telegram. If Kai responds, you're live. 🎉

### 5.5 Verify Daemon Persistence

```bash
# Check launchd service
openclaw gateway status

# Test restart recovery — stop it, wait, verify it comes back
openclaw gateway stop
sleep 10
openclaw gateway status  # should show it restarted automatically
```

### 5.6 Check the Control UI

Open `http://127.0.0.1:18789` in a browser on the Mac Mini. This is OpenClaw's built-in web dashboard for:

- Config editing (GUI form + raw JSON editor)
- Log viewing
- Session management
- Health monitoring

This will also be accessible remotely via Tailscale (Phase 7).

---

## Phase 6: Auto Token Refresh

### 6.1 Discover Paths First

These paths vary per system. Run these and note the output — you'll substitute them into the script and plist below:

```bash
echo "HOME: $HOME"
echo "UID: $(id -u)"
which openclaw   # e.g. /opt/homebrew/bin/openclaw
which claude     # e.g. /opt/homebrew/bin/claude
which jq         # e.g. /opt/homebrew/bin/jq
which curl       # e.g. /usr/bin/curl
```

### 6.2 The Refresh Script

Create the scripts directory and script:

```bash
mkdir -p ~/.openclaw/scripts
mkdir -p ~/.openclaw/logs
```

Create `~/.openclaw/scripts/refresh-token.sh`:

**⚠️ Replace all paths below with your actual paths from 6.1.** Every path must be absolute — launchd runs with a minimal environment.

```bash
#!/bin/bash
# Auto-refresh setup token for OpenClaw
# Scheduled via launchd — all paths must be absolute (launchd has minimal env)

set -euo pipefail

# === CONFIGURE THESE ABSOLUTE PATHS ===
OPENCLAW="/opt/homebrew/bin/openclaw"
CLAUDE="/opt/homebrew/bin/claude"
JQ="/opt/homebrew/bin/jq"
CURL="/usr/bin/curl"
OPENCLAW_HOME="/Users/kamil/.openclaw"
# ======================================

LOG="$OPENCLAW_HOME/logs/token-refresh.log"
MAX_LOG_SIZE=1048576  # 1MB — rotate when exceeded
mkdir -p "$(dirname "$LOG")"

# Log rotation: keep last 100 lines when log exceeds MAX_LOG_SIZE
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

# Check if token is actually expiring (don't refresh if healthy)
"$OPENCLAW" models status --check >> "$LOG" 2>&1
STATUS=$?
if [ $STATUS -eq 0 ]; then
    log "Token is healthy (exit 0). Skipping refresh."
    exit 0
fi

log "Token needs refresh (status check exit: $STATUS)"

# Generate new setup token
# NOTE: If this requires browser interaction, auto-refresh won't work.
# The script captures stderr so you can debug failures in the log.
NEW_TOKEN=$("$CLAUDE" setup-token 2>> "$LOG")

if [ -z "$NEW_TOKEN" ]; then
    log "ERROR: Failed to generate new token. Manual refresh needed."
    alert_kamil "⚠️ Kai token refresh failed. Run 'claude setup-token' on the Mac Mini (SSH or Screen Sharing)."
    exit 1
fi

# Paste into OpenClaw
echo "$NEW_TOKEN" | "$OPENCLAW" models auth paste-token --provider anthropic >> "$LOG" 2>&1

# Gateway picks up new creds — restart to be safe
"$OPENCLAW" gateway restart >> "$LOG" 2>&1

# Verify
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

**⚠️ Replace `/Users/kamil` with your actual home directory. Replace `/opt/homebrew/bin` with your actual paths.**

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

**Load with modern launchctl syntax** (macOS 10.10+):

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.openclaw.token-refresh.plist
```

To unload later if needed:

```bash
launchctl bootout gui/$(id -u)/com.openclaw.token-refresh
```

> **Note:** `launchctl load`/`unload` still work but are deprecated and print warnings on modern macOS. Use `bootstrap`/`bootout` instead.

Runs every Monday at 4 AM local time. Checks health first, only refreshes if the token is actually expiring. Alerts you on Telegram if it fails.

### 6.4 Test the Script Manually First

```bash
# Dry run — check what status --check returns
openclaw models status --check; echo "Exit: $?"

# Run the full script
~/.openclaw/scripts/refresh-token.sh

# Check the log
cat ~/.openclaw/logs/token-refresh.log
```

### 6.5 ⚠️ Unknowns to Verify First Week

Before trusting the auto-refresh:

1. **Does `claude setup-token` work non-interactively?** — Run it in a terminal and see if it outputs a token without requiring a browser. If it needs browser auth, the auto-refresh script will detect the failure and alert you via Telegram. You'd then need to SSH/VNC in and run it manually.
2. **How long do setup tokens actually last?** — Check `openclaw models status` after a week to see the expiry timeline.
3. **Can you pipe the token to `paste-token`?** — Test: `echo "YOUR_TOKEN" | openclaw models auth paste-token --provider anthropic`

If `claude setup-token` requires interactive browser auth:

- The script will detect the failure and alert you on Telegram
- VNC in via Tailscale (Phase 7) and run `claude setup-token` manually
- Consider switching the weekly schedule to a Kai cron reminder instead (Kai pings you to refresh)

---

## Phase 7: Remote Management & Security

This is how you manage the Mac Mini from your PC or phone without being physically there.

### 7.1 Install Tailscale (Recommended)

Tailscale creates an encrypted WireGuard VPN between your devices. Free for personal use (up to 100 devices). No port forwarding, no exposed ports, works from anywhere.

**On the Mac Mini:**

```bash
brew install tailscale

# Start Tailscale and authenticate
# This opens a browser to log in to your Tailscale account
open /Applications/Tailscale.app
# Or if installed via brew: tailscale up
```

**On your other devices:**

- **PC (Windows/Mac/Linux):** Install Tailscale from [tailscale.com/download](https://tailscale.com/download)
- **Phone (iOS/Android):** Install the Tailscale app from your app store

Once all devices are on the same Tailscale network (tailnet), they can reach each other securely from anywhere in the world.

**Find your Mac Mini's Tailscale IP:**

```bash
tailscale ip -4  # e.g. 100.x.y.z
```

Or use the MagicDNS hostname (e.g. `mac-mini.your-tailnet.ts.net`).

### 7.2 Remote Access Methods

Once Tailscale is set up, you have multiple ways to manage the Mac Mini remotely:

**From PC — SSH (CLI):**

```bash
ssh kamil@100.x.y.z       # using Tailscale IP
# or
ssh kamil@mac-mini         # using MagicDNS name (if configured)
```

**From PC — Screen Sharing (full GUI):**

- **macOS → macOS:** Finder → Go → Connect to Server → `vnc://100.x.y.z`
- **Windows:** Use a VNC client (RealVNC, TightVNC) → connect to `100.x.y.z:5900`
- **Linux:** `vncviewer 100.x.y.z` or Remmina

**From Phone — SSH:**

- **iOS:** Termius (free), Prompt, or Blink Shell
- **Android:** Termius, JuiceSSH, or ConnectBot
- Connect to your Mac Mini's Tailscale IP

**From Phone — Screen Sharing (full GUI):**

- **iOS:** Screens 5, or any VNC client app
- **Android:** RealVNC Viewer, bVNC

**From anywhere — OpenClaw Control UI:**
Once Tailscale is running, access the OpenClaw dashboard from any device:

```
http://100.x.y.z:18789
```

This gives you config editing, logs, and session management in a browser.

For a more secure setup with HTTPS and Tailscale identity auth:

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

Then access via `https://mac-mini.your-tailnet.ts.net/` — authenticated automatically by Tailscale.

### 7.3 OpenClaw Security Audit

```bash
openclaw security audit --fix
```

This automatically tightens:

- File permissions on state/config (0o600)
- Gateway auth configuration
- DM policy safety
- Safe defaults

Run `--deep` for more thorough checks:

```bash
openclaw security audit --deep
```

### 7.4 macOS Firewall

```bash
# Enable firewall
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on

# Block all incoming by default
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setblockall on
```

OpenClaw uses **outbound** connections only (Telegram long-polling, Anthropic API), so blocking all inbound is safe.

> **Note:** `--setblockall on` blocks ALL incoming connections including AirDrop, AirPlay Receiver, and local network discovery. If you use these features on the Mac Mini, use `--setallowsigned on` instead (allows signed Apple apps) and manually block specific apps. Since this is primarily a server, blocking all incoming is the safer default.

> **Tailscale is not affected** — it uses an encrypted tunnel that works through firewalls.

### 7.5 Gateway Auth

Ensure `openclaw.json` has a strong gateway token (the onboard wizard may have set one):

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

---

## Phase 8: Backup & Monitoring

### 8.1 Time Machine (Full System Backup)

Enable Time Machine in **System Settings → General → Time Machine**. This backs up the entire `~/.openclaw` directory including:

- Auth profiles and tokens
- Session data and history
- Cron jobs
- Device pairings
- Workspace files
- Gateway config

Plug in an external drive or use a NAS. This is your disaster recovery — if anything goes wrong, you can restore the entire state.

### 8.2 Workspace Git (Version History)

For workspace-specific version history, commit periodically:

```bash
cd ~/.openclaw/workspace
git add SOUL.md MEMORY.md USER.md IDENTITY.md TOOLS.md AGENTS.md HEARTBEAT.md
git add guides/ memory/
git commit -m "Workspace update $(date +%Y-%m-%d)"
```

**Never use `git add -A` or `git add .`** — only stage specific files.

### 8.3 Network Down Alerting

If home internet drops, Kai goes silent with no way to notify you. Options:

**Option A: External uptime monitor (simplest):**

- Use [UptimeRobot](https://uptimerobot.com) (free tier) or similar service
- If using Tailscale: monitor the Mac Mini's Tailscale IP
- Alerts you via email/SMS/push when Mac Mini is unreachable

**Option B: Kai self-reports via cron:**

- Set up an OpenClaw cron job that pings you every few hours
- If you stop receiving pings, something is wrong
- Already partially covered by the heartbeat system

**Option C: Tailscale status:**

- The Tailscale app on your phone shows device online/offline status
- Quick glance to see if the Mac Mini is connected

### 8.4 Log Management

OpenClaw writes rolling daily logs to `/tmp/openclaw/openclaw-YYYY-MM-DD.log`.

View logs via CLI:

```bash
openclaw logs --follow  # live tail
```

Or via the Control UI Logs tab.

The token refresh script has its own log rotation (truncates at 1MB). macOS `/tmp` is cleared on reboot, so OpenClaw's logs don't accumulate indefinitely.

If you want persistent logs, configure the log path in `openclaw.json`:

```json5
{
  logging: {
    file: "~/.openclaw/logs/gateway.log",
    level: "info",
  },
}
```

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
2. 🔄 API key configured as automatic FALLBACK (OpenClaw fails over)
3. 💰 Budget $50-100/mo API credits as insurance
4. 🧠 Use Sonnet for routine/sub-agent tasks (cheaper if fallback triggers)
5. 📋 Refresh only when needed (health check first, not blindly)
6. 🚫 Reasonable usage — don't run 10 agents at max throughput 24/7
7. 🔧 Swapping auth method = one config change, not a rebuild
8. 📊 `openclaw models status --check` in monitoring for early warning

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

### Updating OpenClaw

**Preferred (re-run installer — handles everything):**

```bash
curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard
```

**Alternative (manual npm):**

```bash
npm install -g openclaw@latest
openclaw doctor
openclaw gateway restart
openclaw gateway health
```

Or use the Control UI's **Update & Restart** button.

### Updating Claude Code CLI

```bash
npm install -g @anthropic-ai/claude-code@latest
```

### Checking Logs

```bash
# Gateway logs (live tail)
openclaw logs --follow

# Token refresh logs
cat ~/.openclaw/logs/token-refresh.log

# Gateway service status
openclaw gateway status
```

### Manual Token Refresh

```bash
# Generate a new token (may require browser auth — use Screen Sharing if remote)
claude setup-token

# Paste it into OpenClaw
openclaw models auth paste-token --provider anthropic

# Restart gateway to pick up new creds
openclaw gateway restart

# Verify
openclaw models status --check
```

### Remote Access Quick Reference

```bash
# SSH from any Tailscale device
ssh kamil@<mac-mini-tailscale-ip>

# Check Mac Mini status remotely
ssh kamil@<mac-mini-tailscale-ip> "openclaw gateway status && openclaw models status --check"

# Screen Sharing (from macOS)
open vnc://<mac-mini-tailscale-ip>

# Control UI (from any browser)
# http://<mac-mini-tailscale-ip>:18789
```

### Troubleshooting Common Issues

| Problem                | Check                            | Fix                                               |
| ---------------------- | -------------------------------- | ------------------------------------------------- |
| Kai not responding     | `openclaw gateway status`        | `openclaw gateway restart`                        |
| Auth errors            | `openclaw models status --check` | Re-run `claude setup-token` + `paste-token`       |
| Telegram not working   | `openclaw doctor`                | Check bot token, ensure only one instance polling |
| Mac Mini went to sleep | `pmset -g`                       | Re-run `sudo pmset -a sleep 0`                    |
| After power outage     | `openclaw gateway status`        | launchd should auto-restart; verify with status   |
| Config issues          | `openclaw doctor`                | `openclaw doctor --fix` auto-repairs safe issues  |
| Script PATH errors     | `which openclaw` in SSH          | Update absolute paths in refresh-token.sh         |
| Internet down          | Check router / Tailscale app     | Kai resumes automatically when internet returns   |
| Can't SSH remotely     | Check Tailscale app on phone     | Ensure both devices are on same tailnet           |
| Need GUI remotely      | VNC via Tailscale IP             | `vnc://<tailscale-ip>` or VNC app on phone        |

---

## Full Checklist

### Pre-Migration

- [ ] Export workspace backup (tar.gz) from current CC container
- [ ] Export openclaw.json config backup
- [ ] Export auth profiles backup
- [ ] Note Telegram bot token
- [ ] Send backups to Kamil via Telegram

### Mac Mini Hardware

- [ ] Get a basic UPS ($50-80)
- [ ] Connect Mac Mini to UPS
- [ ] Connect monitor (for local access and initial setup)

### Mac Mini OS Setup

- [ ] Set timezone (`sudo systemsetup -settimezone "Your/Timezone"`)
- [ ] Prevent system sleep (`sudo pmset -a sleep 0`)
- [ ] Set display sleep to 10 min (`sudo pmset -a displaysleep 10`)
- [ ] Enable auto-restart after power failure (`sudo pmset -a autorestart 1`)
- [ ] Disable automatic macOS updates (prevent surprise reboots)
- [ ] Enable automatic login
- [ ] **Enable Remote Login (SSH)** in System Settings → Sharing
- [ ] **Enable Screen Sharing (VNC)** in System Settings → Sharing
- [ ] Install Homebrew
- [ ] Install Node.js and jq (`brew install node jq`)
- [ ] Verify Node version >= 22 (`node --version`)
- [ ] Note all install paths (`which node`, `which npm`, `which jq`)

### Install Tools

- [ ] Install OpenClaw (`npm install -g openclaw@latest` or installer script) — note path
- [ ] Install Claude Code CLI (`npm install -g @anthropic-ai/claude-code`) — note path

### Auth & Config

- [ ] Generate setup token (`claude setup-token`)
- [ ] Run `openclaw onboard --install-daemon`
- [ ] Verify auth (`openclaw models status --check` and `--probe`)
- [ ] Add fallback API key (`openclaw models auth add`)

### Migration

- [ ] **Stop old CC container gateway** (critical — Telegram conflict)
- [ ] Restore workspace files from backup (overwrites onboard defaults)
- [ ] Restore/merge openclaw.json config (especially bot token + allowFrom)
- [ ] Initialize git repo in workspace (specific files only)

### Launch

- [ ] Start gateway (`openclaw gateway start`)
- [ ] Run `openclaw doctor`
- [ ] Run `openclaw security audit --fix`
- [ ] Open Control UI (`http://127.0.0.1:18789`) and verify config
- [ ] Send test message on Telegram
- [ ] Verify daemon auto-restart (stop → wait 10s → check it comes back)

### Remote Management (Tailscale)

- [ ] Install Tailscale on Mac Mini (`brew install tailscale`)
- [ ] Authenticate Tailscale (log in to your account)
- [ ] Install Tailscale on PC
- [ ] Install Tailscale on phone
- [ ] Note Mac Mini's Tailscale IP (`tailscale ip -4`)
- [ ] Test SSH from PC via Tailscale IP
- [ ] Test Screen Sharing from PC via Tailscale IP
- [ ] Test SSH from phone via Tailscale
- [ ] Test Control UI access from PC via `http://<tailscale-ip>:18789`
- [ ] Optional: Configure Tailscale Serve for HTTPS Control UI access

### Post-Launch: Token Refresh

- [ ] Create `~/.openclaw/scripts/refresh-token.sh` with correct absolute paths
- [ ] `chmod +x` the script
- [ ] Create launchd plist with absolute paths and PATH env var
- [ ] Load plist with `launchctl bootstrap gui/$(id -u) <plist-path>`
- [ ] Test script manually first
- [ ] Check log output (`~/.openclaw/logs/token-refresh.log`)

### Post-Launch: Backup & Monitoring

- [ ] Enable Time Machine for full `~/.openclaw` backup
- [ ] Optional: Push workspace git to private remote
- [ ] Optional: Set up UptimeRobot for network-down alerts

### Verify Unknowns (first week)

- [ ] Does `claude setup-token` work non-interactively? (or needs browser)
- [ ] How long do setup tokens last before expiring?
- [ ] Can token be piped to `paste-token`?
- [ ] Is `openclaw gateway restart` needed after token change or does hot-reload pick it up?

### macOS Firewall (after everything works)

- [ ] Enable firewall (`socketfilterfw --setglobalstate on`)
- [ ] Block all incoming (`socketfilterfw --setblockall on`)
- [ ] Verify Tailscale + OpenClaw still work after enabling firewall

---

## Changelog

- **v1:** Basic checklist, pseudocode refresh script
- **v2:** 7 phases, verified CLI commands, launchd plist, security hardening, day 2 ops
- **v3:** Fixed launchd `$HOME` bug (absolute paths), fixed PATH in launchd env, fixed `git add -A` → specific files, replaced fragile grep with jq for bot token, added UPS recommendation, added log rotation, added network-down alerting options, added timezone setup, clarified Phase 3→4 workspace overwrite, added full ~/.openclaw backup via Time Machine
- **v3.1 (2026-02-22):**
  - Fixed `brew install node@22` keg-only issue → use `brew install node` per OpenClaw official docs
  - Fixed deprecated `launchctl load` → use `launchctl bootstrap gui/$(id -u)`
  - Fixed inconsistent manual token refresh (Day 2) → standardized on `paste-token`
  - Fixed `displaysleep 0` → `displaysleep 10` (monitor attached, display can sleep)
  - Fixed refresh script suppressing stderr → now redirects to log for debugging
  - Removed unnecessary `disablesleep 1` (only for laptops, Mac Mini has no lid)
  - Added SSH + Screen Sharing setup (Phase 2.3) for remote access from day one
  - Added comprehensive Remote Management section (Phase 7) with Tailscale
  - Added PC and phone remote access methods (SSH, VNC, Control UI)
  - Added OpenClaw installer script as recommended install option
  - Added Tailscale Serve for secure HTTPS Control UI access
  - Added note about `--setblockall on` disabling AirDrop/AirPlay
  - Added `openclaw models status --probe` for live auth verification
  - Added log management section (Phase 8.4)
  - Added remote access quick reference to Day 2 operations
  - Expanded troubleshooting table with remote access scenarios
  - Verified all CLI commands against OpenClaw docs (2026-02-22)
  - Updated checklist with remote management and firewall ordering
