# Mac Mini Full Plan v3 — Architecture, Auth & Strategy

## Current Setup (for reference)

```
Claude Code Remote Container (Anthropic cloud, disposable)
 │
 ├── CC Opus 4.6 (admin, powered by Max sub $200/mo)
 ├── sk-ant-si-* token (4hr JWT, auto-refreshed by CC backend)
 ├── OpenClaw reads token from disk on every API call
 ├── Keepalive hook prevents session timeout
 └── Kai → Telegram → Kamil

⚠️ Session-coupled: CC session ends = token dies = Kai dies
See: cc-remote-container-setup.md for full details
```

## Mac Mini Target Architecture

```
📱 Kamil (anywhere)
 │
 ├── Telegram (primary interface)
 │
 ▼
🖥️ Mac Mini M4 24GB 512GB SSD (always on, Kamil's home)
 │
 ├── UPS (recommended — protects against power outage data corruption)
 │
 ├── launchd (auto-restart on boot/crash)
 │   └── OpenClaw Gateway (daemon, via `openclaw gateway install`)
 │       ├── Telegram plugin (long-polling, no webhook needed)
 │       ├── Cron scheduler
 │       └── Kai (main agent)
 │           ├── SOUL.md, MEMORY.md, workspace/
 │           └── future sub-agents
 │
 ├── Auth: Setup Token (sk-ant-oat01-*) → Max sub ($200/mo flat)
 │   └── Auto-refresh via launchd scheduled task
 │
 ├── Backup: Time Machine (full) + Git repo (workspace)
 │
 ├── Tailscale (optional, secure remote CLI/SSH + uptime monitoring)
 │
 └── Claude Code CLI (dev/debug tool only, NOT runtime)
```

## Key Difference from Current

|                    | Current (CC Remote)        | Mac Mini (Target)                 |
| ------------------ | -------------------------- | --------------------------------- |
| Infrastructure     | Anthropic cloud container  | Your hardware                     |
| Token type         | sk-ant-si-\* (4hr JWT)     | sk-ant-oat01-\* (long-lived)      |
| Token refresh      | CC backend auto-rotates    | Automated script                  |
| Persistence        | Dies with session          | Survives reboots                  |
| Process supervisor | None (container lifecycle) | launchd (auto-restart)            |
| Cost               | $200/mo Max sub            | $200/mo Max sub + ~$5 electricity |

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

### 1.2 Export OpenClaw Config

```bash
cp /root/.openclaw/openclaw.json /tmp/openclaw-config-backup.json
```

This preserves telegram bot token, channel config, and gateway settings.

### 1.3 Note the Telegram Bot Token

The bot token is in `openclaw.json` under `channels.telegram.botToken`. You'll need it on the mac mini. **Only one instance can poll Telegram at a time** — stop the old gateway before starting the new one.

---

## Phase 2: Mac Mini Base Setup

### 2.1 Hardware: UPS (Recommended)

Get a basic UPS (~$50-80). The mac mini is a 24/7 server now — a power outage mid-write can corrupt OpenClaw's SQLite database or auth files. A UPS gives you clean shutdown time.

### 2.2 macOS System Config

**Set timezone first** (affects all scheduled tasks):

```bash
# Check current timezone
sudo systemsetup -gettimezone

# Set timezone (example — use yours)
sudo systemsetup -settimezone "America/Toronto"
```

**Prevent sleep:**

```bash
sudo pmset -a sleep 0
sudo pmset -a disablesleep 1
sudo pmset -a displaysleep 0

# Auto-restart after power failure
sudo pmset -a autorestart 1

# Verify
pmset -g
```

**Also in System Settings:**

- Energy Saver → Prevent automatic sleeping
- Software Update → Disable "Install macOS updates automatically" (prevent surprise reboots)
- Enable automatic login (so it comes back up after power outage without password)

### 2.3 Install Dependencies

```bash
# Install Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install Node.js 22+ and jq (used by scripts)
brew install node@22 jq

# Verify
node --version  # must be >= 22.12.0
```

**Note the install paths — needed for launchd scripts later:**

```bash
which node    # e.g. /opt/homebrew/bin/node
which npm     # e.g. /opt/homebrew/bin/npm
```

### 2.4 Install OpenClaw

```bash
npm install -g openclaw

# Note the path
which openclaw  # e.g. /opt/homebrew/bin/openclaw
```

### 2.5 Install Claude Code CLI

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

### 3.2 Run OpenClaw Onboard

```bash
openclaw onboard --auth-choice setup-token --install-daemon
```

This interactive wizard will:

- Prompt you to paste the setup token
- Configure the gateway
- Set up the Telegram channel (paste your bot token)
- Install the launchd daemon automatically

**Important:** The wizard creates default workspace files (SOUL.md, etc). That's fine — we'll overwrite them with our backup in Phase 4.

### 3.3 Verify Auth

```bash
openclaw models status
```

Check that it shows your Anthropic setup-token profile as active. Use `--check` for automation:

```bash
openclaw models status --check
# Exit 0 = OK
# Exit 1 = expired/missing
# Exit 2 = expiring within 24h
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

### 4.3 Initialize Git for Workspace Persistence

```bash
cd ~/.openclaw/workspace
git init
git add SOUL.md MEMORY.md USER.md IDENTITY.md TOOLS.md AGENTS.md HEARTBEAT.md
git add guides/ memory/
git commit -m "Initial workspace migration from CC container"
```

This gives you version history. Kai can commit specific file changes during heartbeats. **Never use `git add -A`** — only stage specific known files to avoid committing deletions or sensitive data.

---

## Phase 5: Start & Verify

### 5.1 Stop Old Instance

**Critical:** Stop the CC container gateway FIRST. Two instances polling the same Telegram bot = conflict.

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
# General health
openclaw doctor

# Security audit
openclaw security audit

# Fix common security issues
openclaw security audit --fix

# Model auth health
openclaw models status --check
```

### 5.4 Test End-to-End

Send "test" on Telegram. If Kai responds, you're live.

### 5.5 Verify Daemon Persistence

```bash
# Check launchd service
openclaw gateway status

# Test restart recovery
openclaw gateway stop
sleep 10
openclaw gateway status  # should show it restarted automatically
```

---

## Phase 6: Auto Token Refresh

### 6.1 Discover Paths First

These paths vary per system. Run these and note the output:

```bash
echo "HOME: $HOME"
which openclaw   # e.g. /opt/homebrew/bin/openclaw
which claude     # e.g. /opt/homebrew/bin/claude
which jq         # e.g. /opt/homebrew/bin/jq
which curl       # e.g. /usr/bin/curl
```

You'll substitute these into the script and plist below.

### 6.2 The Script

Create `~/.openclaw/scripts/refresh-token.sh`:

**Replace `/opt/homebrew/bin` with your actual paths from 6.1.**

```bash
#!/bin/bash
# Auto-refresh setup token for OpenClaw
# Scheduled via launchd — uses absolute paths (launchd has minimal env)

# === CONFIGURE THESE PATHS ===
OPENCLAW="/opt/homebrew/bin/openclaw"
CLAUDE="/opt/homebrew/bin/claude"
JQ="/opt/homebrew/bin/jq"
CURL="/usr/bin/curl"
OPENCLAW_HOME="$HOME/.openclaw"
# =============================

LOG="$OPENCLAW_HOME/logs/token-refresh.log"
MAX_LOG_SIZE=1048576  # 1MB — rotate when exceeded
mkdir -p "$(dirname "$LOG")"

# Log rotation: truncate if over MAX_LOG_SIZE
if [ -f "$LOG" ] && [ "$(stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt "$MAX_LOG_SIZE" ]; then
    tail -100 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $1" >> "$LOG"; }

alert_kamil() {
    local msg="$1"
    local BOT_TOKEN
    BOT_TOKEN=$($JQ -r '.channels.telegram.botToken // empty' "$OPENCLAW_HOME/openclaw.json" 2>/dev/null)
    if [ -n "$BOT_TOKEN" ]; then
        $CURL -s "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            -d chat_id="455442541" \
            -d text="$msg" \
            > /dev/null 2>&1
    fi
}

log "Starting token refresh check..."

# Check if token is actually expiring (don't refresh if healthy)
$OPENCLAW models status --check 2>/dev/null
STATUS=$?
if [ $STATUS -eq 0 ]; then
    log "Token is healthy (exit 0). Skipping refresh."
    exit 0
fi

log "Token needs refresh (status check exit: $STATUS)"

# Generate new setup token
# NOTE: If this requires browser interaction, auto-refresh won't work.
# In that case, rely on monitoring alerts + manual refresh.
NEW_TOKEN=$($CLAUDE setup-token 2>/dev/null)

if [ -z "$NEW_TOKEN" ]; then
    log "ERROR: Failed to generate new token. Manual refresh needed."
    alert_kamil "⚠️ Kai token refresh failed. Manual refresh needed: run 'claude setup-token' on the mac mini."
    exit 1
fi

# Paste into OpenClaw
echo "$NEW_TOKEN" | $OPENCLAW models auth paste-token --provider anthropic 2>> "$LOG"

# Restart gateway to pick up new creds
$OPENCLAW gateway restart 2>> "$LOG"

# Verify
sleep 5
$OPENCLAW models status --check 2>/dev/null
VERIFY=$?
if [ $VERIFY -eq 0 ]; then
    log "Token refresh successful ✅"
else
    log "ERROR: Token refresh completed but verification failed (exit: $VERIFY)"
    alert_kamil "⚠️ Kai token refresh failed verification. Check logs on mac mini: ~/.openclaw/logs/token-refresh.log"
    exit 1
fi
```

```bash
chmod +x ~/.openclaw/scripts/refresh-token.sh
```

### 6.3 Schedule via launchd

Create `~/Library/LaunchAgents/com.openclaw.token-refresh.plist`:

**Replace `/Users/kamil` with your actual home directory.**

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
launchctl load ~/Library/LaunchAgents/com.openclaw.token-refresh.plist
```

Runs every Monday at 4 AM local time. Checks health first, only refreshes if needed. Alerts you on Telegram if it fails.

### 6.4 Test the Script Manually First

```bash
# Dry run — check what status --check returns
openclaw models status --check; echo "Exit: $?"

# Run the full script
~/.openclaw/scripts/refresh-token.sh

# Check the log
cat ~/.openclaw/logs/token-refresh.log
```

### 6.5 ⚠️ Unknowns to Verify on Mac Mini

Before trusting the auto-refresh:

1. **Does `claude setup-token` work non-interactively?** — Run it and see if it outputs a token without browser interaction
2. **How long do setup tokens actually last?** — Check `openclaw models status` after a week to see expiry
3. **Can you pipe the token to `paste-token`?** — Test: `echo "TOKEN" | openclaw models auth paste-token --provider anthropic`

If `claude setup-token` requires interactive browser auth, the auto-refresh won't work automatically. In that case:

- The script will detect the failure and alert you on Telegram
- Manually run `claude setup-token` when alerted
- Consider a cron reminder via OpenClaw's built-in cron instead

---

## Phase 7: Security Hardening

### 7.1 OpenClaw Security Audit

```bash
openclaw security audit --fix
```

This automatically tightens:

- File permissions on state/config (0o600)
- Gateway auth configuration
- Safe defaults

### 7.2 macOS Firewall

```bash
# Enable firewall
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on

# Block all incoming by default
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setblockall on
```

OpenClaw uses **outbound** connections only (Telegram long-polling, Anthropic API), so blocking all inbound is safe and recommended.

### 7.3 Gateway Auth

Ensure `openclaw.json` has a strong gateway token:

```json
{
  "gateway": {
    "mode": "local",
    "auth": {
      "token": "<strong-random-token>"
    }
  }
}
```

Generate one: `openssl rand -hex 32`

### 7.4 Tailscale (Optional, for Remote Access + Monitoring)

```bash
brew install tailscale
# Follow Tailscale setup, then enable in openclaw:
# gateway.auth.allowTailscale: true
```

Benefits:

- Encrypted remote SSH access to mac mini from anywhere
- Can set up external uptime monitoring (ping a Tailscale IP)
- No ports exposed to the public internet

---

## Phase 8: Backup & Monitoring

### 8.1 Time Machine (Full System Backup)

Enable Time Machine in System Settings. This backs up the entire `~/.openclaw` directory including:

- Auth profiles and tokens
- Session data
- Cron jobs
- Device pairings
- Workspace files

Plug in an external drive or use a NAS. This is your disaster recovery.

### 8.2 Workspace Git (Version History)

For workspace-specific version history, commit periodically:

```bash
cd ~/.openclaw/workspace
git add SOUL.md MEMORY.md USER.md IDENTITY.md TOOLS.md AGENTS.md HEARTBEAT.md
git add guides/ memory/
git commit -m "Workspace update $(date +%Y-%m-%d)"
# Optional: push to a private GitHub/GitLab remote
```

**Never use `git add -A` or `git add .`** — only stage specific files to avoid committing deletions or sensitive data.

### 8.3 Network Down Alerting (Optional)

If home internet drops, Kai goes silent with no way to notify you. Options:

**Option A: External uptime monitor (simplest)**

- Use UptimeRobot (free tier) or similar
- If using Tailscale: monitor the Tailscale IP of the mac mini
- Alerts you via email/SMS when mac mini is unreachable

**Option B: Kai self-reports via cron**

- Set up an OpenClaw cron job that pings you every few hours
- If you stop receiving pings, something is wrong
- Already partially covered by heartbeat system

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
| Tailscale                    | free                                 |
| UptimeRobot                  | free tier                            |
| API fallback budget          | $50-100 (insurance, may not be used) |
| **Total**                    | **~$205-305/mo**                     |

---

## Day 2 Operations

### Updating OpenClaw

```bash
npm update -g openclaw
openclaw gateway restart
```

### Updating Claude Code CLI

```bash
npm update -g @anthropic-ai/claude-code
```

### Checking Logs

```bash
# Gateway logs
openclaw logs

# Token refresh logs
cat ~/.openclaw/logs/token-refresh.log

# launchd service logs
openclaw gateway status --json
```

### Manual Token Refresh

```bash
claude setup-token
openclaw models auth setup-token --provider anthropic --yes
openclaw gateway restart
openclaw models status --check
```

### Troubleshooting Common Issues

| Problem                | Check                            | Fix                                               |
| ---------------------- | -------------------------------- | ------------------------------------------------- |
| Kai not responding     | `openclaw gateway status`        | `openclaw gateway restart`                        |
| Auth errors            | `openclaw models status --check` | Re-run `claude setup-token`                       |
| Telegram not working   | `openclaw doctor`                | Check bot token, ensure only one instance polling |
| Mac mini went to sleep | `pmset -g`                       | Re-run `sudo pmset -a sleep 0`                    |
| After power outage     | `openclaw gateway status`        | launchd should auto-restart; verify with status   |
| Config issues          | `openclaw doctor --yes`          | Auto-fixes safe issues                            |
| Script PATH errors     | `which openclaw`                 | Update paths in refresh-token.sh                  |
| Internet down          | Check router                     | Kai resumes automatically when internet returns   |

### Workspace Backup (periodic)

```bash
cd ~/.openclaw/workspace
git add SOUL.md MEMORY.md USER.md IDENTITY.md TOOLS.md AGENTS.md HEARTBEAT.md
git add guides/ memory/
git commit -m "Workspace update $(date +%Y-%m-%d)"
# Optional: git push origin main
```

---

## Full Checklist

### Pre-Migration

- [ ] Export workspace backup (tar.gz) from current CC container
- [ ] Export openclaw.json config backup
- [ ] Note Telegram bot token
- [ ] Send backups to Kamil via Telegram

### Mac Mini Hardware

- [ ] Get a basic UPS ($50-80) for power protection
- [ ] Connect mac mini to UPS

### Mac Mini OS Setup

- [ ] Set timezone (`sudo systemsetup -settimezone "Your/Timezone"`)
- [ ] Configure sleep prevention (`pmset`)
- [ ] Enable auto-restart after power failure
- [ ] Disable automatic macOS updates
- [ ] Enable automatic login
- [ ] Install Homebrew
- [ ] Install Node.js 22+ and jq (`brew install node@22 jq`)
- [ ] Note install paths (`which node`, `which npm`)

### Install Tools

- [ ] Install OpenClaw (`npm install -g openclaw`) — note path
- [ ] Install Claude Code CLI (`npm install -g @anthropic-ai/claude-code`) — note path

### Auth & Config

- [ ] Generate setup token (`claude setup-token`)
- [ ] Run `openclaw onboard --auth-choice setup-token --install-daemon`
- [ ] Verify auth (`openclaw models status --check`)
- [ ] Add fallback API key (`openclaw models auth add`)

### Migration

- [ ] **Stop old CC container gateway** (critical — telegram conflict)
- [ ] Restore workspace files from backup (overwrites onboard defaults)
- [ ] Restore/merge openclaw.json config (especially bot token + allowFrom)
- [ ] Initialize git repo in workspace (specific files only, not `git add -A`)

### Launch

- [ ] Start gateway (`openclaw gateway start`)
- [ ] Run `openclaw doctor`
- [ ] Run `openclaw security audit --fix`
- [ ] Send test message on Telegram
- [ ] Verify daemon auto-restart (stop → wait 10s → check it comes back)

### Post-Launch: Token Refresh

- [ ] Create `~/.openclaw/scripts/refresh-token.sh` with correct absolute paths
- [ ] `chmod +x` the script
- [ ] Create launchd plist with absolute paths (no $HOME) and PATH env var
- [ ] `launchctl load` the plist
- [ ] Test script manually first
- [ ] Check log output (`~/.openclaw/logs/token-refresh.log`)

### Post-Launch: Backup & Monitoring

- [ ] Enable Time Machine for full `~/.openclaw` backup
- [ ] Optional: Push workspace git to private remote
- [ ] Optional: Install Tailscale for remote access
- [ ] Optional: Set up UptimeRobot or similar for network-down alerts

### Verify Unknowns (first week)

- [ ] Does `claude setup-token` work non-interactively?
- [ ] How long do setup tokens last before expiring?
- [ ] Can token be piped to `paste-token`?
- [ ] Does gateway need full restart or just reload after token change?

---

## Changelog

- **v1:** Basic checklist, pseudocode refresh script
- **v2:** 7 phases, verified CLI commands, launchd plist, security hardening, day 2 ops
- **v3:** Fixed launchd $HOME bug (absolute paths), fixed PATH in launchd env, fixed `git add -A` → specific files, replaced fragile grep with jq for bot token, added UPS recommendation, added log rotation, added network-down alerting options, added timezone setup, clarified Phase 3→4 workspace overwrite, added full ~/.openclaw backup via Time Machine, added Phase 8 (Backup & Monitoring), added script PATH troubleshooting
