# Mac Mini Setup Script — Plan v1.2

_Companion to: Mac Mini Full Plan v5.2_
_Automates 14-phase migration onto a brand new Mac Mini M4_

---

## Goal

A single bash script (`mac-mini-setup.sh`) that takes a fresh Mac Mini from unboxing to a fully operational OpenClaw gateway with Kai running. Minimizes manual steps while being honest about what requires human interaction.

---

## Design Principles

1. **Idempotent** — every phase checks before acting. safe to re-run at any point.
2. **Resumable** — if interrupted (reboot, error, lunch break), re-run picks up where it left off.
3. **No hidden magic** — every action is logged and explained. user can read the script and understand what it does.
4. **Fail safe** — errors stop the current phase with a clear message. never leaves system in a broken state.
5. **Zero dependencies** — runs on stock macOS with only bash and `/usr/bin/curl`. installs everything it needs.
6. **Config at the top** — all customization in one place. edit once, run once.

---

## Getting the Script onto the Mac Mini

The script must exist on the machine before anything is installed. Stock macOS has `/usr/bin/curl`, so:

**Option A: Download from GitHub (recommended)**

```bash
curl -fsSL https://raw.githubusercontent.com/kamil/kai-workspace/main/guides/mac-mini-setup.sh -o ~/mac-mini-setup.sh
chmod +x ~/mac-mini-setup.sh
```

**Option B: AirDrop from phone/PC**
AirDrop the file, then `chmod +x` in Terminal.

**Option C: Copy-paste into Terminal**

```bash
cat > ~/mac-mini-setup.sh << 'SCRIPT_EOF'
# <paste entire script>
SCRIPT_EOF
chmod +x ~/mac-mini-setup.sh
```

**Option D: USB drive**
Copy to USB, plug in, drag to Desktop, `chmod +x`.

---

## Prerequisites (before running the script)

The user must have:

1. ✅ A Mac Mini M4 with macOS booted and initial setup complete (Apple ID, user account created)
2. ✅ **All pending macOS software updates applied** (System Settings → Software Update — do this before running the script)
3. ✅ Internet connection (Wi-Fi or Ethernet)
4. ✅ Admin user account (the one they'll run OpenClaw under)
5. ✅ **Old CC container gateway stopped** (run `openclaw gateway stop` on old machine first)
6. ✅ Workspace backup file downloaded to ~/Downloads/ (see "Backup Creation" below)
7. ✅ Config backup file downloaded to ~/Downloads/ (optional — script can create fresh config)
8. ✅ Telegram bot token available (from @BotFather or existing config backup)
9. ✅ Setup token ready — obtain from `claude setup-token` on current machine, or from Anthropic dashboard
10. ✅ Anthropic API key available (fallback — from console.anthropic.com)
11. ✅ UPS connected via USB (recommended, not required)

### Backup Creation (run on OLD machine before migration)

These commands must be run on the current CC container / old machine. The script does NOT create these — they must already exist.

**Workspace backup:**

```bash
cd /root/.openclaw/workspace
tar czf /tmp/kai-workspace-backup.tar.gz \
  SOUL.md MEMORY.md USER.md IDENTITY.md \
  TOOLS.md AGENTS.md HEARTBEAT.md \
  guides/ memory/
# Send to Telegram or download to ~/Downloads/ on the Mac Mini
```

**Config + auth backup (Option A — clean migration, recommended):**

```bash
cp /root/.openclaw/openclaw.json /tmp/openclaw-config-backup.json
tar czf /tmp/openclaw-auth-backup.tar.gz \
  /root/.openclaw/agents/*/agent/auth-profiles.json \
  /root/.openclaw/credentials/ 2>/dev/null || true
```

**The tar structure matters:** The workspace tar contains files at the TOP level (SOUL.md, guides/, etc.) — NOT wrapped in a `workspace/` directory. The extraction command in Phase 7.2 is `cd ~/.openclaw/workspace && tar xzf ...` so the files land in the right place.

> **Security note:** Delete the auth backup from Telegram after downloading — no need to leave secrets in chat history.

---

## Config Section

```bash
# === EDIT BEFORE RUNNING ===

# System
TIMEZONE="America/Toronto"
COMPUTER_NAME="mac-mini"          # sets hostname + Bonjour name

# Backups (from migration prep — must be created on OLD machine first)
# See "Backup Creation" section above for how to create these
WORKSPACE_BACKUP="$HOME/Downloads/kai-workspace-backup.tar.gz"
CONFIG_BACKUP="$HOME/Downloads/openclaw-config-backup.json"

# Telegram
TELEGRAM_BOT_TOKEN=""             # if empty: reads from config backup, or prompts
TELEGRAM_CHAT_ID="455442541"

# Auth
# Setup token: obtain via `claude setup-token` on current machine before migrating
# If empty, script prompts interactively during Phase 6
SETUP_TOKEN=""
ANTHROPIC_API_KEY=""              # fallback API key, prompted if empty

# Git (for workspace disaster recovery — REQUIRED, not optional)
GITHUB_REPO=""                    # e.g. "https://github.com/kamil/kai-workspace.git"
                                  # if empty: local git only, script warns

# Gateway
GATEWAY_TOKEN=""                  # auto-generated (openssl rand -hex 32) if empty

# Monitoring (optional — set up at healthchecks.io first, get the ping URL)
HEALTHCHECKS_PING_URL=""          # e.g. "https://hc-ping.com/your-uuid-here"
                                  # if empty: maintenance script skips health ping

# Maintenance
MAINTENANCE_HOUR=4                # 4 AM local time
MAINTENANCE_MINUTE=0

# ============================
```

---

## Phase Breakdown

### Phase 0: Pre-flight Checks

**Purpose:** Validate environment before doing anything.

**Checks:**

- macOS version >= 15 (Sequoia) — `sw_vers -productVersion`
- Running as regular user (not root)
- User has admin privileges (`groups | grep admin`)
- Internet connectivity (`/usr/bin/curl -fsS --max-time 5 https://apple.com`)
- Config section has been edited (sentinel check — e.g. TIMEZONE isn't "EDIT_ME")
- Backup files exist at declared paths (if paths are non-empty)

**If any fail:** print clear error, exit.

**Idempotency:** Always runs (fast checks).

**Note:** We do NOT check for an existing OpenClaw gateway here — OpenClaw may not be installed yet. That check happens in Phase 8 before starting the new gateway.

### Phase 1: System Configuration

**Purpose:** Configure macOS for 24/7 server use.

**Actions:**
| Action | Command | Idempotent check |
|---|---|---|
| Set computer name | `sudo scutil --set ComputerName/HostName/LocalHostName` | `scutil --get ComputerName` matches |
| Set timezone | `sudo systemsetup -settimezone "$TIMEZONE"` | `systemsetup -gettimezone` matches |
| Disable system sleep | `sudo pmset -a sleep 0` | `pmset -g \| grep " sleep" = 0` |
| Display sleep 10min | `sudo pmset -a displaysleep 10` | `pmset -g \| grep displaysleep = 10` |
| Auto-restart on power loss | `sudo pmset -a autorestart 1` | `pmset -g \| grep autorestart = 1` |
| Wake on LAN | `sudo pmset -a womp 1` | `pmset -g \| grep womp = 1` |
| Disable Power Nap | `sudo pmset -a powernap 0` | `pmset -g \| grep powernap = 0` |
| Disable auto macOS updates | `sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false` | `defaults read` check |
| Keep RSR on | `sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool true` | already default |

**Interactive:** No. All CLI.

**Needs sudo:** Yes (prompts once at start, subsequent sudo calls use cached credentials).

### Phase 2: FileVault

**Purpose:** Enable full-disk encryption.

**Idempotent check:** `fdesetup status` shows "FileVault is On" (or encryption in progress)

**If not enabled:**

1. Print warning about what FileVault does (disables auto-login, needs password on boot)
2. Run `sudo fdesetup enable`
3. **⏸️ PAUSE** — fdesetup prompts for password and outputs recovery key
4. Print: "SAVE YOUR RECOVERY KEY NOW. Store it in a password manager or print it. Do NOT store it on this Mac."
5. Wait for Enter
6. Verify: `fdesetup status`

**Edge cases:**

- FileVault encryption takes time in background (faster on M4 with hardware encryption, but still not instant). Script doesn't wait — continues with next phase.
- If encryption is already in progress (interrupted previous run), `fdesetup status` shows progress. Script treats this as "on" and continues.

### Phase 3: Remote Access

**Purpose:** Enable SSH and Screen Sharing for remote management.

**Actions:**

**Enable SSH:**

```bash
sudo systemsetup -setremotelogin on
```

Idempotent check: `sudo systemsetup -getremotelogin`

**Enable Screen Sharing:**

```bash
# launchctl bootstrap is the modern equivalent (launchctl load is deprecated)
sudo launchctl bootstrap system/ /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true
```

Idempotent check: `launchctl print system/com.apple.screensharing 2>/dev/null`

If `launchctl bootstrap` fails (some Sequoia builds), fall back to GUI instructions:

```
⚠️ Automatic Screen Sharing setup failed.
   Enable manually: System Settings → General → Sharing → Screen Sharing → ON
   Press Enter when done...
```

**Print SSH host fingerprint** (so user can verify on first connection):

```bash
ssh-keygen -l -f /etc/ssh/ssh_host_ed25519_key.pub
```

Print: "When you first SSH from another device, verify this fingerprint matches."

**Security note:** SSH is enabled with password auth at this point. This is intentional — we need remote access before keys are set up. The window of exposure is limited to the local network (Tailscale isn't installed yet, no ports are forwarded). Password auth is disabled in Phase 11 after keys are configured.

**Interactive:** No (except sudo). Possible manual fallback for Screen Sharing.

### Phase 4: Dependencies

**Purpose:** Install Homebrew, jq, Node.js, GitHub CLI.

**Sub-steps (ORDER MATTERS — jq must come before Node for version check):**

**4.1 Xcode Command Line Tools**

- Check: `xcode-select -p &>/dev/null`
- Install: `xcode-select --install`
- **⏸️ PAUSE** — macOS shows a dialog, downloads ~2GB. Script waits with: "Press Enter after Xcode CLT finishes installing..."
- Verify: `xcode-select -p`

> **Note:** `xcode-select --install` shows a GUI dialog. This requires physical access to the Mac Mini (or VNC, which may not work yet if Screen Sharing setup in Phase 3 needed manual fallback). The prerequisites state the user should be physically present for initial setup.

**4.2 Homebrew**

- Check: `command -v brew`
- Install: `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`
- **⏸️ PAUSE** — Homebrew prompts for password and Enter
- Post-install: add to PATH (`eval "$(/opt/homebrew/bin/brew shellenv)"` + append to `~/.zprofile`)
- Verify: `brew --version`

**4.3 jq (MUST come before Node)**

- Check: `command -v jq`
- Install: `brew install jq`
- Verify: `jq --version`

**4.4 Node.js (uses jq for version check)**

- Check: `command -v node && node -v`
- Version logic:
  ```bash
  # jq is already installed (4.3) — safe to use
  BREW_NODE_VER=$(brew info --json=v2 node | jq -r '.formulae[0].versions.stable')
  if [[ "$BREW_NODE_VER" == 22.* ]]; then
      brew install node
      NODE_FORMULA="node"
  else
      echo "Homebrew's default Node is $BREW_NODE_VER — using node@22 instead"
      brew install node@22
      # node@22 is keg-only — add to PATH
      echo 'export PATH="/opt/homebrew/opt/node@22/bin:$PATH"' >> ~/.zprofile
      source ~/.zprofile
      NODE_FORMULA="node@22"
  fi
  brew pin $NODE_FORMULA
  ```
- Verify: `node --version` is 22.x

**4.5 GitHub CLI (conditional on GITHUB_REPO)**

- **Only if `GITHUB_REPO` is non-empty:**
  - Check: `command -v gh`
  - Install: `brew install gh`
  - Auth: `gh auth login` — **⏸️ PAUSE** (browser auth)
- **If `GITHUB_REPO` is empty:**
  - Skip with warning: "No GITHUB_REPO configured. Workspace disaster recovery will depend on Time Machine only."

**Path recording:** After all installs, record detected paths:

```bash
NODE_PATH=$(command -v node)
NPM_PATH=$(command -v npm)
JQ_PATH=$(command -v jq)
CURL_PATH=$(command -v curl)  # /usr/bin/curl
```

These are used later to generate the maintenance script.

### Phase 5: Install Tools

**Purpose:** Install OpenClaw and Claude Code CLI.

**5.1 OpenClaw**

- Check: `command -v openclaw`
- Install: `npm install -g openclaw@latest`
- Record: `OPENCLAW_PATH=$(command -v openclaw)`
- Verify: `openclaw --version`

**5.2 Claude Code CLI (needed for setup-token management)**

- Check: `command -v claude`
- Install: `npm install -g @anthropic-ai/claude-code`
- Record: `CLAUDE_PATH=$(command -v claude)`
- Verify: `claude --version`

> **Why Claude Code CLI?** It's used for `claude setup-token` which generates/refreshes the auth token for the Max subscription. It's not used at runtime — only for token management. If you don't plan to use setup-token auth (API key only), this can be skipped, but the daily maintenance script won't be able to auto-refresh tokens.

### Phase 6: Auth Setup

**Purpose:** Configure Anthropic auth (setup-token + fallback API key).

**6.1 Setup Token**

**If `SETUP_TOKEN` is set in config section:**

- Pipe directly: `echo "$SETUP_TOKEN" | openclaw models auth paste-token --provider anthropic`

**If `SETUP_TOKEN` is empty:**

1. Print: "We need to set up authentication. This may open a browser."
2. **⏸️ PAUSE** — "Press Enter when ready..."
3. Test if `claude setup-token` works non-interactively (critical — determines if automation is possible later):
   ```bash
   # macOS-compatible timeout test (no GNU timeout)
   claude setup-token 2>/dev/null &
   PID=$!
   sleep 15
   if kill -0 $PID 2>/dev/null; then
       kill $PID 2>/dev/null
       wait $PID 2>/dev/null
       echo "⚠️ setup-token needs browser auth (timed out). Running interactively..."
       echo "Complete the browser flow, then copy the token output."
       claude setup-token
   else
       wait $PID
       echo "✅ setup-token worked non-interactively. Daily auto-refresh will work."
   fi
   ```
4. Capture output → `openclaw models auth paste-token --provider anthropic`
5. Record result of interactivity test for Phase 9 logging

**Edge case:** If `claude setup-token` fails entirely (network issue, auth expired), fall through to 6.2. If both 6.1 and 6.2 fail: **FATAL** — can't continue.

**6.2 Fallback API Key**

- If `ANTHROPIC_API_KEY` is set in config: pipe to `openclaw models auth add`
- If empty: prompt interactively
- If user skips both 6.1 and 6.2: **FATAL** — script exits with clear message

**6.3 Verify Auth**

```bash
openclaw models status --check
# Exit 0 = OK, Exit 1 = expired/missing, Exit 2 = expiring within 24h
```

- If exit 0 or 2: continue
- If exit 1 and BOTH auth methods were attempted: FATAL

**6.4 Live Verification**

```bash
openclaw models status --probe
```

Makes a real API call to verify auth works end-to-end. Tiny cost, worth the confidence.

### Phase 7: Config & Workspace

**Purpose:** Write OpenClaw config, restore workspace, init git.

**7.1 Generate openclaw.json**

Strategy: if CONFIG_BACKUP exists and is valid JSON, start from that. Otherwise generate fresh.

Fresh config template (reflects current working config as of 2026-06-22):

```json
{
  "agents": {
    "defaults": {
      "compaction": {
        "reserveTokensFloor": 16000,
        "maxHistoryShare": 0.7
      },
      "contextPruning": {
        "mode": "cache-ttl",
        "ttl": "10m",
        "keepLastAssistants": 2,
        "softTrimRatio": 0.6,
        "hardClearRatio": 0.8,
        "minPrunableToolChars": 500
      }
    }
  },
  "channels": {
    "telegram": {
      "enabled": true,
      "botToken": "$TELEGRAM_BOT_TOKEN",
      "dmPolicy": "allowlist",
      "allowFrom": ["$TELEGRAM_CHAT_ID"],
      "groupPolicy": "allowlist",
      "streamMode": "partial"
    }
  },
  "gateway": {
    "mode": "local",
    "auth": {
      "token": "$GATEWAY_TOKEN"
    }
  },
  "hooks": {
    "internal": {
      "enabled": true
    }
  },
  "commands": {
    "native": "auto",
    "nativeSkills": "auto"
  }
}
```

If CONFIG_BACKUP exists:

- Copy to `~/.openclaw/openclaw.json`
- Merge/ensure critical fields present (gateway token, compaction, contextPruning, hooks.internal)
- Update `reserveTokensFloor` to 16000 if lower

**7.2 Restore Workspace**

If WORKSPACE_BACKUP exists:

```bash
cd ~/.openclaw/workspace
tar xzf "$WORKSPACE_BACKUP"
```

> **Tar structure assumption:** The backup tar contains files at the TOP level (SOUL.md, guides/, memory/, etc.) — NOT wrapped in a `workspace/` directory. If the tar was created with `tar czf backup.tar.gz -C ~/.openclaw/workspace .` or by listing files explicitly (as shown in Backup Creation section), extraction in `~/.openclaw/workspace/` places files correctly.

**Validation after extraction:**

```bash
if [ ! -f ~/.openclaw/workspace/SOUL.md ]; then
    echo "⚠️ SOUL.md not found after extraction."
    echo "The tar may have a different structure. Checking..."
    # Look for nested workspace/ directory
    if [ -f ~/.openclaw/workspace/workspace/SOUL.md ]; then
        echo "Found nested workspace/. Fixing..."
        mv ~/.openclaw/workspace/workspace/* ~/.openclaw/workspace/
        rmdir ~/.openclaw/workspace/workspace
    else
        echo "⚠️ Workspace backup may be empty or corrupt. Continuing with defaults."
    fi
fi
```

If WORKSPACE_BACKUP doesn't exist: warn, continue with default workspace from onboard.

**7.3 Git Init**

- Check: `cd ~/.openclaw/workspace && git rev-parse --is-inside-work-tree 2>/dev/null`
- If not a git repo:
  ```bash
  git init
  git add SOUL.md MEMORY.md USER.md IDENTITY.md TOOLS.md AGENTS.md HEARTBEAT.md
  git add guides/ memory/ 2>/dev/null || true
  git branch -M main
  git commit -m "Initial workspace migration"
  ```

**7.4 Git Remote**

- If GITHUB_REPO is set:
  ```bash
  git remote add origin "$GITHUB_REPO" 2>/dev/null || git remote set-url origin "$GITHUB_REPO"
  git push -u origin main || {
      echo "⚠️ Git push failed. Check your GitHub auth (gh auth login) and repo URL."
      echo "You can fix this later. Continuing..."
  }
  ```
  Note: uses HTTPS (SSH keys don't exist yet — those come in Phase 11). After Phase 11, user can switch to SSH: `git remote set-url origin git@github.com:kamil/kai-workspace.git`
- If GITHUB_REPO empty: warn "No git remote configured. DR depends on Time Machine only. This is risky."

### Phase 8: Gateway Start & Verify

**Purpose:** Install daemon, start gateway, verify everything works.

**8.0 Pre-check: No conflicting gateway**

```bash
if pgrep -x "openclaw" > /dev/null 2>&1; then
    echo "⚠️ An OpenClaw process is already running on this machine."
    echo "This may conflict with the new gateway. Stop it first?"
    # PAUSE for user decision
fi
```

**8.1 Install Daemon**

- `openclaw gateway install`

**8.2 Start Gateway**

- `openclaw gateway start`
- Wait 10 seconds
- `openclaw gateway status` — verify running

**8.3 Run Doctor**

- `openclaw doctor --non-interactive`

**8.4 Test Telegram**

> **If using a NEW bot token** (fresh from @BotFather), the user must `/start` the bot in Telegram first. Otherwise the bot can't send messages to the chat. Print this reminder.

Send test message via Telegram API:

```bash
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
  --data-urlencode "text=🎉 Kai is live on the Mac Mini! Setup script Phase 8 complete." \
  -o /dev/null -w "%{http_code}"
```

- If HTTP 200: "✅ Telegram message sent. Check your phone."
- If HTTP 403 or 400: "⚠️ Telegram API returned an error. If this is a new bot, make sure you've sent /start to it first."

Print: "Reply to the bot to verify two-way communication. Press Enter when confirmed..."
**⏸️ PAUSE**

**8.5 Verify Daemon Persistence**

Test that launchd restarts the gateway after a crash:

```bash
# Get the exact PID of the gateway process
GATEWAY_PID=$(pgrep -x "node" -f "openclaw" | head -1)
if [ -n "$GATEWAY_PID" ]; then
    kill -9 "$GATEWAY_PID"  # SIGKILL = simulate crash (not graceful stop)
    sleep 10
    openclaw gateway status  # should show it restarted
else
    echo "⚠️ Could not find gateway PID. Verify manually: openclaw gateway status"
fi
```

### Phase 9: Maintenance Automation

**Purpose:** Generate maintenance script and launchd plist using detected paths.

**9.1 Generate daily-maintenance.sh**

Template with paths filled in from Phase 4/5 detection:

```
OPENCLAW="$OPENCLAW_PATH"
CLAUDE="$CLAUDE_PATH"
NPM="$NPM_PATH"
JQ="$JQ_PATH"
CURL="$CURL_PATH"
OPENCLAW_HOME="$HOME/.openclaw"
HEALTHCHECKS_URL="$HEALTHCHECKS_PING_URL"
```

The maintenance script content comes from the full plan v5.2 Phase 6.3 (daily-maintenance.sh). The setup script embeds it as a heredoc with variable substitution for paths.

**Key features of the maintenance script:**

- Token health check (`openclaw models status --check`)
- Auto-refresh via `claude setup-token` with timeout wrapper (30s, prevents hang if browser auth needed)
- OpenClaw npm update with version recording for rollback
- Post-update health check → automatic rollback on failure
- Telegram alerts for failures/updates
- Healthchecks.io ping (if URL configured)
- HOLD_VERSION file check (skip updates when present)
- Log rotation (tail -200 when log exceeds 2MB)

Write to `~/.openclaw/scripts/daily-maintenance.sh`
`chmod +x`

**9.1.1 HOLD_VERSION Mechanism**

The maintenance script checks for `~/.openclaw/HOLD_VERSION` before running updates:

- If file exists: skip OpenClaw update, send Telegram alert about available update
- If file doesn't exist: proceed with auto-update normally

Usage:

```bash
touch ~/.openclaw/HOLD_VERSION    # pause auto-updates (e.g. before a trip)
rm ~/.openclaw/HOLD_VERSION       # resume auto-updates
```

This is a safety valve — if an update breaks something, `touch HOLD_VERSION` prevents the next night's run from re-installing while you investigate.

**9.2 Generate launchd plist**

Template with `$HOME` and paths filled in:

- `StartCalendarInterval` with configured MAINTENANCE_HOUR/MINUTE
- `TimeOut: 300` (5 minutes — safety net if script hangs)
- PATH includes both `/opt/homebrew/bin` and `/opt/homebrew/opt/node@22/bin` (covers both install methods)
- HOME set explicitly (launchd doesn't load shell profiles)

Write to `~/Library/LaunchAgents/com.openclaw.daily-maintenance.plist`

**9.3 Load plist**

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.openclaw.daily-maintenance.plist
```

**9.4 Test**

- Run maintenance script manually
- Check log output
- Verify Telegram alert delivery (if token refresh or update happened)

### Phase 10: Tailscale

**Purpose:** Install Tailscale and authenticate. Done BEFORE security hardening so remote access is available as a safety net.

**10.1 Install**

- Check: app exists at `/Applications/Tailscale.app` or `command -v tailscale`
- Install: `brew install --cask tailscale`

**10.2 Start & Auth**

- `open /Applications/Tailscale.app`
- **⏸️ PAUSE** — "Authenticate Tailscale in the browser. Press Enter when connected..."

**10.3 Record IP**

- `TAILSCALE_IP=$(tailscale ip -4)`
- Print: "Your Mac Mini's Tailscale IP: $TAILSCALE_IP"
- Print: "Install Tailscale on your PC and phone, then test:"
- Print: " SSH: ssh $(whoami)@$TAILSCALE_IP"
- Print: " Control UI: http://$TAILSCALE_IP:18789"

### Phase 11: Security Hardening

**Purpose:** File permissions, SSH key-only auth, firewall.

**11.1 File Permissions**

```bash
chmod 700 ~/.openclaw/
chmod 600 ~/.openclaw/openclaw.json
find ~/.openclaw/agents/*/agent/ -name "auth-profiles.json" -exec chmod 600 {} \;
```

**11.2 SSH Key Setup**

Print the Mac Mini's SSH host fingerprint for verification:

```bash
echo "━━━ Mac Mini SSH Host Fingerprint ━━━"
ssh-keygen -l -f /etc/ssh/ssh_host_ed25519_key.pub
echo "Verify this matches when connecting from your other devices."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
```

**⏸️ PAUSE** — print detailed instructions:

```
SSH key setup required. On each device you want to connect from:

  From your PC:
    ssh-keygen -t ed25519 -C "kamil@pc"          # if no key exists
    ssh-copy-id $(whoami)@$TAILSCALE_IP

  From your phone (Termius, Blink, etc.):
    Generate an ed25519 key in the app
    Copy the public key to this Mac's ~/.ssh/authorized_keys

Test from ALL devices via Tailscale before continuing.
Press Enter when SSH key login works from every device...
```

**11.3 Disable Password Auth**

Only after user confirms keys work.

```bash
# Backup first
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

# Disable password auth — handle both cases: line exists (commented or not) and line missing
for SETTING in "PasswordAuthentication" "KbdInteractiveAuthentication"; do
    if grep -q "^#*${SETTING}" /etc/ssh/sshd_config; then
        # Line exists (possibly commented) — replace it
        sudo sed -i '' "s/^#*${SETTING}.*/${SETTING} no/" /etc/ssh/sshd_config
    else
        # Line doesn't exist — append it
        echo "${SETTING} no" | sudo tee -a /etc/ssh/sshd_config > /dev/null
    fi
done

# Reload sshd
sudo launchctl kickstart -k system/com.openssh.sshd
```

Print: "SSH password auth disabled. Test from all devices NOW."
Print: "If locked out, use physical keyboard. Rollback command:"
Print: " sudo cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config && sudo launchctl kickstart -k system/com.openssh.sshd"

**⏸️ PAUSE** — "Confirm SSH still works from all devices. Press Enter..."

**11.4 Firewall**

```bash
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setallowsigned on
```

> `--setallowsigned` allows Apple-signed services (SSH, Screen Sharing, Tailscale) while blocking unsigned incoming connections. `--setblockall` would break SSH/VNC over Tailscale.

**11.5 Gateway Token**

- Already set in Phase 7. Verify it's in config.
- If not: generate with `openssl rand -hex 32` and write to config.
- `openclaw gateway restart`

### Phase 12: Backup Setup

**Purpose:** Reference copies, git push, Time Machine note.

**12.1 Reference Copies**

```bash
mkdir -p ~/.openclaw/workspace/reference/scripts ~/.openclaw/workspace/reference/plists
cp ~/.openclaw/scripts/daily-maintenance.sh ~/.openclaw/workspace/reference/scripts/
cp ~/Library/LaunchAgents/com.openclaw.daily-maintenance.plist ~/.openclaw/workspace/reference/plists/
cd ~/.openclaw/workspace
git add reference/
git commit -m "Add reference copies of scripts and plists"
git push origin main 2>/dev/null || echo "⚠️ Git push failed. Run 'git push origin main' manually after fixing auth."
```

**12.2 Time Machine**

- Print: "Connect a Time Machine drive and enable ENCRYPTED backups in System Settings → Time Machine."
- Print: "⚠️ Enable 'Encrypt backups' — without it, all tokens and keys sit in plaintext on the backup drive."
- Can't automate (needs physical drive).

### Phase 13: Final Verification

**Purpose:** Full health check and summary.

**Checks:**

```bash
openclaw gateway status            # gateway running
openclaw models status --check     # auth healthy
openclaw models status --probe     # live API test
openclaw doctor --non-interactive  # no config issues
node --version                     # node 22.x
tailscale status                   # tailscale connected
fdesetup status                    # filevault on (or encrypting)
pmset -g | grep " sleep"           # sleep disabled
```

**Summary output:**

```
╔══════════════════════════════════════════════╗
║        Mac Mini Setup Complete! 🎉          ║
╠══════════════════════════════════════════════╣
║                                              ║
║  OpenClaw:    v2026.x.x ✅                  ║
║  Gateway:     running ✅                     ║
║  Auth:        healthy ✅                     ║
║  Telegram:    connected ✅                   ║
║  FileVault:   enabled ✅                     ║
║  Tailscale:   100.x.y.z ✅                  ║
║  Firewall:    active ✅                      ║
║  SSH:         key-only ✅                    ║
║  Maintenance: daily at HH:MM ✅             ║
║  Git remote:  configured ✅ / ⚠️ not set    ║
║                                              ║
║  Manual follow-up needed:                    ║
║  • Connect Time Machine (encrypted)         ║
║  • Set Anthropic spending limit ($50-100)   ║
║  • Monitor token lifetime (week 1)          ║
║  • Set up Healthchecks.io (if not done)     ║
║                                              ║
║  Logs: ~/.openclaw/logs/setup.log           ║
║  Plan: ~/.openclaw/workspace/guides/        ║
║        mac-mini-full-plan-v5.md             ║
╚══════════════════════════════════════════════╝
```

---

## Error Handling

| Scenario                          | Behavior                                                                    |
| --------------------------------- | --------------------------------------------------------------------------- |
| No internet                       | Phase 0 fails with clear message                                            |
| Homebrew install fails            | Stop, print manual install URL                                              |
| Node wrong version                | Auto-switch to node@22, log why                                             |
| jq install fails                  | Stop (required for Node version check and maintenance script)               |
| `claude setup-token` fails        | Warn, continue with API key only                                            |
| Both auth methods fail            | FATAL — can't continue                                                      |
| Workspace backup not found        | Warn, continue with fresh workspace                                         |
| Workspace tar has wrong structure | Auto-detect nested directory, attempt fix                                   |
| Config backup not found           | Generate fresh config from template                                         |
| Git push fails                    | Warn with fix instructions, continue                                        |
| Gateway won't start               | Stop, print diagnostic commands                                             |
| Telegram API returns error        | Print /start reminder for new bots, continue                                |
| `sshd_config` modification fails  | Stop, restore backup, print manual instructions                             |
| sshd_config line doesn't exist    | Append instead of replace (grep+tee fallback)                               |
| Tailscale install fails           | Warn, continue (can install later)                                          |
| Screen Sharing enable fails       | Print manual GUI instructions                                               |
| `launchctl bootstrap` fails       | Check plist syntax, print manual load command                               |
| `brew pin` fails                  | Warn, continue (non-critical)                                               |
| Any sudo command fails            | Stop, check permissions                                                     |
| `--phase N` with missing prereqs  | Per-phase prereq check fails with message about which prior phase is needed |

---

## Per-Phase Prerequisite Checks

When using `--phase N` to resume, the script validates prerequisites:

| Phase | Requires                                                      |
| ----- | ------------------------------------------------------------- |
| 0     | macOS, admin user, internet                                   |
| 1     | Phase 0 (just admin + internet)                               |
| 2     | Phase 0                                                       |
| 3     | Phase 0                                                       |
| 4     | Phase 0                                                       |
| 5     | Phase 4 (`brew`, `node`, `npm`, `jq` in PATH)                 |
| 6     | Phase 5 (`openclaw` and `claude` in PATH)                     |
| 7     | Phase 5 (`openclaw` in PATH), Phase 6 (auth configured)       |
| 8     | Phase 7 (config exists, workspace populated)                  |
| 9     | Phase 5 (all tool paths available), Phase 8 (gateway running) |
| 10    | Phase 0 (internet)                                            |
| 11    | Phase 10 (Tailscale connected — safety net for SSH lockout)   |
| 12    | Phase 7 (workspace git initialized), Phase 9 (scripts exist)  |
| 13    | All prior phases                                              |

Each phase's prereq check runs `command -v` for required binaries and verifies critical state (e.g. `openclaw gateway status` for Phase 9).

---

## Logging

All output logged to `~/.openclaw/logs/setup.log` (tee'd to both terminal and file).

```bash
mkdir -p ~/.openclaw/logs
exec > >(tee -a ~/.openclaw/logs/setup.log) 2>&1
```

Format:

```
[2026-06-22 15:30:00] [PHASE 4] Installing Node.js...
[2026-06-22 15:30:05] [PHASE 4] ✅ Node 22.12.0 installed
[2026-06-22 15:30:05] [PHASE 4] Path: /opt/homebrew/bin/node
```

---

## Output Style

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Phase 4: Dependencies                [4/13]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ✅ Xcode CLT already installed
  ✅ Homebrew already installed
  ⏳ Installing jq...
  ✅ jq 1.7.1 installed
  ⏳ Installing Node.js...
     Homebrew shows Node 24.1 — using node@22 instead
  ✅ Node 22.12.0 installed (/opt/homebrew/opt/node@22/bin/node)
  ✅ Node pinned (brew pin node@22)
  ⏳ Installing GitHub CLI...
  ✅ GitHub CLI installed
  ⏸️  GitHub authentication required
     → Complete the browser auth flow
     Press Enter when done...
```

Color codes:

- ✅ Green — done/skipped (already configured)
- ⏳ Yellow — in progress
- ⏸️ Blue — waiting for user
- ❌ Red — error
- ⚠️ Yellow — warning (non-fatal)

---

## CLI Flags

```bash
./mac-mini-setup.sh                  # normal run
./mac-mini-setup.sh --dry-run        # show what would be done (checks idempotency: "would install" vs "already installed (skip)")
./mac-mini-setup.sh --phase 6        # start from phase 6 (validates prerequisites first)
./mac-mini-setup.sh --skip 2,10      # skip FileVault and Tailscale
./mac-mini-setup.sh --verify-only    # just run Phase 13 checks
./mac-mini-setup.sh --help           # usage
```

**`--dry-run` behavior:** Runs all idempotent checks without making changes. Shows "would install Node" vs "Node already installed (skip)". Validates the config section. Does NOT actually install or modify anything.

**`--phase N` behavior:** Runs prerequisite checks for Phase N. If prerequisites are met, starts from Phase N and continues through Phase 13. If prerequisites fail, prints which prior phase must run first.

---

## File Layout (generated by script)

```
~/.openclaw/
├── openclaw.json                    # generated or restored from backup
├── scripts/
│   └── daily-maintenance.sh         # generated with detected paths
├── logs/
│   ├── setup.log                    # this script's log
│   └── daily-maintenance.log        # maintenance log (after first run)
├── workspace/
│   ├── SOUL.md, MEMORY.md, ...      # restored from backup
│   ├── guides/
│   │   └── mac-mini-full-plan-v5.md # the plan
│   └── reference/
│       ├── scripts/
│       │   └── daily-maintenance.sh
│       └── plists/
│           └── com.openclaw.daily-maintenance.plist
├── agents/
│   └── main/agent/
│       └── auth-profiles.json       # auth configured by script
├── credentials/                     # restored from auth backup (if provided)
└── HOLD_VERSION                     # NOT created by default
                                     # touch to pause auto-updates
                                     # rm to resume

~/Library/LaunchAgents/
└── com.openclaw.daily-maintenance.plist  # generated
```

---

## Security Notes

- Script never stores secrets in plain text files (except openclaw.json which gets chmod 600)
- Gateway token auto-generated with `openssl rand -hex 32`
- Bot token prompted interactively (not hardcoded in script unless user fills config)
- Setup log may contain version numbers and paths — not sensitive
- The script itself can be shared publicly (config section has no secrets by default)
- Auth backup from Telegram should be deleted after download (reminder printed)

---

## Estimated Size

| Component                                       | Lines                                      |
| ----------------------------------------------- | ------------------------------------------ |
| Config section + constants                      | ~40                                        |
| Helper functions (log, prompt, checks, prereqs) | ~120                                       |
| Phase 0 (pre-flight)                            | ~40                                        |
| Phase 1 (system config)                         | ~50                                        |
| Phase 2 (FileVault)                             | ~30                                        |
| Phase 3 (remote access)                         | ~35                                        |
| Phase 4 (dependencies)                          | ~100                                       |
| Phase 5 (install tools)                         | ~35                                        |
| Phase 6 (auth)                                  | ~80                                        |
| Phase 7 (config + workspace)                    | ~100                                       |
| Phase 8 (gateway)                               | ~60                                        |
| Phase 9 (maintenance automation)                | ~200 (includes embedded heredoc templates) |
| Phase 10 (tailscale)                            | ~30                                        |
| Phase 11 (security hardening)                   | ~80                                        |
| Phase 12 (backup setup)                         | ~35                                        |
| Phase 13 (verification)                         | ~60                                        |
| CLI arg parsing + --dry-run                     | ~50                                        |
| **Total**                                       | **~1150–1300 lines**                       |

---

## Changelog

- **v1.0:** Initial plan with 10 phases (0-9), basic structure
- **v1.1:** Expanded to 13 phases (0-12), added CLI flags, error handling table, file layout, security notes
- **v1.2 (2026-06-22):** Major review — 21 fixes applied:
  - **🔴 Bugs fixed:**
    - Moved jq install before Node version check (was using jq before it existed)
    - Fixed phase count: 14 phases (0-13), not "10-phase migration"
  - **🟠 Contradictions fixed:**
    - Screen Sharing: `launchctl load` → `launchctl bootstrap` (deprecated command)
    - Config template: `reserveTokensFloor` 8000 → 16000, added contextPruning and hooks.internal.enabled
  - **🟡 Logic fixes:**
    - Added "Backup Creation" section with exact tar commands for old machine
    - Documented tar structure + added extraction validation with auto-fix for nested dirs
    - Added per-phase prerequisite checks table (validates deps when using --phase N)
    - Noted SSH password auth window between Phase 3 and Phase 11
    - Made `gh auth login` conditional on GITHUB_REPO being set
    - Clarified Claude Code CLI is for setup-token management (not optional if using setup-token)
    - Added setup-token interactivity test from v5.2 Phase 6.1
  - **🔵 Edge cases addressed:**
    - Added "Getting the Script onto the Mac Mini" section (curl/AirDrop/USB/paste)
    - Added HEALTHCHECKS_PING_URL to config section
    - sshd_config: grep+append fallback when config lines don't exist
    - Added /start reminder for new Telegram bot tokens
    - Added `womp` (wake on LAN) and `powernap` (disable) to Phase 1
    - SSH host fingerprint printed for verification on first connection
    - Fixed kill test: use `pgrep -x` + SIGKILL for crash simulation
    - Updated line estimate: ~1150-1300 (was 850)
    - Documented HOLD_VERSION pause mechanism
    - Added SETUP_TOKEN to config section (pre-fill from old machine)
    - Git push failures warn instead of silently suppressing
    - Screen Sharing has GUI fallback if launchctl fails
