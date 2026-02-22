# Mac Mini Full Plan v2 — Architecture, Auth & Strategy

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
 ├── Backup: Git repo for workspace files
 │
 ├── Tailscale (optional, secure remote CLI/SSH access)
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

### 2.1 macOS System Config

```bash
# Prevent sleep (critical — mac mini must stay awake 24/7)
sudo pmset -a sleep 0
sudo pmset -a disablesleep 1
sudo pmset -a displaysleep 0

# Disable auto-restart after power failure (optional, launchd handles app restart)
# Actually ENABLE auto-restart after power failure:
sudo pmset -a autorestart 1

# Verify
pmset -g
```

**Also in System Settings:**

- Energy Saver → Prevent automatic sleeping
- Software Update → Disable "Install macOS updates automatically" (prevent surprise reboots)
- Enable automatic login (so it comes back up after power outage without password)

### 2.2 Install Dependencies

```bash
# Install Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install Node.js 22+
brew install node@22

# Verify
node --version  # must be >= 22.12.0
```

### 2.3 Install OpenClaw

```bash
npm install -g openclaw

# Verify
openclaw --version
```

### 2.4 Install Claude Code CLI

```bash
npm install -g @anthropic-ai/claude-code

# Verify
claude --version
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

**Or for a non-interactive setup** (if you have the values ready):

```bash
openclaw onboard \
  --non-interactive \
  --auth-choice setup-token \
  --install-daemon \
  --mode local
```

Then paste the token when prompted by:

```bash
openclaw models auth setup-token --provider anthropic --yes
```

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

### 4.1 Restore Workspace Files

```bash
# Extract the backup from Phase 1
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

This gives you version history and a backup mechanism. Kai can commit changes during heartbeats.

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
sleep 5
openclaw gateway status  # should show it restarted automatically
```

---

## Phase 6: Auto Token Refresh

### 6.1 The Script

Create `~/.openclaw/scripts/refresh-token.sh`:

```bash
#!/bin/bash
# Auto-refresh setup token for OpenClaw
# Scheduled via launchd

LOG="$HOME/.openclaw/logs/token-refresh.log"
mkdir -p "$(dirname "$LOG")"

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $1" >> "$LOG"; }

log "Starting token refresh..."

# Check if token is actually expiring (don't refresh if healthy)
openclaw models status --check 2>/dev/null
STATUS=$?
if [ $STATUS -eq 0 ]; then
    log "Token is healthy (exit 0). Skipping refresh."
    exit 0
fi

log "Token needs refresh (status check exit: $STATUS)"

# Generate new setup token
# NOTE: Verify this works non-interactively on your mac mini first!
# If claude setup-token requires interaction, you'll need to refresh manually
NEW_TOKEN=$(claude setup-token 2>/dev/null)

if [ -z "$NEW_TOKEN" ]; then
    log "ERROR: Failed to generate new token. Manual refresh needed."
    # Alert via Telegram bot API directly
    BOT_TOKEN=$(grep -o '"botToken":"[^"]*"' ~/.openclaw/openclaw.json | cut -d'"' -f4)
    if [ -n "$BOT_TOKEN" ]; then
        curl -s "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            -d chat_id="455442541" \
            -d text="⚠️ Kai token refresh failed. Manual refresh needed: run 'claude setup-token' on the mac mini." \
            > /dev/null 2>&1
    fi
    exit 1
fi

# Paste into OpenClaw
echo "$NEW_TOKEN" | openclaw models auth paste-token --provider anthropic 2>> "$LOG"

# Restart gateway to pick up new creds
openclaw gateway restart 2>> "$LOG"

# Verify
sleep 5
openclaw models status --check 2>/dev/null
VERIFY=$?
if [ $VERIFY -eq 0 ]; then
    log "Token refresh successful ✅"
else
    log "ERROR: Token refresh completed but verification failed (exit: $VERIFY)"
    BOT_TOKEN=$(grep -o '"botToken":"[^"]*"' ~/.openclaw/openclaw.json | cut -d'"' -f4)
    if [ -n "$BOT_TOKEN" ]; then
        curl -s "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            -d chat_id="455442541" \
            -d text="⚠️ Kai token refresh failed verification. Check logs: ~/.openclaw/logs/token-refresh.log" \
            > /dev/null 2>&1
    fi
    exit 1
fi
```

```bash
chmod +x ~/.openclaw/scripts/refresh-token.sh
```

### 6.2 Schedule via launchd

Create `~/Library/LaunchAgents/com.openclaw.token-refresh.plist`:

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
        <string>-c</string>
        <string>$HOME/.openclaw/scripts/refresh-token.sh</string>
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
    <string>/tmp/openclaw-token-refresh.stdout</string>
    <key>StandardErrorPath</key>
    <string>/tmp/openclaw-token-refresh.stderr</string>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.openclaw.token-refresh.plist
```

Runs every Monday at 4 AM. Checks health first, only refreshes if needed.

### 6.3 ⚠️ Unknowns to Verify on Mac Mini

Before trusting the auto-refresh:

1. **Does `claude setup-token` work non-interactively?** — Run it and see if it outputs a token without browser interaction, or if it requires a manual login step
2. **How long do setup tokens actually last?** — Check `openclaw models status` after a week to see expiry date
3. **Can you pipe the token to paste-token?** — Test: `echo "TOKEN" | openclaw models auth paste-token --provider anthropic`

If `claude setup-token` requires interactive browser auth, the auto-refresh won't work. In that case: set a weekly reminder to manually run it, and rely on the `--check` monitoring to alert you.

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

OpenClaw uses **outbound** connections (Telegram long-polling, Anthropic API), so blocking inbound is safe and recommended.

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

### 7.4 Tailscale (Optional, for Remote Access)

```bash
brew install tailscale
# Follow Tailscale setup
# Enable in openclaw config:
# gateway.auth.allowTailscale: true
```

This gives you encrypted remote access without exposing ports to the internet.

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

| Item                 | Cost                                 |
| -------------------- | ------------------------------------ |
| Claude Max sub       | $200                                 |
| Mac Mini electricity | ~$5                                  |
| Telegram bot         | free                                 |
| Tailscale            | free                                 |
| API fallback budget  | $50-100 (insurance, may not be used) |
| **Total**            | **~$205-305/mo**                     |

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

### Manual Token Refresh (if auto-refresh doesn't work)

```bash
claude setup-token
openclaw models auth setup-token --provider anthropic --yes
openclaw gateway restart
openclaw models status --check
```

### Troubleshooting Common Issues

| Problem                | Check                            | Fix                                             |
| ---------------------- | -------------------------------- | ----------------------------------------------- |
| Kai not responding     | `openclaw gateway status`        | `openclaw gateway restart`                      |
| Auth errors            | `openclaw models status --check` | Re-run `claude setup-token`                     |
| Telegram not working   | `openclaw doctor`                | Check bot token, ensure only one instance       |
| Mac mini went to sleep | `pmset -g`                       | Re-run `sudo pmset -a sleep 0`                  |
| After power outage     | `openclaw gateway status`        | launchd should auto-restart; verify with status |
| Config issues          | `openclaw doctor --yes`          | Auto-fixes safe issues                          |

### Workspace Backup (periodic)

```bash
cd ~/.openclaw/workspace
git add -A
git commit -m "Workspace update $(date +%Y-%m-%d)"
# Optional: push to private remote
```

---

## Full Checklist

### Pre-Migration

- [ ] Export workspace backup (tar.gz) from current CC container
- [ ] Export openclaw.json config backup
- [ ] Note Telegram bot token
- [ ] Send backups to Kamil via Telegram

### Mac Mini Setup

- [ ] Configure macOS sleep prevention (`pmset`)
- [ ] Enable auto-restart after power failure
- [ ] Disable automatic macOS updates (prevent surprise reboots)
- [ ] Install Homebrew
- [ ] Install Node.js 22+
- [ ] Install OpenClaw (`npm install -g openclaw`)
- [ ] Install Claude Code CLI (`npm install -g @anthropic-ai/claude-code`)

### Auth & Config

- [ ] Generate setup token (`claude setup-token`)
- [ ] Run `openclaw onboard --auth-choice setup-token --install-daemon`
- [ ] Verify auth (`openclaw models status --check`)
- [ ] Add fallback API key (`openclaw models auth add`)

### Migration

- [ ] **Stop old CC container gateway** (critical — telegram conflict)
- [ ] Restore workspace files from backup
- [ ] Restore/merge openclaw.json config (especially bot token + allowFrom)
- [ ] Initialize git repo in workspace

### Launch

- [ ] Start gateway (`openclaw gateway start`)
- [ ] Run `openclaw doctor`
- [ ] Run `openclaw security audit --fix`
- [ ] Send test message on Telegram
- [ ] Verify daemon auto-restart (stop → check it comes back)

### Post-Launch

- [ ] Set up token refresh script + launchd schedule
- [ ] Test auto-refresh script manually first
- [ ] Verify token lifetime (check expiry after 1 week)
- [ ] Optional: Install Tailscale for remote access
- [ ] Optional: Set up Time Machine backup

### Verify Unknowns (first week)

- [ ] Does `claude setup-token` work non-interactively?
- [ ] How long do setup tokens last before expiring?
- [ ] Can token be piped to `paste-token`?
- [ ] Does gateway need full restart or just reload after token change?
