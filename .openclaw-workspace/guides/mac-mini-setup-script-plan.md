# Mac Mini Setup Script — Plan v1.1

_Companion to: Mac Mini Full Plan v5.2_
_Automates 10-phase migration onto a brand new Mac Mini M4_

---

## Goal

A single bash script (`mac-mini-setup.sh`) that takes a fresh Mac Mini from unboxing to a fully operational OpenClaw gateway with Kai running. Minimizes manual steps while being honest about what requires human interaction.

---

## Design Principles

1. **Idempotent** — every phase checks before acting. safe to re-run at any point.
2. **Resumable** — if interrupted (reboot, error, lunch break), re-run picks up where it left off.
3. **No hidden magic** — every action is logged and explained. user can read the script and understand what it does.
4. **Fail safe** — errors stop the current phase with a clear message. never leaves system in a broken state.
5. **Zero dependencies** — runs on stock macOS with only bash. installs everything it needs.
6. **Config at the top** — all customization in one place. edit once, run once.

---

## Prerequisites (before running the script)

The user must have:

1. ✅ A Mac Mini M4 with macOS booted and initial setup complete (Apple ID, user account created)
2. ✅ Internet connection (Wi-Fi or Ethernet)
3. ✅ Admin user account (the one they'll run OpenClaw under)
4. ✅ Workspace backup file downloaded to ~/Downloads/ (from CC container via Telegram)
5. ✅ Config backup file downloaded to ~/Downloads/ (optional — script can create fresh config)
6. ✅ Telegram bot token (from @BotFather or existing config backup)
7. ✅ Anthropic API key (for fallback auth — from console.anthropic.com)
8. ✅ UPS connected via USB (recommended, not required)

---

## Config Section

```bash
# === EDIT BEFORE RUNNING ===

# System
TIMEZONE="America/Toronto"
COMPUTER_NAME="mac-mini"          # sets hostname + Bonjour name

# Backups (from Phase 1 of migration plan — run on OLD machine first)
WORKSPACE_BACKUP="$HOME/Downloads/kai-workspace-backup.tar.gz"
CONFIG_BACKUP="$HOME/Downloads/openclaw-config-backup.json"

# Telegram
TELEGRAM_BOT_TOKEN=""             # if empty: reads from config backup, or prompts
TELEGRAM_CHAT_ID="455442541"

# Auth
ANTHROPIC_API_KEY=""              # fallback API key, prompted if empty

# Git (for workspace disaster recovery)
GITHUB_REPO=""                    # e.g. "https://github.com/kamil/kai-workspace.git"
                                  # if empty: local git only, no remote push

# Gateway
GATEWAY_TOKEN=""                  # auto-generated (openssl rand -hex 32) if empty

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

- macOS version >= 15 (Sequoia)
- Running as regular user (not root)
- User has admin privileges (`groups | grep admin`)
- Internet connectivity (`curl -fsS --max-time 5 https://apple.com`)
- Config section has been edited (sentinel check — e.g. TIMEZONE isn't "EDIT_ME")
- No other OpenClaw gateway already running on this machine

**If any fail:** print clear error, exit.

**Idempotency:** Always runs (fast checks).

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
| Disable auto macOS updates | `sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false` | `defaults read` check |
| Keep RSR on | `sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool true` | already default |

**Interactive:** No. All CLI.

**Needs sudo:** Yes (prompts once at start, subsequent sudo calls use cached credentials).

### Phase 2: FileVault

**Purpose:** Enable full-disk encryption.

**Idempotent check:** `fdesetup status` shows "FileVault is On"

**If not enabled:**

1. Print warning about what FileVault does (disables auto-login, needs password on boot)
2. Run `sudo fdesetup enable`
3. **⏸️ PAUSE** — fdesetup prompts for password and outputs recovery key
4. Print: "SAVE YOUR RECOVERY KEY NOW. Store it in a password manager or print it."
5. Wait for Enter
6. Verify: `fdesetup status`

**Edge case:** FileVault encryption takes hours in background. Script doesn't wait — continues with next phase. Encryption runs in background without affecting use.

### Phase 3: Remote Access

**Purpose:** Enable SSH and Screen Sharing for remote management.

**Actions:**
| Action | Command | Idempotent check |
|---|---|---|
| Enable SSH | `sudo systemsetup -setremotelogin on` | `systemsetup -getremotelogin` |
| Enable Screen Sharing | `sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist` | `launchctl list \| grep screensharing` |

**Note:** On macOS Ventura+, Screen Sharing may require `sudo defaults write /var/db/launchd.db/com.apple.launchd/overrides.plist com.apple.screensharing -dict Disabled -bool false` first. The script should try the standard approach and fall back to the manual instruction if it fails.

**Interactive:** No (except sudo).

### Phase 4: Dependencies

**Purpose:** Install Homebrew, Node.js, jq, GitHub CLI.

**Sub-steps:**

**4.1 Xcode Command Line Tools**

- Check: `xcode-select -p &>/dev/null`
- Install: `xcode-select --install`
- **⏸️ PAUSE** — macOS shows a dialog, downloads ~2GB. Script waits with: "Press Enter after Xcode CLT finishes installing..."
- Verify: `xcode-select -p`

**4.2 Homebrew**

- Check: `command -v brew`
- Install: `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`
- **⏸️ PAUSE** — Homebrew prompts for password and Enter
- Post-install: add to PATH (`eval "$(/opt/homebrew/bin/brew shellenv)"` + append to `~/.zprofile`)
- Verify: `brew --version`

**4.3 Node.js**

- Check: `command -v node && node -v`
- Version logic:
  ```
  BREW_NODE_VER=$(brew info --json=v2 node | jq -r '.formulae[0].versions.stable')
  if [[ "$BREW_NODE_VER" == 22.* ]]; then
      brew install node
      NODE_FORMULA="node"
  else
      brew install node@22
      # add to PATH
      NODE_FORMULA="node@22"
  fi
  brew pin $NODE_FORMULA
  ```
- Verify: `node --version` is 22.x

**4.4 jq**

- Check: `command -v jq`
- Install: `brew install jq`

**4.5 GitHub CLI**

- Check: `command -v gh`
- Install: `brew install gh`
- Auth: `gh auth login` — **⏸️ PAUSE** (browser auth)

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

**5.2 Claude Code CLI**

- Check: `command -v claude`
- Install: `npm install -g @anthropic-ai/claude-code`
- Record: `CLAUDE_PATH=$(command -v claude)`
- Verify: `claude --version`

### Phase 6: Auth Setup

**Purpose:** Configure Anthropic auth (setup-token + fallback API key).

**6.1 Setup Token**

- Print: "This will open a browser for Anthropic authentication."
- **⏸️ PAUSE** — "Press Enter when ready..."
- Run: `claude setup-token` (interactive — user completes browser flow)
- Capture token output
- Run: `openclaw models auth setup-token` and paste token
- Verify: `openclaw models status --check` returns 0

**Edge case:** If setup-token fails or user skips, the API key fallback (6.2) becomes primary. Script warns but continues.

**6.2 Fallback API Key**

- If `ANTHROPIC_API_KEY` is set in config: pipe it to `openclaw models auth add`
- If empty: prompt interactively
- If user skips both 6.1 and 6.2: **FATAL** — can't continue without any auth

**6.3 Verify Auth**

- `openclaw models status --check` — must return 0 or 2
- `openclaw models status --probe` — live API test

### Phase 7: Config & Workspace

**Purpose:** Write OpenClaw config, restore workspace, init git.

**7.1 Generate openclaw.json**

Strategy: if CONFIG_BACKUP exists, start from that. Otherwise generate fresh.

Fresh config template:

```json5
{
  channels: {
    telegram: {
      enabled: true,
      botToken: "$TELEGRAM_BOT_TOKEN",
      dmPolicy: "allowlist",
      allowFrom: ["$TELEGRAM_CHAT_ID"],
      groupPolicy: "allowlist",
      streamMode: "partial",
    },
  },
  gateway: {
    mode: "local",
    auth: {
      token: "$GATEWAY_TOKEN",
    },
  },
  agents: {
    defaults: {
      compaction: {
        reserveTokensFloor: 8000,
      },
    },
  },
}
```

If CONFIG_BACKUP exists:

- Copy to `~/.openclaw/openclaw.json`
- Merge/ensure critical fields (gateway token, compaction setting)

**7.2 Restore Workspace**

- If WORKSPACE_BACKUP exists:
  ```bash
  cd ~/.openclaw/workspace
  tar xzf "$WORKSPACE_BACKUP"
  ```
- If not: warn, continue with default workspace from onboard

**7.3 Git Init**

- Check: `cd ~/.openclaw/workspace && git rev-parse --is-inside-work-tree`
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
  git push -u origin main
  ```
- If empty: warn "No git remote configured. DR depends on Time Machine only."

### Phase 8: Gateway Start & Verify

**Purpose:** Install daemon, start gateway, verify everything works.

**8.1 Install Daemon**

- `openclaw gateway install`

**8.2 Start Gateway**

- `openclaw gateway start`
- Wait 10 seconds
- `openclaw gateway status` — verify running

**8.3 Run Doctor**

- `openclaw doctor --non-interactive`

**8.4 Test Telegram**

- Send test message via Telegram API:
  ```bash
  curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
    --data-urlencode "text=🎉 Kai is live on the Mac Mini! Setup script Phase 8 complete."
  ```
- Print: "Check Telegram — you should see a message from the bot."
- **⏸️ PAUSE** — "Reply to the bot to verify two-way communication. Press Enter when confirmed..."

**8.5 Verify Daemon Persistence**

- `kill $(pgrep -f "openclaw gateway")`
- Sleep 10
- `openclaw gateway status` — verify auto-restarted

### Phase 9: Maintenance Automation

**Purpose:** Generate maintenance script and launchd plist using detected paths.

**9.1 Generate daily-maintenance.sh**

- Template with paths filled in from Phase 4/5 detection:
  ```
  OPENCLAW="$OPENCLAW_PATH"
  CLAUDE="$CLAUDE_PATH"
  NPM="$NPM_PATH"
  JQ="$JQ_PATH"
  CURL="$CURL_PATH"
  OPENCLAW_HOME="$HOME/.openclaw"
  ```
- Write to `~/.openclaw/scripts/daily-maintenance.sh`
- `chmod +x`

**9.2 Generate launchd plist**

- Template with `$HOME` and paths filled in
- Includes `TimeOut: 300`
- Includes correct PATH based on Option A vs B node install
- Write to `~/Library/LaunchAgents/com.openclaw.daily-maintenance.plist`

**9.3 Load plist**

- `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.openclaw.daily-maintenance.plist`

**9.4 Test**

- Run maintenance script manually
- Check log output

### Phase 10: Tailscale

**Purpose:** Install Tailscale and authenticate.

**10.1 Install**

- Check: `command -v tailscale` or app exists
- Install: `brew install --cask tailscale`

**10.2 Start & Auth**

- `open /Applications/Tailscale.app`
- **⏸️ PAUSE** — "Authenticate Tailscale in the browser. Press Enter when connected..."

**10.3 Record IP**

- `TAILSCALE_IP=$(tailscale ip -4)`
- Print: "Your Mac Mini's Tailscale IP: $TAILSCALE_IP"
- Print: "Install Tailscale on your PC and phone, then test SSH: ssh $(whoami)@$TAILSCALE_IP"

### Phase 11: Security Hardening

**Purpose:** File permissions, SSH key-only auth, firewall.

**11.1 File Permissions**

```bash
chmod 700 ~/.openclaw/
chmod 600 ~/.openclaw/openclaw.json
find ~/.openclaw/agents/*/agent/ -name "auth-profiles.json" -exec chmod 600 {} \;
```

**11.2 SSH Key Setup**

- **⏸️ PAUSE** — print detailed instructions:

  ```
  On your PC:  ssh-copy-id $(whoami)@$TAILSCALE_IP
  On your phone: copy public key to ~/.ssh/authorized_keys on this Mac

  Test from ALL devices before continuing.
  Press Enter when SSH key login works from every device...
  ```

**11.3 Disable Password Auth**

- Only after user confirms keys work
- `sudo sed` to modify sshd_config (with backup):
  ```bash
  sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
  sudo sed -i '' 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  sudo sed -i '' 's/^#*KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config
  ```
- `sudo launchctl kickstart -k system/com.openssh.sshd`
- Print: "Test SSH from all devices NOW. If locked out, use physical keyboard."
- **⏸️ PAUSE** — "Confirm SSH still works. Press Enter..."

**Edge case:** If ssh-copy-id wasn't done or keys don't work, the user is locked out of remote SSH. The script:

1. Creates a backup of sshd_config before modifying
2. Warns multiple times
3. Waits for explicit confirmation
4. Provides rollback command: `sudo cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config && sudo launchctl kickstart -k system/com.openssh.sshd`

**11.4 Firewall**

```bash
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setallowsigned on
```

**11.5 Gateway Token**

- Already set in Phase 7. Verify it's in config.
- If not: generate and add.
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
git push origin main 2>/dev/null || true
```

**12.2 Time Machine**

- Print: "Connect a Time Machine drive and enable ENCRYPTED backups in System Settings → Time Machine."
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
fdesetup status                    # filevault on
pmset -g | grep " sleep"          # sleep disabled
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
║  Maintenance: daily 4:00 AM ✅              ║
║  Git remote:  configured ✅                  ║
║                                              ║
║  Manual follow-up needed:                    ║
║  • Connect Time Machine (encrypted)         ║
║  • Set up Healthchecks.io                   ║
║  • Set Anthropic spending limit             ║
║  • Monitor token lifetime (week 1)          ║
║                                              ║
║  Logs: ~/.openclaw/logs/setup.log           ║
║  Plan: ~/.openclaw/workspace/guides/        ║
║        mac-mini-full-plan-v5.md             ║
╚══════════════════════════════════════════════╝
```

---

## Error Handling

| Scenario                       | Behavior                                        |
| ------------------------------ | ----------------------------------------------- |
| No internet                    | Phase 0 fails with clear message                |
| Homebrew install fails         | Stop, print manual install URL                  |
| Node wrong version             | Auto-switch to node@22, log why                 |
| setup-token fails              | Warn, continue with API key only                |
| Both auth methods fail         | FATAL — can't continue                          |
| Workspace backup not found     | Warn, continue with fresh workspace             |
| Config backup not found        | Generate fresh config from template             |
| Git push fails                 | Warn, continue (local git still works)          |
| Gateway won't start            | Stop, print diagnostic commands                 |
| sshd_config modification fails | Stop, restore backup, print manual instructions |
| Tailscale install fails        | Warn, continue (can install later)              |
| Any sudo command fails         | Stop, check permissions                         |

---

## Logging

All output logged to `~/.openclaw/logs/setup.log` (tee'd to both terminal and file).

Format:

```
[2026-06-22 15:30:00] [PHASE 4] Installing Node.js...
[2026-06-22 15:30:05] [PHASE 4] ✅ Node 22.12.0 installed
[2026-06-22 15:30:05] [PHASE 4] Path: /opt/homebrew/bin/node
```

---

## Output Style

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Phase 4: Dependencies                [4/13]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ✅ Xcode CLT already installed
  ✅ Homebrew already installed
  ⏳ Installing Node.js...
     Homebrew shows Node 24.1 — using node@22 instead
  ✅ Node 22.12.0 installed (/opt/homebrew/opt/node@22/bin/node)
  ✅ Node pinned (brew pin node@22)
  ✅ jq already installed
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
./mac-mini-setup.sh --dry-run        # show what would be done
./mac-mini-setup.sh --phase 6        # start from phase 6
./mac-mini-setup.sh --skip 2,10      # skip FileVault and Tailscale
./mac-mini-setup.sh --verify-only    # just run Phase 13 checks
./mac-mini-setup.sh --help           # usage
```

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
│   │   ├── mac-mini-full-plan-v5.md # the plan
│   │   └── mac-mini-setup.sh        # this script (reference copy)
│   └── reference/
│       ├── scripts/
│       │   └── daily-maintenance.sh
│       └── plists/
│           └── com.openclaw.daily-maintenance.plist
├── agents/
│   └── main/agent/
│       └── auth-profiles.json       # auth configured by script
└── HOLD_VERSION                     # NOT created (only on demand)

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

---

## Estimated Size

| Component                              | Lines                              |
| -------------------------------------- | ---------------------------------- |
| Config section                         | ~30                                |
| Helper functions (log, prompt, checks) | ~80                                |
| Phase 0 (pre-flight)                   | ~30                                |
| Phase 1 (system config)                | ~40                                |
| Phase 2 (FileVault)                    | ~25                                |
| Phase 3 (remote access)                | ~20                                |
| Phase 4 (dependencies)                 | ~80                                |
| Phase 5 (install tools)                | ~30                                |
| Phase 6 (auth)                         | ~50                                |
| Phase 7 (config + workspace)           | ~70                                |
| Phase 8 (gateway)                      | ~50                                |
| Phase 9 (maintenance automation)       | ~150 (includes embedded templates) |
| Phase 10 (tailscale)                   | ~25                                |
| Phase 11 (security hardening)          | ~60                                |
| Phase 12 (backup setup)                | ~30                                |
| Phase 13 (verification)                | ~50                                |
| CLI arg parsing                        | ~30                                |
| **Total**                              | **~850 lines**                     |

---

## Open Questions

1. **Should the script also handle stopping the old CC container gateway?** Probably not — that's on the old machine. But it could check if another gateway is polling the same bot and warn.

2. **Should we offer to configure the OpenClaw Control UI (Tailscale Serve)?** This is optional and the config keys need verification. Probably skip in v1, add in v2.

3. **Should the script handle macOS software updates?** Running updates before setup would be ideal but adds 30+ min and a reboot (which requires FileVault password). Recommend doing it manually before running the script.

4. **Should we embed the daily-maintenance.sh template or keep it as a heredoc?** Heredoc is cleaner for a single file. No external templates needed.

5. **Should --dry-run actually check idempotency?** Yes — it should show "would install Node" vs "Node already installed (skip)" so you can see exactly what a real run would do.
