#!/bin/bash
# Mac Mini Setup Script — v1.7
# Companion to: Mac Mini Full Plan v5.2
# Automates 14-phase migration onto a brand new Mac Mini M4

set -uo pipefail

# === CONFIGURATION — EDIT BEFORE RUNNING ===
# After running successfully, clear SETUP_TOKEN and ANTHROPIC_API_KEY
# from this file (they'll be stored securely in OpenClaw's auth system).
# If this script is in a git repo, secrets in the config section end up
# in git history. For sensitive values, prefer environment variables:
#   export SETUP_TOKEN="sk-ant-oat01-..."
#   export ANTHROPIC_API_KEY="sk-ant-..."
#   ./mac-mini-setup.sh

# System
TIMEZONE="${TIMEZONE:-America/Toronto}"
COMPUTER_NAME="${COMPUTER_NAME:-mac-mini}"

# Backups (from migration prep — must be created on OLD machine first)
WORKSPACE_BACKUP="${WORKSPACE_BACKUP:-$HOME/Downloads/kai-workspace-backup.tar.gz}"
CONFIG_BACKUP="${CONFIG_BACKUP:-$HOME/Downloads/openclaw-config-backup.json}"

# Telegram
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"       # reads from config backup or prompts if empty
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-455442541}"

# Auth (prefer env vars for these — see note above)
SETUP_TOKEN="${SETUP_TOKEN:-}"                      # if empty, Phase 6 runs interactively
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"           # fallback API key, prompted if empty

# Git (for workspace disaster recovery — strongly recommended)
GITHUB_REPO="${GITHUB_REPO:-}"                      # e.g. "https://github.com/kamil/kai-workspace.git"

# Gateway
GATEWAY_TOKEN="${GATEWAY_TOKEN:-}"                  # auto-generated (openssl rand -hex 32) if empty

# Monitoring (optional — set up at healthchecks.io first, get the ping URL)
HEALTHCHECKS_PING_URL="${HEALTHCHECKS_PING_URL:-}"

# Maintenance
MAINTENANCE_HOUR="${MAINTENANCE_HOUR:-4}"           # 4 AM local time
MAINTENANCE_MINUTE="${MAINTENANCE_MINUTE:-0}"

# ============================================

# Global state
DRY_RUN=false
CURRENT_PHASE=""
LOG_FILE="$HOME/.openclaw/logs/setup.log"
SKIP_PHASES=""
SKIP_CLAUDE_CLI=false
VERIFY_ONLY=false
PHASE_START=""
SETUP_TOKEN_AUTO=false

# Tool paths (detected dynamically)
CURL_BIN="/usr/bin/curl"
BREW_BIN=""
JQ_BIN=""
NODE_BIN=""
NPM_BIN=""
OPENCLAW_BIN=""
CLAUDE_BIN=""

# Create log directory early
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# Capture all output to log file (tee to both terminal and file)
exec > >(tee -a "$LOG_FILE") 2>&1

# Helper functions
log() { 
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] [PHASE $CURRENT_PHASE] $1" | tee -a "$LOG_FILE"
}

die() { 
    echo "❌ $1" >&2
    exit 1
}

detect_paths() {
    # Named *_BIN (not *_PATH) to avoid collision with NODE_PATH env var used by Node.js
    
    # Always available (stock macOS)
    CURL_BIN="/usr/bin/curl"

    # Homebrew (Phase 4.2)
    BREW_BIN=$(command -v brew 2>/dev/null || echo "")

    # jq (Phase 4.3)
    JQ_BIN=$(command -v jq 2>/dev/null || echo "")

    # Node/npm (Phase 4.4)
    NODE_BIN=$(command -v node 2>/dev/null || echo "")
    NPM_BIN=$(command -v npm 2>/dev/null || echo "")

    # OpenClaw (Phase 5.1)
    OPENCLAW_BIN=$(command -v openclaw 2>/dev/null || echo "")

    # Claude Code CLI (Phase 5.2)
    CLAUDE_BIN=$(command -v claude 2>/dev/null || echo "")
}

require_tool() {
    local tool="$1" phase="$2"
    command -v "$tool" &>/dev/null || die "$tool not found in PATH. Run Phase $phase first (or: $0 --phase $phase)"
}

run() {
    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY] Would run: $*"
    else
        "$@"
    fi
}

pause() {
    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY] Would pause: $1"
    else
        read -rp "$1 Press Enter to continue..."
    fi
}

confirm() {
    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY] Would ask: $1 (auto-yes)"
        return 0
    fi
    read -rp "$1 " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

phase_banner() {
    local phase_num="$1"
    local phase_name="$2"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  Phase %d: %-30s [%d/13]\n" "$phase_num" "$phase_name" "$phase_num"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

should_skip_phase() {
    local phase="$1"
    [[ ",$SKIP_PHASES," == *",$phase,"* ]]
}

phase_0() {
    CURRENT_PHASE="0"
    should_skip_phase 0 && { log "Skipping Phase 0 (--skip)"; return; }
    
    phase_banner 0 "Pre-flight Checks"
    
    # macOS version >= 15
    local macos_version
    macos_version=$(sw_vers -productVersion)
    local macos_major
    macos_major=$(echo "$macos_version" | cut -d. -f1)
    
    if [ "$macos_major" -lt 15 ]; then
        die "macOS version $macos_version is too old. Need 15.0+ (Sequoia)"
    fi
    log "macOS version: $macos_version ✅"
    
    # Running as regular user (not root)
    if [ "$EUID" -eq 0 ]; then
        die "Don't run as root. Run as regular user with admin privileges."
    fi
    log "Running as user: $(whoami) ✅"
    
    # User has admin privileges
    if ! groups | grep -q admin; then
        die "User $(whoami) doesn't have admin privileges. Add to admin group first."
    fi
    log "User has admin privileges ✅"
    
    # Internet connectivity
    if ! $CURL_BIN -fsS --max-time 5 https://apple.com >/dev/null 2>&1; then
        die "No internet connection. Connect to Wi-Fi or Ethernet first."
    fi
    log "Internet connectivity ✅"
    
    # Sufficient disk space (>= 10GB free)
    local free_gb
    free_gb=$(df -g / | awk 'NR==2{print $4}')
    if [ "$free_gb" -lt 10 ]; then
        die "Only ${free_gb}GB free. Need at least 10GB for Xcode CLT, Homebrew, and tools."
    fi
    log "Disk space: ${free_gb}GB free ✅"
    
    # Validate chat ID is numeric
    if ! [[ "$TELEGRAM_CHAT_ID" =~ ^[0-9]+$ ]]; then
        die "TELEGRAM_CHAT_ID must be numeric (got: '$TELEGRAM_CHAT_ID'). Use your Telegram user ID, not username."
    fi
    log "Telegram chat ID validated ✅"
    
    # Configuration review and confirmation
    echo ""
    echo "━━━ Configuration Review ━━━"
    echo "  Timezone:     $TIMEZONE"
    echo "  Computer:     $COMPUTER_NAME"
    echo "  Telegram ID:  $TELEGRAM_CHAT_ID"
    echo "  Workspace:    $WORKSPACE_BACKUP"
    echo "  Config:       $CONFIG_BACKUP"
    echo "  Git remote:   ${GITHUB_REPO:-<not set>}"
    echo "  Health ping:  ${HEALTHCHECKS_PING_URL:-<not set>}"
    echo "  Setup token:  ${SETUP_TOKEN:+set (${SETUP_TOKEN:0:12}...)}${SETUP_TOKEN:-<not set — interactive>}"
    echo "  API key:      ${ANTHROPIC_API_KEY:+set (${ANTHROPIC_API_KEY:0:8}...)}${ANTHROPIC_API_KEY:-<not set — will prompt>}"
    echo "  Bot token:    ${TELEGRAM_BOT_TOKEN:+set}${TELEGRAM_BOT_TOKEN:-<not set — will extract or prompt>}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    confirm "Continue with these settings? [y/N]" || die "Edit the config section at the top of the script and re-run."
    
    # Generate gateway token if empty
    if [ -z "$GATEWAY_TOKEN" ]; then
        GATEWAY_TOKEN=$(openssl rand -hex 32)
        log "Generated gateway token: ${GATEWAY_TOKEN:0:8}..."
    fi
    
    # Validate Telegram bot token (attempt extraction if jq available)
    if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
        if [ -f "$CONFIG_BACKUP" ] && command -v jq >/dev/null 2>&1; then
            TELEGRAM_BOT_TOKEN=$(jq -r '.channels.telegram.botToken // ""' "$CONFIG_BACKUP" 2>/dev/null)
            [ -n "$TELEGRAM_BOT_TOKEN" ] && log "Bot token extracted from config backup ✅"
        fi
        
        if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
            echo "⚠️ TELEGRAM_BOT_TOKEN is empty and no config backup with botToken found."
            if [ "$DRY_RUN" != "true" ]; then
                read -rp "Enter Telegram bot token (from @BotFather): " TELEGRAM_BOT_TOKEN
                [ -z "$TELEGRAM_BOT_TOKEN" ] && die "Telegram bot token is required for OpenClaw gateway."
            else
                echo "[DRY] Would prompt for Telegram bot token (skipping)"
            fi
        fi
    fi
    
    # Check backup files exist (if paths are non-empty)
    if [ -n "$WORKSPACE_BACKUP" ] && [ ! -f "$WORKSPACE_BACKUP" ]; then
        echo "⚠️ Workspace backup not found: $WORKSPACE_BACKUP"
    fi
    
    if [ -n "$CONFIG_BACKUP" ] && [ ! -f "$CONFIG_BACKUP" ]; then
        echo "⚠️ Config backup not found: $CONFIG_BACKUP"
    fi
    
    log "Pre-flight checks complete ✅"
}

phase_1() {
    CURRENT_PHASE="1"
    should_skip_phase 1 && { log "Skipping Phase 1 (--skip)"; return; }
    
    phase_banner 1 "System Configuration"
    
    # Set computer name
    if [ "$(scutil --get ComputerName)" != "$COMPUTER_NAME" ]; then
        log "Setting computer name to: $COMPUTER_NAME"
        run sudo scutil --set ComputerName "$COMPUTER_NAME"
        run sudo scutil --set HostName "$COMPUTER_NAME"
        run sudo scutil --set LocalHostName "$COMPUTER_NAME"
    else
        log "Computer name already set ✅"
    fi
    
    # Set timezone
    if [ "$(systemsetup -gettimezone | cut -d' ' -f3-)" != "$TIMEZONE" ]; then
        log "Setting timezone to: $TIMEZONE"
        run sudo systemsetup -settimezone "$TIMEZONE"
    else
        log "Timezone already set ✅"
    fi
    
    # Disable system sleep
    if ! pmset -g | grep -q " sleep.*0"; then
        log "Disabling system sleep"
        run sudo pmset -a sleep 0
    else
        log "System sleep already disabled ✅"
    fi
    
    # Display sleep 10min
    if ! pmset -g | grep -q "displaysleep.*10"; then
        log "Setting display sleep to 10 minutes"
        run sudo pmset -a displaysleep 10
    else
        log "Display sleep already set ✅"
    fi
    
    # Auto-restart on power loss
    if ! pmset -g | grep -q "autorestart.*1"; then
        log "Enabling auto-restart on power loss"
        run sudo pmset -a autorestart 1
    else
        log "Auto-restart already enabled ✅"
    fi
    
    # Wake on LAN
    if ! pmset -g | grep -q "womp.*1"; then
        log "Enabling Wake on LAN"
        run sudo pmset -a womp 1
    else
        log "Wake on LAN already enabled ✅"
    fi
    
    # Disable Power Nap
    if ! pmset -g | grep -q "powernap.*0"; then
        log "Disabling Power Nap"
        run sudo pmset -a powernap 0
    else
        log "Power Nap already disabled ✅"
    fi
    
    # Disable proximity wake
    if ! pmset -g | grep -q "proximitywake.*0"; then
        log "Disabling proximity wake"
        run sudo pmset -a proximitywake 0
    else
        log "Proximity wake already disabled ✅"
    fi
    
    # Disable auto macOS updates
    if ! defaults read /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates 2>/dev/null | grep -q "0"; then
        log "Disabling automatic macOS updates"
        run sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
    else
        log "Auto macOS updates already disabled ✅"
    fi
    
    # Keep RSR on (already default but confirm)
    run sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool true
    
    log "System configuration complete ✅"
}

phase_2() {
    CURRENT_PHASE="2"
    should_skip_phase 2 && { log "Skipping Phase 2 (--skip)"; return; }
    
    phase_banner 2 "FileVault"
    
    local fv_status
    fv_status=$(fdesetup status)
    
    if [[ "$fv_status" == *"FileVault is On"* ]] || [[ "$fv_status" == *"Encryption in progress"* ]]; then
        log "FileVault already enabled ✅"
    else
        log "Enabling FileVault..."
        echo "⚠️ FileVault will:"
        echo "   • Disable auto-login (you'll need to enter password on boot)"
        echo "   • Generate a recovery key (SAVE IT SECURELY)"
        echo "   • Encrypt the disk in background (may take hours)"
        echo ""
        
        run sudo fdesetup enable
        
        pause "SAVE YOUR RECOVERY KEY NOW. Store it in a password manager or print it. Do NOT store it on this Mac."
        
        # Verify
        local fv_after
        fv_after=$(fdesetup status)
        if [[ "$fv_after" == *"FileVault is On"* ]] || [[ "$fv_after" == *"Encryption in progress"* ]]; then
            log "FileVault enabled ✅"
        else
            die "FileVault activation failed: $fv_after"
        fi
    fi
}

phase_3() {
    CURRENT_PHASE="3"
    should_skip_phase 3 && { log "Skipping Phase 3 (--skip)"; return; }
    
    phase_banner 3 "Remote Access"
    
    # Enable SSH
    if [[ "$(sudo systemsetup -getremotelogin)" == *"Off"* ]]; then
        log "Enabling SSH"
        run sudo systemsetup -setremotelogin on
    else
        log "SSH already enabled ✅"
    fi
    
    # Enable Screen Sharing
    if ! launchctl print system/com.apple.screensharing &>/dev/null; then
        log "Enabling Screen Sharing"
        run sudo launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null
        local screen_share_exit=$?
        
        if [ $screen_share_exit -ne 0 ] && [ $screen_share_exit -ne 36 ]; then
            if ! launchctl print system/com.apple.screensharing &>/dev/null; then
                echo "⚠️ Automatic Screen Sharing setup failed."
                echo "   Enable manually: System Settings → General → Sharing → Screen Sharing → ON"
                pause "Enable Screen Sharing manually."
            fi
        fi
    else
        log "Screen Sharing already enabled ✅"
    fi
    
    # Print SSH host fingerprint
    echo ""
    echo "━━━ SSH Host Fingerprint ━━━"
    ssh-keygen -l -f /etc/ssh/ssh_host_ed25519_key.pub
    echo "Verify this matches when connecting from your other devices."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    log "Remote access setup complete ✅"
}

phase_4() {
    CURRENT_PHASE="4"
    should_skip_phase 4 && { log "Skipping Phase 4 (--skip)"; return; }
    
    phase_banner 4 "Dependencies"
    
    # 4.1 Xcode Command Line Tools
    if ! xcode-select -p &>/dev/null; then
        log "Installing Xcode Command Line Tools..."
        
        # Try non-interactive install first
        run touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
        local clt_package
        clt_package=$(softwareupdate --list 2>&1 | grep -i "command line tools" | grep -i "label" | sed 's/.*Label: //' | head -1)
        
        if [ -n "$clt_package" ]; then
            log "Installing via softwareupdate (non-interactive)..."
            run softwareupdate --install "$clt_package" --verbose
        else
            # Fallback: GUI dialog
            log "Triggering GUI install dialog..."
            run xcode-select --install
            echo ""
            echo "⏸️  If running via SSH: someone must click 'Install' on the Mac's screen."
            echo "   If running locally: click 'Install' in the dialog that appeared."
            pause "Press Enter after Xcode CLT finishes installing..."
        fi
        
        run rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
        
        # Verify installation
        if ! xcode-select -p &>/dev/null; then
            die "Xcode Command Line Tools installation failed"
        fi
    else
        log "Xcode Command Line Tools already installed ✅"
    fi
    
    # 4.2 Homebrew
    detect_paths
    if [ -z "$BREW_BIN" ]; then
        log "Installing Homebrew..."
        if [ "$DRY_RUN" != "true" ]; then
            /bin/bash -c "$($CURL_BIN -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || die "Homebrew installation failed"
            
            # Add to PATH
            eval "$(/opt/homebrew/bin/brew shellenv)"
            if ! grep -q 'brew shellenv' ~/.zprofile 2>/dev/null; then
                echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
            fi
        else
            echo "[DRY] Would install Homebrew"
        fi
        
        detect_paths
        [ -z "$BREW_BIN" ] && die "Homebrew installation failed - brew not found in PATH"
    else
        log "Homebrew already installed ✅"
    fi
    
    # 4.3 jq (MUST come before Node for version check)
    detect_paths
    if [ -z "$JQ_BIN" ]; then
        log "Installing jq..."
        run "$BREW_BIN" install jq
        detect_paths
        [ -z "$JQ_BIN" ] && die "jq installation failed"
    else
        log "jq already installed ✅"
    fi
    
    # 4.4 Node.js (uses jq for version check)
    detect_paths
    if [ -z "$NODE_BIN" ] || ! [[ "$(node --version 2>/dev/null)" == v22.* ]]; then
        log "Installing Node.js 22..."
        
        # Check Homebrew's default Node version
        local brew_node_ver
        brew_node_ver=$("$BREW_BIN" info --json=v2 node | "$JQ_BIN" -r '.formulae[0].versions.stable')
        
        local node_formula
        if [[ "$brew_node_ver" == 22.* ]]; then
            run "$BREW_BIN" install node
            node_formula="node"
        else
            log "Homebrew's default Node is $brew_node_ver — using node@22 instead"
            run "$BREW_BIN" install node@22
            
            # node@22 is keg-only — add to PATH
            if ! grep -q 'node@22' ~/.zprofile 2>/dev/null; then
                echo 'export PATH="/opt/homebrew/opt/node@22/bin:$PATH"' >> ~/.zprofile
            fi
            export PATH="/opt/homebrew/opt/node@22/bin:$PATH"
            node_formula="node@22"
        fi
        
        run "$BREW_BIN" pin "$node_formula" || echo "⚠️ Failed to pin $node_formula"
        
        # Verify correct node is active
        detect_paths
        local active_node
        active_node=$(node --version 2>/dev/null || echo "none")
        if [[ "$active_node" != v22.* ]]; then
            echo "⚠️ Active node is $active_node, not 22.x."
            echo "   PATH may need adjustment. Brew node@22 is at: /opt/homebrew/opt/node@22/bin/node"
            echo "   Current: $(which node 2>/dev/null || echo 'not found')"
        else
            log "Node.js $active_node installed ✅"
        fi
    else
        log "Node.js 22.x already installed ✅"
    fi
    
    # 4.5 GitHub CLI (conditional on GITHUB_REPO)
    if [ -n "$GITHUB_REPO" ]; then
        if ! command -v gh &>/dev/null; then
            log "Installing GitHub CLI..."
            run "$BREW_BIN" install gh
            
            log "Authenticating with GitHub..."
            pause "About to run 'gh auth login' - complete the browser authentication."
            run gh auth login
        else
            log "GitHub CLI already installed ✅"
        fi
    else
        log "No GITHUB_REPO configured. Skipping GitHub CLI installation."
        echo "⚠️ Workspace disaster recovery will depend on Time Machine only."
    fi
    
    log "Dependencies installation complete ✅"
}

phase_5() {
    CURRENT_PHASE="5"
    should_skip_phase 5 && { log "Skipping Phase 5 (--skip)"; return; }
    
    phase_banner 5 "Install Tools"
    
    detect_paths
    [ -z "$NPM_BIN" ] && die "npm not found. Run Phase 4 first."
    
    # 5.1 OpenClaw
    if [ -z "$OPENCLAW_BIN" ]; then
        log "Installing OpenClaw..."
        run "$NPM_BIN" install -g openclaw@latest
        
        detect_paths
        [ -z "$OPENCLAW_BIN" ] && die "OpenClaw installation failed - openclaw not found in PATH"
        
        local openclaw_version
        openclaw_version=$("$OPENCLAW_BIN" --version 2>/dev/null || echo "unknown")
        log "OpenClaw $openclaw_version installed ✅"
    else
        log "OpenClaw already installed ✅"
    fi
    
    # 5.2 Claude Code CLI
    if [ "$SKIP_CLAUDE_CLI" != "true" ]; then
        if [ -z "$CLAUDE_BIN" ]; then
            log "Installing Claude Code CLI..."
            run "$NPM_BIN" install -g @anthropic-ai/claude-code
            
            detect_paths
            [ -z "$CLAUDE_BIN" ] && die "Claude Code CLI installation failed - claude not found in PATH"
            
            local claude_version
            claude_version=$("$CLAUDE_BIN" --version 2>/dev/null || echo "unknown")
            log "Claude Code CLI $claude_version installed ✅"
        else
            log "Claude Code CLI already installed ✅"
        fi
    else
        log "Skipping Claude Code CLI installation (--skip-claude-cli)"
    fi
    
    log "Tools installation complete ✅"
}

phase_6() {
    CURRENT_PHASE="6"
    should_skip_phase 6 && { log "Skipping Phase 6 (--skip)"; return; }
    
    phase_banner 6 "Auth Setup"
    
    detect_paths
    [ -z "$OPENCLAW_BIN" ] && die "openclaw not found. Run Phase 5 first."
    
    # Initialize SETUP_TOKEN_AUTO
    SETUP_TOKEN_AUTO=false
    
    # 6.0 Determine auth strategy
    local auth_mode
    if [ -n "$SETUP_TOKEN" ]; then
        auth_mode="token-provided"
        SETUP_TOKEN_AUTO=true
        log "Using provided setup token"
    elif [ -n "$CLAUDE_BIN" ]; then
        auth_mode="token-interactive"
        log "Will generate setup token interactively"
    else
        auth_mode="apikey-only"
        log "Claude CLI not available - using API key auth only"
        echo "⚠️ Daily auto-refresh will not be available."
    fi
    
    # 6.1 Setup Token
    if [ "$auth_mode" = "token-provided" ]; then
        log "Setting up provided token..."
        if [ "$DRY_RUN" != "true" ]; then
            echo "$SETUP_TOKEN" | "$OPENCLAW_BIN" models auth paste-token --provider anthropic || echo "⚠️ Token setup failed"
        else
            echo "[DRY] Would set up provided token"
        fi
        
    elif [ "$auth_mode" = "token-interactive" ]; then
        log "Setting up token interactively..."
        echo "We need to set up authentication. This may open a browser."
        
        # Test if claude setup-token works non-interactively
        if [ "$DRY_RUN" != "true" ]; then
            local tmptoken
            tmptoken=$(mktemp /tmp/setup-token.XXXXXX)
            
            # Run claude setup-token with timeout
            "$CLAUDE_BIN" setup-token > "$tmptoken" 2>/dev/null &
            local token_pid=$!
            local token_wait=0
            while kill -0 $token_pid 2>/dev/null && [ $token_wait -lt 15 ]; do
                sleep 1
                token_wait=$((token_wait + 1))
            done
            
            if kill -0 $token_pid 2>/dev/null; then
                # Timed out — needs browser auth
                kill $token_pid 2>/dev/null
                wait $token_pid 2>/dev/null || true
                log "setup-token requires browser auth (timed out after 15s)"
                echo "Running interactively — complete the browser flow."
                "$CLAUDE_BIN" setup-token > "$tmptoken"
            else
                # Completed without timeout
                wait $token_pid
                if [ -s "$tmptoken" ]; then
                    log "setup-token works non-interactively ✅"
                    SETUP_TOKEN_AUTO=true
                else
                    log "setup-token returned empty output. Running interactively..."
                    "$CLAUDE_BIN" setup-token > "$tmptoken"
                fi
            fi
            
            # Feed token to OpenClaw
            if [ -s "$tmptoken" ]; then
                cat "$tmptoken" | "$OPENCLAW_BIN" models auth paste-token --provider anthropic
                log "Token configured ✅"
            else
                echo "⚠️ No token captured. Will try API key auth."
            fi
            
            rm -f "$tmptoken"
        else
            echo "[DRY] Would run claude setup-token interactively"
            SETUP_TOKEN_AUTO=true  # Assume it would work for dry run
        fi
    fi
    
    # 6.2 Fallback API Key
    if [ -n "$ANTHROPIC_API_KEY" ]; then
        log "Setting up fallback API key..."
        if [ "$DRY_RUN" != "true" ]; then
            echo "$ANTHROPIC_API_KEY" | "$OPENCLAW_BIN" models auth add --provider anthropic --name "api-key-fallback" || echo "⚠️ API key setup failed"
        else
            echo "[DRY] Would set up API key"
        fi
    elif [ "$auth_mode" = "apikey-only" ]; then
        if [ "$DRY_RUN" != "true" ]; then
            read -rp "Enter your Anthropic API key (from console.anthropic.com): " api_key
            if [ -n "$api_key" ]; then
                echo "$api_key" | "$OPENCLAW_BIN" models auth add --provider anthropic --name "api-key-fallback"
                log "API key configured ✅"
            else
                die "No API key provided and no setup token. Cannot continue without authentication."
            fi
        else
            echo "[DRY] Would prompt for API key"
        fi
    fi
    
    # 6.3 Verify Auth
    if [ "$DRY_RUN" != "true" ]; then
        log "Verifying authentication..."
        "$OPENCLAW_BIN" models status --check
        local auth_status=$?
        
        case $auth_status in
            0) log "Auth healthy ✅" ;;
            1) die "Auth failed - no valid token or API key found" ;;
            2) log "Auth valid but expiring within 24h ⚠️" ;;
            *) log "Unexpected auth status: $auth_status" ;;
        esac
    else
        echo "[DRY] Would verify authentication"
    fi
    
    # 6.4 Live Verification (small API call)
    if [ "$DRY_RUN" != "true" ]; then
        log "Testing live API connection..."
        if "$OPENCLAW_BIN" models status --probe; then
            log "Live API test successful ✅"
        else
            echo "⚠️ Live API test failed. Check your internet connection and auth."
        fi
    else
        echo "[DRY] Would test live API connection"
    fi
    
    log "Auth setup complete (auto-refresh: $SETUP_TOKEN_AUTO) ✅"
}

phase_7() {
    CURRENT_PHASE="7"
    should_skip_phase 7 && { log "Skipping Phase 7 (--skip)"; return; }
    
    phase_banner 7 "Config & Workspace"
    
    detect_paths
    [ -z "$OPENCLAW_BIN" ] && die "openclaw not found. Run Phase 5 first."
    [ -z "$JQ_BIN" ] && die "jq not found. Run Phase 4 first."
    
    # 7.1 Generate openclaw.json
    log "Configuring OpenClaw..."
    
    # Ensure directory exists
    run mkdir -p ~/.openclaw

    if [ "$DRY_RUN" != "true" ]; then
        # Deferred bot token extraction (jq now available)
        if [ -z "$TELEGRAM_BOT_TOKEN" ] && [ -f "$CONFIG_BACKUP" ]; then
            local extracted_token
            extracted_token=$("$JQ_BIN" -r '.channels.telegram.botToken // ""' "$CONFIG_BACKUP" 2>/dev/null)
            if [ -n "$extracted_token" ]; then
                TELEGRAM_BOT_TOKEN="$extracted_token"
                log "Bot token extracted from config backup ✅"
            fi
        fi
        
        # Config merge or fresh generation
        if [ -f "$CONFIG_BACKUP" ] && "$JQ_BIN" empty "$CONFIG_BACKUP" 2>/dev/null; then
            log "Using existing config as base"
            run cp "$CONFIG_BACKUP" ~/.openclaw/openclaw.json
            
            # Merge/ensure critical fields
            "$JQ_BIN" \
                --arg gwToken "$GATEWAY_TOKEN" \
                --arg botToken "$TELEGRAM_BOT_TOKEN" \
                --argjson chatId "$TELEGRAM_CHAT_ID" \
                '
                # Compaction settings
                .agents.defaults.compaction.reserveTokensFloor = (
                    if (.agents.defaults.compaction.reserveTokensFloor // 0) < 16000
                    then 16000
                    else .agents.defaults.compaction.reserveTokensFloor
                    end
                ) |
                .agents.defaults.compaction.maxHistoryShare = (
                    .agents.defaults.compaction.maxHistoryShare // 0.7
                ) |
                
                # Context pruning
                .agents.defaults.contextPruning = (
                    .agents.defaults.contextPruning // {
                        "mode": "cache-ttl",
                        "ttl": "10m",
                        "keepLastAssistants": 2,
                        "softTrimRatio": 0.6,
                        "hardClearRatio": 0.8,
                        "minPrunableToolChars": 500
                    }
                ) |
                
                # Internal hooks
                .hooks.internal.enabled = true |
                
                # Commands
                .commands.native = (.commands.native // "auto") |
                .commands.nativeSkills = (.commands.nativeSkills // "auto") |
                
                # Telegram
                .channels.telegram.botToken = (if $botToken != "" then $botToken else .channels.telegram.botToken end) |
                .channels.telegram.allowFrom = [$chatId] |
                
                # Gateway token
                .gateway.auth.token = (
                    if (.gateway.auth.token // "") != ""
                    then .gateway.auth.token
                    else $gwToken
                    end
                )
                ' ~/.openclaw/openclaw.json > /tmp/openclaw-merged.json || die "Config merge failed"
            
            run mv /tmp/openclaw-merged.json ~/.openclaw/openclaw.json
            
        else
            log "Generating fresh config"
            "$JQ_BIN" -n \
                --arg botToken "$TELEGRAM_BOT_TOKEN" \
                --argjson chatId "$TELEGRAM_CHAT_ID" \
                --arg gwToken "$GATEWAY_TOKEN" \
                '{
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
                            "botToken": $botToken,
                            "dmPolicy": "allowlist",
                            "allowFrom": [$chatId],
                            "groupPolicy": "allowlist",
                            "streamMode": "partial"
                        }
                    },
                    "gateway": {
                        "mode": "local",
                        "auth": {
                            "token": $gwToken
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
                }' > ~/.openclaw/openclaw.json || die "Fresh config generation failed"
        fi
    else
        echo "[DRY] Would generate/merge OpenClaw config"
        # Still do bot token extraction in dry-run (read-only operation)
        if [ -z "$TELEGRAM_BOT_TOKEN" ] && [ -f "$CONFIG_BACKUP" ] && [ -n "$JQ_BIN" ]; then
            local extracted_token
            extracted_token=$("$JQ_BIN" -r '.channels.telegram.botToken // ""' "$CONFIG_BACKUP" 2>/dev/null)
            if [ -n "$extracted_token" ]; then
                TELEGRAM_BOT_TOKEN="$extracted_token"
                log "Bot token extracted from config backup ✅"
            fi
        fi
    fi
    
    # 7.2 Restore Workspace
    if [ -f "$WORKSPACE_BACKUP" ]; then
        log "Restoring workspace from backup..."
        run mkdir -p ~/.openclaw/workspace
        
        if [ "$DRY_RUN" != "true" ]; then
            cd ~/.openclaw/workspace || die "Failed to cd to workspace"
            tar xzf "$WORKSPACE_BACKUP" || die "Failed to extract workspace backup"
            
            # Validation and fix nested structure
            if [ ! -f ~/.openclaw/workspace/SOUL.md ]; then
                log "SOUL.md not found after extraction"
                if [ -f ~/.openclaw/workspace/workspace/SOUL.md ]; then
                    log "Found nested workspace/ directory. Fixing..."
                    mv ~/.openclaw/workspace/workspace/* ~/.openclaw/workspace/
                    rmdir ~/.openclaw/workspace/workspace 2>/dev/null || true
                else
                    log "⚠️ Workspace backup may be empty or corrupt"
                fi
            else
                log "Workspace restored ✅"
            fi
        else
            echo "[DRY] Would extract workspace backup"
        fi
        
    else
        log "No workspace backup found at $WORKSPACE_BACKUP"
        echo "⚠️ This is a migration script — a workspace backup is expected."
        echo "   Without it, Kai starts with an empty workspace (no SOUL.md, no memories)."
        
        confirm "Continue with empty workspace? [y/N]" || die "Create a workspace backup on the old machine first. See Prerequisites."
        
        run mkdir -p ~/.openclaw/workspace
    fi
    
    # 7.3 Git Init
    if [ "$DRY_RUN" != "true" ]; then
        cd ~/.openclaw/workspace || die "Failed to cd to workspace"
        
        if ! git rev-parse --is-inside-work-tree &>/dev/null; then
            log "Initializing git repository..."
            
            # Create .gitignore first
            cat > ~/.openclaw/workspace/.gitignore << 'GITIGNORE_EOF'
.DS_Store
*.log
*.jsonl
*.tmp
node_modules/
GITIGNORE_EOF
            
            git init
            git add SOUL.md MEMORY.md USER.md IDENTITY.md TOOLS.md AGENTS.md HEARTBEAT.md 2>/dev/null || true
            git add guides/ memory/ .gitignore 2>/dev/null || true
            git branch -M main
            git commit -m "Initial workspace migration" || die "Git commit failed"
            
            log "Git repository initialized ✅"
        else
            log "Git repository already exists ✅"
        fi
    else
        echo "[DRY] Would initialize git repository"
    fi
    
    # 7.4 Git Remote
    if [ -n "$GITHUB_REPO" ]; then
        if [ "$DRY_RUN" != "true" ]; then
            cd ~/.openclaw/workspace || die "Failed to cd to workspace"
            
            git remote add origin "$GITHUB_REPO" 2>/dev/null || git remote set-url origin "$GITHUB_REPO"
            
            if git push -u origin main; then
                log "Git remote configured and pushed ✅"
            else
                echo "⚠️ Git push failed. Check your GitHub auth (gh auth login) and repo URL."
                echo "You can fix this later. Continuing..."
            fi
        else
            echo "[DRY] Would configure git remote and push"
        fi
    else
        log "No git remote configured. Disaster recovery depends on Time Machine only."
        echo "⚠️ This is risky - consider setting GITHUB_REPO."
    fi
    
    # Note: Phase 7.4 doesn't need the git remote get-url guard used in Phase 12.1
    # because the remote was just configured above (only runs when GITHUB_REPO is set).
    
    log "Config & workspace setup complete ✅"
}

phase_8() {
    CURRENT_PHASE="8"
    should_skip_phase 8 && { log "Skipping Phase 8 (--skip)"; return; }
    
    phase_banner 8 "Gateway Start & Verify"
    
    detect_paths
    [ -z "$OPENCLAW_BIN" ] && die "openclaw not found. Run Phase 5 first."
    
    # 8.0 Pre-check: No conflicting gateway
    if [ "$DRY_RUN" != "true" ]; then
        if "$OPENCLAW_BIN" gateway status &>/dev/null; then
            echo "⚠️ An OpenClaw gateway is already running on this machine."
            if confirm "Stop it and continue? [y/N]"; then
                "$OPENCLAW_BIN" gateway stop || die "Failed to stop existing gateway"
            else
                die "Stop the existing gateway first"
            fi
        fi
    else
        echo "[DRY] Would check for existing gateway"
    fi
    
    # 8.1 Install Daemon
    log "Installing daemon..."
    run "$OPENCLAW_BIN" gateway install
    
    # 8.2 Run Doctor
    log "Running health check..."
    run "$OPENCLAW_BIN" doctor --non-interactive
    
    # 8.3 Start Gateway
    log "Starting gateway..."
    run "$OPENCLAW_BIN" gateway start
    
    if [ "$DRY_RUN" != "true" ]; then
        sleep 10
        if "$OPENCLAW_BIN" gateway status &>/dev/null; then
            log "Gateway started successfully ✅"
        else
            die "Gateway failed to start"
        fi
    else
        echo "[DRY] Would wait and verify gateway status"
    fi
    
    # 8.4 Test Telegram
    log "Testing Telegram integration..."
    
    if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
        log "⚠️ TELEGRAM_BOT_TOKEN is empty. Skipping Telegram test."
        echo "   Configure botToken in openclaw.json manually."
    else
        echo "ℹ️  If this is a NEW bot, send /start to it in Telegram first."
        
        if [ "$DRY_RUN" != "true" ]; then
            local response
            response=$("$CURL_BIN" -s --max-time 10 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
                --data-urlencode "text=🎉 Kai is live on the Mac Mini! Setup script Phase 8 complete." \
                -w "\n%{http_code}" 2>/dev/null)
            
            local http_code
            http_code=$(echo "$response" | tail -1)
            
            if [ "$http_code" = "200" ]; then
                log "Telegram message sent successfully ✅"
                echo "✅ Check your phone for the test message."
            else
                echo "⚠️ Telegram API returned HTTP $http_code."
                echo "   Common causes: new bot (need /start), wrong bot token, wrong chat ID."
                echo "   This isn't fatal — the gateway may still work. Test by messaging the bot."
            fi
        else
            echo "[DRY] Would send test message to Telegram"
        fi
        
        pause "Reply to the bot to verify two-way communication."
    fi
    
    # 8.5 Verify Daemon Persistence
    if [ "$DRY_RUN" != "true" ]; then
        log "Testing daemon auto-restart..."
        
        local gateway_pid
        gateway_pid=$(pgrep -f "openclaw.*gateway" | head -1)
        if [ -z "$gateway_pid" ]; then
            gateway_pid=$(pgrep -f "node.*openclaw" | head -1)
        fi
        
        if [ -n "$gateway_pid" ]; then
            kill -9 "$gateway_pid"
            log "Killed PID $gateway_pid. Waiting 10s for launchd restart..."
            sleep 10
            
            if "$OPENCLAW_BIN" gateway status &>/dev/null; then
                log "Gateway auto-restarted after crash ✅"
            else
                echo "⚠️ Gateway didn't restart. Check: launchctl list | grep openclaw"
            fi
        else
            echo "⚠️ Could not find gateway PID. Verify manually:"
            echo "   openclaw gateway status"
            echo "   kill -9 <PID>; sleep 10; openclaw gateway status"
        fi
    else
        echo "[DRY] Would test daemon persistence"
    fi
    
    log "Gateway verification complete ✅"
}

phase_9() {
    CURRENT_PHASE="9"
    should_skip_phase 9 && { log "Skipping Phase 9 (--skip)"; return; }
    
    phase_banner 9 "Maintenance Automation"
    
    detect_paths
    [ -z "$OPENCLAW_BIN" ] && die "openclaw not found. Run Phase 5 first."
    [ -z "$NPM_BIN" ] && die "npm not found. Run Phase 4 first."
    [ -z "$JQ_BIN" ] && die "jq not found. Run Phase 4 first."
    [ -z "$CURL_BIN" ] && die "curl not found."
    
    if [ -z "$CLAUDE_BIN" ]; then
        echo "⚠️ Claude CLI not found. Auto-refresh won't work in maintenance script."
    fi
    
    # 9.1 Generate daily-maintenance.sh
    log "Generating maintenance script..."
    run mkdir -p ~/.openclaw/scripts
    
    if [ "$DRY_RUN" != "true" ]; then
        cat > ~/.openclaw/scripts/daily-maintenance.sh << MAINT_EOF
#!/bin/bash
# Daily maintenance: token health check + OpenClaw auto-update
# Generated by mac-mini-setup.sh on $(date -u)
# Runs at ${MAINTENANCE_HOUR}:$(printf '%02d' $MAINTENANCE_MINUTE) daily via launchd

set -uo pipefail
# NOTE: Do NOT use set -e here. This script checks exit codes explicitly
# (\$?), and set -e would kill the script on non-zero exits before we can
# read them (e.g. models status --check returns 1/2 when token is expiring).

# === CONFIGURED PATHS (generated at setup time) ===
OPENCLAW="$OPENCLAW_BIN"
CLAUDE="$CLAUDE_BIN"
NPM="$NPM_BIN"
JQ="$JQ_BIN"
CURL="$CURL_BIN"
OPENCLAW_HOME="$HOME/.openclaw"
HEALTHCHECKS_URL="$HEALTHCHECKS_PING_URL"
SETUP_TOKEN_AUTO=$SETUP_TOKEN_AUTO
# ==================================================

LOG="\$OPENCLAW_HOME/logs/daily-maintenance.log"
MAX_LOG_SIZE=2097152  # 2MB
mkdir -p "\$(dirname "\$LOG")"

# Log rotation
if [ -f "\$LOG" ] && [ "\$(stat -f%z "\$LOG" 2>/dev/null || echo 0)" -gt "\$MAX_LOG_SIZE" ]; then
    tail -200 "\$LOG" > "\${LOG}.tmp" && mv "\${LOG}.tmp" "\$LOG"
fi

log() { echo "[\$(date -u '+%Y-%m-%d %H:%M:%S UTC')] \$1" >> "\$LOG"; }

alert_kamil() {
    local msg="\$1"

    # Primary: Direct Telegram API
    local BOT_TOKEN
    BOT_TOKEN=\$("\$JQ" -r '.channels.telegram.botToken // empty' "\$OPENCLAW_HOME/openclaw.json" 2>/dev/null)
    if [ -n "\$BOT_TOKEN" ]; then
        "\$CURL" -s "https://api.telegram.org/bot\${BOT_TOKEN}/sendMessage" \\
            --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \\
            --data-urlencode "text=\$msg" \\
            > /dev/null 2>&1 && return 0
    fi

    log "ALERT DELIVERY FAILED: \$msg"
    # Optional: ping healthchecks.io fail endpoint if configured
    if [ -n "\$HEALTHCHECKS_URL" ]; then
        "\$CURL" -fsS -m 10 "\${HEALTHCHECKS_URL}/fail" > /dev/null 2>&1 || true
    fi
}

needs_restart=false
UPDATE_SUCCESS=false
UPDATE_IN_PROGRESS=false
CURRENT_VERSION=""

# SIGTERM trap for mid-update safety
trap 'log "SIGTERM received"; if [ "\$UPDATE_IN_PROGRESS" = true ] && [ -n "\$CURRENT_VERSION" ]; then log "Rolling back mid-update..."; "\$NPM" install -g "openclaw@\$CURRENT_VERSION" 2>/dev/null || true; fi; exit 1' TERM

# Timeout wrapper for claude setup-token (macOS has no GNU timeout)
# Prevents script from hanging if setup-token requires browser auth
get_token_with_timeout() {
    "\$CLAUDE" setup-token 2>> "\$LOG" &
    local pid=\$!
    local timeout=30
    local count=0
    while kill -0 \$pid 2>/dev/null && [ \$count -lt \$timeout ]; do
        sleep 1
        count=\$((count + 1))
    done
    if kill -0 \$pid 2>/dev/null; then
        kill \$pid 2>/dev/null
        wait \$pid 2>/dev/null || true
        log "WARNING: claude setup-token timed out after \${timeout}s (likely needs browser auth)"
        echo ""  # return empty = failure
    else
        wait \$pid
    fi
}

log "=== Starting daily maintenance ==="

# PART 1: TOKEN HEALTH CHECK
log "Checking token health..."
"\$OPENCLAW" models status --check >> "\$LOG" 2>&1
TOKEN_STATUS=\$?

case \$TOKEN_STATUS in
    0)  log "Token is healthy. Skipping refresh."
        ;;
    1)  log "Token is expired or missing. Attempting refresh..."

        if [ "\$SETUP_TOKEN_AUTO" = "true" ] && [ -n "\$CLAUDE" ] && [ -x "\$CLAUDE" ]; then
            # Try automatic refresh (with timeout to prevent hanging)
            NEW_TOKEN=\$(get_token_with_timeout)

            if [ -n "\$NEW_TOKEN" ]; then
                echo "\$NEW_TOKEN" | "\$OPENCLAW" models auth paste-token --provider anthropic >> "\$LOG" 2>&1

                # Verify the new token
                "\$OPENCLAW" models status --check >> "\$LOG" 2>&1
                VERIFY=\$?
                if [ \$VERIFY -eq 0 ]; then
                    log "Token refresh successful ✅"
                    needs_restart=true
                else
                    log "ERROR: Token refresh completed but verification failed (exit: \$VERIFY)"
                    alert_kamil "⚠️ Kai token refresh failed verification. SSH in and run: claude setup-token + paste manually. Check logs: ~/.openclaw/logs/daily-maintenance.log"
                fi
            else
                log "ERROR: claude setup-token returned empty token (likely needs browser auth)"
                alert_kamil "⚠️ Kai token expired and auto-refresh failed (browser auth needed). SSH/VNC in and run: claude setup-token + paste manually. Using API key fallback until fixed."
            fi
        else
            log "ERROR: Token expired but auto-refresh not available (SETUP_TOKEN_AUTO=\$SETUP_TOKEN_AUTO, CLAUDE=\$CLAUDE)"
            alert_kamil "⚠️ Kai token expired. SSH/VNC in and run: claude setup-token + paste manually, or set up API key fallback."
        fi
        ;;
    2)  log "Token is expiring within 24h. Attempting refresh..."

        if [ "\$SETUP_TOKEN_AUTO" = "true" ] && [ -n "\$CLAUDE" ] && [ -x "\$CLAUDE" ]; then
            NEW_TOKEN=\$(get_token_with_timeout)

            if [ -n "\$NEW_TOKEN" ]; then
                echo "\$NEW_TOKEN" | "\$OPENCLAW" models auth paste-token --provider anthropic >> "\$LOG" 2>&1
                needs_restart=true
                log "Token preventive refresh successful ✅"
            else
                log "WARNING: Preventive refresh failed, but token still valid for <24h"
                alert_kamil "⚠️ Kai token expires within 24h and auto-refresh failed. SSH/VNC in soon to run: claude setup-token + paste manually."
            fi
        else
            log "WARNING: Token expiring but auto-refresh not available"
            alert_kamil "⚠️ Kai token expires within 24h. SSH/VNC in to refresh: claude setup-token + paste manually."
        fi
        ;;
    *)  log "Unexpected token status exit code: \$TOKEN_STATUS"
        ;;
esac

# PART 2: OPENCLAW UPDATE CHECK
log "Checking for OpenClaw updates..."

# Record current version for rollback
CURRENT_VERSION=\$("\$NPM" list -g openclaw --json 2>/dev/null | "\$JQ" -r '.dependencies.openclaw.version // empty')
if [ -z "\$CURRENT_VERSION" ]; then
    CURRENT_VERSION=\$("\$OPENCLAW" --version 2>/dev/null | grep -oE '[0-9]+\\.[0-9]+\\.[0-9]+' | head -1 || echo "unknown")
fi
log "Current OpenClaw version: \$CURRENT_VERSION"

if [ "\$CURRENT_VERSION" = "unknown" ] || [ -z "\$CURRENT_VERSION" ]; then
    log "ERROR: Cannot determine current version. Skipping update (rollback would be impossible)."
    alert_kamil "⚠️ OpenClaw auto-update skipped: couldn't determine current version. SSH in and check."
else
    # Check if update is available
    LATEST_VERSION=\$("\$NPM" view openclaw version 2>/dev/null || echo "")
    if [ -z "\$LATEST_VERSION" ]; then
        log "Failed to check npm registry. Network issue? Skipping update check."
    elif [ "\$CURRENT_VERSION" = "\$LATEST_VERSION" ]; then
        log "Already on latest version (\$LATEST_VERSION). No update needed."
    else
        log "Update available: \$CURRENT_VERSION → \$LATEST_VERSION"

        # Check for version hold
        if [ -f "\$OPENCLAW_HOME/HOLD_VERSION" ]; then
            log "Found HOLD_VERSION file. Skipping automatic update."
            alert_kamil "📌 OpenClaw update available (\$CURRENT_VERSION → \$LATEST_VERSION) but HOLD_VERSION file present. Delete ~/.openclaw/HOLD_VERSION to resume auto-updates."
        else
            # Install the update
            UPDATE_IN_PROGRESS=true
            log "Installing openclaw@latest..."
            "\$NPM" install -g openclaw@latest >> "\$LOG" 2>&1
            INSTALL_EXIT=\$?

            if [ \$INSTALL_EXIT -ne 0 ]; then
                log "ERROR: npm install failed (exit \$INSTALL_EXIT)"
                UPDATE_IN_PROGRESS=false
                alert_kamil "⚠️ OpenClaw auto-update failed during npm install. SSH in and check: ~/.openclaw/logs/daily-maintenance.log"
            else
                NEW_VERSION=\$("\$OPENCLAW" --version 2>/dev/null || echo "unknown")
                log "Installed version: \$NEW_VERSION"

                # Run doctor (handles config migrations) - non-interactive mode
                log "Running openclaw doctor..."
                "\$OPENCLAW" doctor --non-interactive >> "\$LOG" 2>&1
                DOCTOR_EXIT=\$?
                if [ \$DOCTOR_EXIT -ne 0 ]; then
                    log "WARNING: doctor found issues (exit \$DOCTOR_EXIT). May need manual review."
                    alert_kamil "⚠️ OpenClaw updated to \$NEW_VERSION but doctor found issues. SSH in and run: openclaw doctor --fix if needed. Check logs: ~/.openclaw/logs/daily-maintenance.log"
                fi

                UPDATE_IN_PROGRESS=false
                needs_restart=true
                UPDATE_SUCCESS=true
            fi
        fi
    fi
fi

# PART 3: SINGLE RESTART & VERIFICATION
if [ "\$needs_restart" = true ]; then
    log "Restarting gateway (token refresh or update)..."
    "\$OPENCLAW" gateway restart >> "\$LOG" 2>&1
    sleep 10

    # Post-restart health checks
    "\$OPENCLAW" gateway status >> "\$LOG" 2>&1
    GATEWAY_OK=\$?

    "\$OPENCLAW" models status --check >> "\$LOG" 2>&1
    POST_TOKEN_STATUS=\$?

    if [ \$GATEWAY_OK -ne 0 ] || [ \$POST_TOKEN_STATUS -eq 1 ]; then
        log "ERROR: Post-restart health check failed (gateway: \$GATEWAY_OK, auth: \$POST_TOKEN_STATUS)"

        # If we updated, try rolling back
        if [ "\$UPDATE_SUCCESS" = true ] && [ -n "\$CURRENT_VERSION" ] && [ "\$CURRENT_VERSION" != "unknown" ]; then
            log "Rolling back OpenClaw to \$CURRENT_VERSION..."
            "\$NPM" install -g "openclaw@\$CURRENT_VERSION" >> "\$LOG" 2>&1
            "\$OPENCLAW" gateway restart >> "\$LOG" 2>&1
            sleep 5

            ROLLBACK_VERSION=\$("\$OPENCLAW" --version 2>/dev/null || echo "unknown")
            log "Rolled back to: \$ROLLBACK_VERSION"

            # Verify rollback succeeded
            if [ "\$ROLLBACK_VERSION" != "\$CURRENT_VERSION" ]; then
                log "ERROR: Rollback verification failed. Expected \$CURRENT_VERSION, got \$ROLLBACK_VERSION"
                alert_kamil "⚠️ OpenClaw rollback failed. Expected \$CURRENT_VERSION, got \$ROLLBACK_VERSION. Manual intervention needed."
            else
                alert_kamil "⚠️ OpenClaw update to \$NEW_VERSION failed health checks. Auto-rolled back to \$CURRENT_VERSION. Check logs: ~/.openclaw/logs/daily-maintenance.log"
            fi
        else
            alert_kamil "⚠️ OpenClaw gateway failed health checks after maintenance. SSH in and investigate. Check logs: ~/.openclaw/logs/daily-maintenance.log"
        fi
    else
        if [ "\$UPDATE_SUCCESS" = true ]; then
            log "Update successful: \$CURRENT_VERSION → \$NEW_VERSION ✅"
            # Only alert on updates, not routine token refresh
            alert_kamil "✅ OpenClaw updated: \$CURRENT_VERSION → \$NEW_VERSION"
        else
            log "Daily maintenance completed successfully"
        fi
    fi
else
    log "Daily maintenance completed - no restart needed"
fi

# Optional: Ping healthchecks.io success endpoint
if [ -n "\$HEALTHCHECKS_URL" ]; then
    "\$CURL" -fsS -m 10 "\$HEALTHCHECKS_URL" > /dev/null 2>&1 || log "Failed to ping healthchecks.io"
fi

log "=== Daily maintenance finished ==="
MAINT_EOF

        chmod +x ~/.openclaw/scripts/daily-maintenance.sh
        log "Maintenance script generated ✅"
    else
        echo "[DRY] Would generate maintenance script"
    fi
    
    # 9.2 Generate launchd plist
    log "Generating launchd plist..."
    
    if [ "$DRY_RUN" != "true" ]; then
        cat > ~/Library/LaunchAgents/com.openclaw.daily-maintenance.plist << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.openclaw.daily-maintenance</string>
    
    <key>Program</key>
    <string>$HOME/.openclaw/scripts/daily-maintenance.sh</string>
    
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>$MAINTENANCE_HOUR</integer>
        <key>Minute</key>
        <integer>$MAINTENANCE_MINUTE</integer>
    </dict>
    
    <key>StandardOutPath</key>
    <string>$HOME/.openclaw/logs/daily-maintenance.stdout</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.openclaw/logs/daily-maintenance.stderr</string>
    
    <key>TimeOut</key>
    <integer>600</integer>
    
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>$HOME</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/opt/homebrew/opt/node@22/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
PLIST_EOF
        
        log "Launchd plist generated ✅"
    else
        echo "[DRY] Would generate launchd plist"
    fi
    
    # 9.3 Load plist
    log "Loading maintenance plist..."
    if [ "$DRY_RUN" != "true" ]; then
        launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.openclaw.daily-maintenance.plist 2>/dev/null
        local maint_boot_exit=$?
        
        if [ $maint_boot_exit -ne 0 ] && [ $maint_boot_exit -ne 36 ]; then
            echo "⚠️ Failed to load maintenance plist (exit $maint_boot_exit)."
            echo "   Try: launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.openclaw.daily-maintenance.plist"
        else
            log "Maintenance plist loaded ✅"
        fi
    else
        echo "[DRY] Would load maintenance plist"
    fi
    
    # 9.4 Test
    log "Testing maintenance script..."
    if [ "$DRY_RUN" != "true" ]; then
        echo "Running maintenance script once to verify it works..."
        ~/.openclaw/scripts/daily-maintenance.sh || echo "⚠️ Maintenance script test had issues. Check logs."
        log "Maintenance script test complete"
    else
        echo "[DRY] Would test maintenance script"
    fi
    
    log "Maintenance automation setup complete ✅"
}

phase_10() {
    CURRENT_PHASE="10"
    should_skip_phase 10 && { log "Skipping Phase 10 (--skip)"; return; }
    
    phase_banner 10 "Tailscale"
    
    detect_paths
    [ -z "$BREW_BIN" ] && die "brew not found. Run Phase 4 first."
    
    # 10.1 Install
    if [ ! -d "/Applications/Tailscale.app" ] && ! command -v tailscale &>/dev/null; then
        log "Installing Tailscale..."
        run "$BREW_BIN" install --cask tailscale
    else
        log "Tailscale already installed ✅"
    fi
    
    # 10.2 Start & Auth
    log "Starting Tailscale..."
    run open /Applications/Tailscale.app
    
    pause "Authenticate Tailscale in the browser. Press Enter when connected..."
    
    # 10.3 Record IP
    if [ "$DRY_RUN" != "true" ]; then
        local tailscale_ip
        if command -v tailscale &>/dev/null; then
            tailscale_ip=$(tailscale ip -4 2>/dev/null || echo "not connected")
            
            if [ "$tailscale_ip" != "not connected" ]; then
                log "Tailscale connected: $tailscale_ip ✅"
                echo ""
                echo "━━━ Tailscale Access ━━━"
                echo "Your Mac Mini's Tailscale IP: $tailscale_ip"
                echo ""
                echo "Install Tailscale on your PC and phone, then test:"
                echo "  SSH: ssh $(whoami)@$tailscale_ip"
                echo "  Control UI: http://$tailscale_ip:18789"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
            else
                echo "⚠️ Tailscale not connected yet. Check the app."
            fi
        else
            echo "⚠️ Tailscale command not found after install."
        fi
    else
        echo "[DRY] Would check and display Tailscale IP"
    fi
    
    log "Tailscale setup complete ✅"
}

phase_11() {
    CURRENT_PHASE="11"
    should_skip_phase 11 && { log "Skipping Phase 11 (--skip)"; return; }
    
    phase_banner 11 "Security Hardening"
    
    # Check if Tailscale is available
    if ! command -v tailscale &>/dev/null || ! tailscale status &>/dev/null 2>&1; then
        echo "⚠️ Tailscale is not set up. Without it, SSH lockout recovery requires"
        echo "   physical keyboard access to this Mac Mini."
        confirm "Continue with security hardening anyway? [y/N]" || {
            log "Skipping Phase 11. Run Phase 10 first, then: $0 --phase 11"
            return
        }
    fi
    
    # 11.1 File Permissions
    log "Setting file permissions..."
    run chmod 700 ~/.openclaw/
    run chmod 600 ~/.openclaw/openclaw.json
    
    if [ "$DRY_RUN" != "true" ]; then
        find ~/.openclaw/agents/*/agent/ -name "auth-profiles.json" -exec chmod 600 {} \; 2>/dev/null || true
    else
        echo "[DRY] Would set auth-profiles.json permissions"
    fi
    
    # 11.2 SSH Key Setup
    echo ""
    echo "━━━ Mac Mini SSH Host Fingerprint ━━━"
    ssh-keygen -l -f /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null || echo "⚠️ Could not read host fingerprint"
    echo "Verify this matches when connecting from your other devices."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    echo "SSH key setup required. On each device you want to connect from:"
    echo ""
    echo "  From your PC:"
    echo "    ssh-keygen -t ed25519 -C \"your-pc\"          # if no key exists"
    local local_ip
    local_ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "LOCAL_IP")
    local tailscale_ip
    tailscale_ip=$(tailscale ip -4 2>/dev/null || echo "TAILSCALE_IP")
    echo "    ssh-copy-id $(whoami)@$tailscale_ip"
    echo ""
    echo "  From your phone (Termius, Blink, etc.):"
    echo "    Generate an ed25519 key in the app"
    echo "    Copy the public key to this Mac's ~/.ssh/authorized_keys"
    echo ""
    
    pause "Test SSH key login from ALL devices before continuing."
    
    # 11.3 Disable Password Auth
    log "Disabling SSH password authentication..."
    
    if [ "$DRY_RUN" != "true" ]; then
        # Backup first
        sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
        
        # Disable password auth
        for setting in "PasswordAuthentication" "KbdInteractiveAuthentication"; do
            if grep -q "^#*${setting}" /etc/ssh/sshd_config; then
                # Line exists (possibly commented) — replace it
                sudo sed -i '' "s/^#*${setting}.*/${setting} no/" /etc/ssh/sshd_config
            else
                # Line doesn't exist — append it
                echo "${setting} no" | sudo tee -a /etc/ssh/sshd_config > /dev/null
            fi
        done
        
        # Reload sshd
        sudo launchctl kickstart -k system/com.openssh.sshd
        
        echo ""
        echo "SSH password auth disabled. Test from all devices NOW."
        echo "If locked out, use physical keyboard. Rollback command:"
        echo "  sudo cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config && sudo launchctl kickstart -k system/com.openssh.sshd"
        echo ""
        
        pause "Confirm SSH still works from all devices."
    else
        echo "[DRY] Would disable SSH password authentication"
    fi
    
    # 11.4 Firewall
    log "Enabling firewall..."
    run sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
    run sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setallowsigned on
    
    # 11.5 Verify Gateway Token
    if [ "$DRY_RUN" != "true" ]; then
        if ! "$JQ_BIN" -r '.gateway.auth.token' ~/.openclaw/openclaw.json | grep -q .; then
            die "Gateway token missing from config. Re-run Phase 7."
        fi
        log "Gateway token verified ✅"
    else
        echo "[DRY] Would verify gateway token"
    fi
    
    log "Security hardening complete ✅"
}

phase_12() {
    CURRENT_PHASE="12"
    should_skip_phase 12 && { log "Skipping Phase 12 (--skip)"; return; }
    
    phase_banner 12 "Backup Setup"
    
    # 12.1 Reference Copies
    log "Creating reference copies..."
    if [ "$DRY_RUN" != "true" ]; then
        mkdir -p ~/.openclaw/workspace/reference/scripts ~/.openclaw/workspace/reference/plists
        cp ~/.openclaw/scripts/daily-maintenance.sh ~/.openclaw/workspace/reference/scripts/
        cp ~/Library/LaunchAgents/com.openclaw.daily-maintenance.plist ~/.openclaw/workspace/reference/plists/
        
        cd ~/.openclaw/workspace || die "Failed to cd to workspace"
        git add reference/
        git commit -m "Add reference copies of scripts and plists"
        
        if git remote get-url origin &>/dev/null; then
            if git push origin main; then
                log "Reference copies pushed to git ✅"
            else
                echo "⚠️ Git push failed. Check auth: gh auth login"
            fi
        else
            echo "⚠️ No git remote configured. Skipping push. Set GITHUB_REPO to enable disaster recovery."
        fi
    else
        echo "[DRY] Would create and commit reference copies"
    fi
    
    # 12.2 Time Machine
    echo ""
    echo "━━━ Time Machine Setup ━━━"
    echo "Connect a Time Machine drive and enable ENCRYPTED backups:"
    echo "  System Settings → General → Time Machine → Options... → Encrypt backups"
    echo ""
    echo "⚠️ Enable 'Encrypt backups' — without it, all tokens and keys sit in"
    echo "   plaintext on the backup drive."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # 12.3 Post-Run Cleanup Reminder
    echo ""
    echo "━━━ SECURITY REMINDER ━━━"
    echo "If you edited SETUP_TOKEN or ANTHROPIC_API_KEY directly in mac-mini-setup.sh,"
    echo "clear those values now. They're stored in OpenClaw's auth system — the script"
    echo "no longer needs them. Don't commit secrets to git."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    log "Backup setup complete ✅"
}

phase_13() {
    CURRENT_PHASE="13"
    should_skip_phase 13 && { log "Skipping Phase 13 (--skip)"; return; }
    
    phase_banner 13 "Final Verification"
    
    detect_paths
    
    local results=()
    local gateway_status="❌"
    local auth_status="❌"
    local node_status="❌"
    local tailscale_status="❌"
    local filevault_status="❌"
    local sleep_status="❌"
    local token_refresh_status="❌"
    local git_remote_status="❌"
    
    # Gateway check
    if [ "$DRY_RUN" != "true" ]; then
        if [ -n "$OPENCLAW_BIN" ] && "$OPENCLAW_BIN" gateway status &>/dev/null; then
            gateway_status="✅"
            local openclaw_version
            openclaw_version=$("$OPENCLAW_BIN" --version 2>/dev/null || echo "unknown")
            results+=("OpenClaw:      $openclaw_version $gateway_status")
        else
            results+=("OpenClaw:      not running ❌")
        fi
        
        # Auth check
        if [ -n "$OPENCLAW_BIN" ]; then
            "$OPENCLAW_BIN" models status --check &>/dev/null
            local auth_exit=$?
            if [ $auth_exit -eq 0 ] || [ $auth_exit -eq 2 ]; then
                auth_status="✅"
            fi
            results+=("Auth:          healthy $auth_status")
            
            # Live API test
            if "$OPENCLAW_BIN" models status --probe &>/dev/null; then
                results+=("API test:      passed ✅")
            else
                results+=("API test:      failed ❌")
            fi
        fi
        
        # Doctor check
        if [ -n "$OPENCLAW_BIN" ] && "$OPENCLAW_BIN" doctor --non-interactive &>/dev/null; then
            results+=("Config:        healthy ✅")
        else
            results+=("Config:        issues ⚠️")
        fi
    else
        results+=("OpenClaw:      [DRY RUN]")
        results+=("Auth:          [DRY RUN]")
        results+=("API test:      [DRY RUN]")
        results+=("Config:        [DRY RUN]")
    fi
    
    # Node check
    if [ -n "$NODE_BIN" ]; then
        local node_version
        node_version=$("$NODE_BIN" --version 2>/dev/null || echo "none")
        if [[ "$node_version" == v22.* ]]; then
            node_status="✅"
        fi
        results+=("Node.js:       $node_version $node_status")
    else
        results+=("Node.js:       not found ❌")
    fi
    
    # Tailscale check
    if command -v tailscale &>/dev/null && tailscale status &>/dev/null 2>&1; then
        local tailscale_ip
        tailscale_ip=$(tailscale ip -4 2>/dev/null || echo "unknown")
        tailscale_status="✅"
        results+=("Tailscale:     $tailscale_ip $tailscale_status")
    else
        results+=("Tailscale:     not connected ⚠️")
    fi
    
    # FileVault check
    local fv_status
    fv_status=$(fdesetup status 2>/dev/null || echo "unknown")
    if [[ "$fv_status" == *"FileVault is On"* ]] || [[ "$fv_status" == *"Encryption in progress"* ]]; then
        filevault_status="✅"
    fi
    results+=("FileVault:     enabled $filevault_status")
    
    # Sleep check
    if pmset -g | grep -q " sleep.*0"; then
        sleep_status="✅"
    fi
    results+=("Sleep:         disabled $sleep_status")
    
    # Token refresh capability
    if [ "$SETUP_TOKEN_AUTO" = "true" ]; then
        token_refresh_status="✅"
        results+=("Token refresh: automatic $token_refresh_status")
    else
        results+=("Token refresh: manual ⚠️")
    fi
    
    # Firewall
    if /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null | grep -q "enabled"; then
        results+=("Firewall:      active ✅")
    else
        results+=("Firewall:      inactive ❌")
    fi
    
    # SSH
    if [[ "$(sudo systemsetup -getremotelogin 2>/dev/null)" == *"On"* ]]; then
        results+=("SSH:           key-only ✅")
    else
        results+=("SSH:           disabled ❌")
    fi
    
    # Maintenance
    if launchctl print gui/$(id -u) | grep -q "com.openclaw.daily-maintenance" 2>/dev/null; then
        results+=("Maintenance:   daily at $(printf '%d:%02d' $MAINTENANCE_HOUR $MAINTENANCE_MINUTE) ✅")
    else
        results+=("Maintenance:   not scheduled ❌")
    fi
    
    # Git remote
    if [ "$DRY_RUN" != "true" ]; then
        if [ -d ~/.openclaw/workspace/.git ] && cd ~/.openclaw/workspace && git remote get-url origin &>/dev/null; then
            git_remote_status="✅"
            results+=("Git remote:    configured $git_remote_status")
        else
            results+=("Git remote:    not set ⚠️")
        fi
    else
        results+=("Git remote:    [DRY RUN]")
    fi
    
    # Summary output
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║        Mac Mini Setup Complete! 🎉          ║"
    echo "╠══════════════════════════════════════════════╣"
    echo "║                                              ║"
    
    for result in "${results[@]}"; do
        printf "║  %-42s ║\n" "$result"
    done
    
    echo "║                                              ║"
    echo "║  Manual follow-up needed:                    ║"
    echo "║  • Connect Time Machine (encrypted)         ║"
    echo "║  • Set Anthropic spending limit (\$50-100)   ║"
    echo "║  • Monitor token lifetime (week 1)          ║"
    
    if [ -z "$HEALTHCHECKS_PING_URL" ]; then
        echo "║  • Set up Healthchecks.io (optional)        ║"
    fi
    
    echo "║  • Clear secrets from setup script          ║"
    echo "║                                              ║"
    echo "║  Logs: ~/.openclaw/logs/setup.log           ║"
    echo "║  Plan: ~/.openclaw/workspace/guides/        ║"
    echo "║        mac-mini-full-plan-v5.md             ║"
    echo "╚══════════════════════════════════════════════╝"
    echo ""
    
    log "Final verification complete ✅"
}

# CLI argument parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --phase)
            PHASE_START="$2"
            shift 2
            ;;
        --skip)
            SKIP_PHASES="$2"
            shift 2
            ;;
        --skip-claude-cli)
            SKIP_CLAUDE_CLI=true
            shift
            ;;
        --verify-only)
            VERIFY_ONLY=true
            PHASE_START="13"
            shift
            ;;
        --help)
            cat << 'HELP_EOF'
Mac Mini Setup Script v1.7

USAGE:
    ./mac-mini-setup.sh [OPTIONS]

OPTIONS:
    --dry-run           Show what would be done without executing
    --phase N           Start from phase N (0-13)
    --skip N,M          Skip phases N and M (comma-separated)
    --skip-claude-cli   Skip Claude Code CLI installation
    --verify-only       Run only final verification (Phase 13)
    --help              Show this help

PHASES:
    0   Pre-flight Checks
    1   System Configuration
    2   FileVault
    3   Remote Access
    4   Dependencies
    5   Install Tools
    6   Auth Setup
    7   Config & Workspace
    8   Gateway Start & Verify
    9   Maintenance Automation
    10  Tailscale
    11  Security Hardening
    12  Backup Setup
    13  Final Verification

EXAMPLES:
    ./mac-mini-setup.sh                    # Full setup
    ./mac-mini-setup.sh --dry-run          # Preview what would happen
    ./mac-mini-setup.sh --phase 6          # Resume from auth setup
    ./mac-mini-setup.sh --skip 2,10        # Skip FileVault and Tailscale
    ./mac-mini-setup.sh --verify-only      # Just run verification

For detailed documentation, see:
    ~/.openclaw/workspace/guides/mac-mini-full-plan-v5.md
HELP_EOF
            exit 0
            ;;
        *)
            die "Unknown option: $1. Use --help for usage."
            ;;
    esac
done

# Main execution
log "Mac Mini Setup Script v1.7 started (DRY_RUN=$DRY_RUN)"

if [ "$VERIFY_ONLY" = "true" ]; then
    phase_13
    exit 0
fi

# Determine phase range
if [ -n "$PHASE_START" ]; then
    if ! [[ "$PHASE_START" =~ ^([0-9]|1[0-3])$ ]]; then
        die "Phase must be 0-13, got: $PHASE_START"
    fi
    log "Starting from phase $PHASE_START"
else
    PHASE_START=0
fi

# Execute phases
for phase in $(seq $PHASE_START 13); do
    case $phase in
        0) phase_0 ;;
        1) phase_1 ;;
        2) phase_2 ;;
        3) phase_3 ;;
        4) phase_4 ;;
        5) phase_5 ;;
        6) phase_6 ;;
        7) phase_7 ;;
        8) phase_8 ;;
        9) phase_9 ;;
        10) phase_10 ;;
        11) phase_11 ;;
        12) phase_12 ;;
        13) phase_13 ;;
    esac
done

log "Mac Mini Setup Script completed successfully! 🎉"