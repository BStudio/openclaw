# Mac Mini Full Plan v5.0 — Deep Review Round 2 (June 2026)

_Reviewed by Kai. v5 is much tighter but still has real bugs._

---

## TL;DR

v5.0 fixed most of the v4.2.1 problems. But the sub-agent introduced **3 new bugs** (macOS compatibility, dead code in alert function, git SSH before keys exist) and left some rough edges. Fewer issues this time, all fixable.

---

## 🔴 CRITICAL — Must fix

### C1. `timeout` command doesn't exist on macOS

**Section:** Phase 6.1

The test step uses `timeout 10s claude setup-token 2>/dev/null`. The `timeout` command is GNU coreutils — it exists on Linux, NOT on macOS. This command will fail with "command not found."

**Fix:** Use a macOS-compatible approach:

```bash
# macOS-compatible timeout test
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

Or install coreutils: `brew install coreutils` then use `gtimeout 10s ...`. But adding a dependency just for one test is overkill.

### C2. `openclaw message send` is not a real CLI command — alert primary path is dead code

**Section:** Phase 6.3 (daily-maintenance.sh, `alert_kamil` function)

The alert function's primary path uses:

```bash
"$OPENCLAW" message send --channel telegram --target "455442541" --text "$msg"
```

`openclaw message send` doesn't exist as a CLI command. The `message` tool is only available to the agent runtime (inside sessions), not from the shell. This silently fails every time, and the function falls back to the Telegram API call.

The "dual alert mechanism" is actually just the Telegram API with a dead first attempt.

**Fix:** Remove the dead primary path. Use the Telegram API as the primary (it works). If you want a secondary, use Healthchecks.io fail ping:

```bash
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

    # Fallback: Write to log + healthchecks.io fail
    log "ALERT DELIVERY FAILED: $msg"
    # Optional: curl -fsS -m 10 https://hc-ping.com/<uuid>/fail
}
```

### C3. Git remote uses SSH but SSH keys don't exist yet

**Section:** Phase 4.3

```bash
git remote add origin git@github.com:kamil/kai-workspace.git
git push -u origin main
```

Phase 4 is before Phase 8 (Security Hardening, where SSH keys are generated). There's no SSH key on the Mac Mini at this point, so `git push` via SSH will fail.

**Fix:** Use HTTPS for the initial remote:

```bash
git remote add origin https://github.com/kamil/kai-workspace.git
git push -u origin main
```

If the repo is private, this will prompt for GitHub credentials. Can switch to SSH later after keys are set up in Phase 8. Or generate a GitHub PAT beforehand.

Also: add `git branch -M main` before push, since the default branch might be `master` depending on git version.

---

## 🟡 SIGNIFICANT — Should fix

### S1. Node version check flow is confusing — main path contradicts the check

**Section:** Phase 2.5

The flow says "Check Node version FIRST" then immediately says `brew install node jq`. If the check showed Node 24, the user has to skip past the main instruction to the alternatives box. Easy to miss.

**Fix:** Restructure as a conditional:

```bash
# Check what Homebrew will install
NODE_VER=$(brew info --json=v2 node | jq -r '.formulae[0].versions.stable' 2>/dev/null)
echo "Homebrew node formula version: $NODE_VER"

# Install based on version
if [[ "$NODE_VER" == 22.* ]]; then
    brew install node jq
elif [[ "$NODE_VER" == 23.* || "$NODE_VER" == 24.* ]]; then
    echo "Node $NODE_VER is too new. Installing node@22 instead."
    brew install node@22 jq
    echo 'export PATH="/opt/homebrew/opt/node@22/bin:$PATH"' >> ~/.zprofile
    source ~/.zprofile
fi
```

### S2. fnm-managed Node paths not reflected in launchd plist

**Section:** Phase 2.5 + 6.4

If the user follows the fnm alternative, Node lives at `~/.local/share/fnm/aliases/default/bin/` (or similar), not `/opt/homebrew/bin/`. But the launchd plist in Phase 6.4 hardcodes `/opt/homebrew/bin`. The maintenance script would fail to find `node` and `npm`.

**Fix:** Add a note: "If you used fnm, update the PATH in the launchd plist to include your fnm bin directory. Find it with: `dirname $(fnm exec which node)`"

Or better: just recommend `brew install node` or `node@22` for servers, and leave fnm as a "dev workstation" option.

### S3. `UPDATE_SUCCESS` variable used before initialization

**Section:** Phase 6.3

`UPDATE_SUCCESS=true` is set inside the update code path, but `[ "$UPDATE_SUCCESS" = true ]` is checked later even if the update path wasn't taken. If no update was available, `UPDATE_SUCCESS` is unset, and the comparison works by coincidence (unset != "true" is false).

**Fix:** Add `UPDATE_SUCCESS=false` near the top of the script, after `needs_restart=false`.

### S4. Nobody commits workspace changes unless heartbeats are active

**Section:** Phase 10.2

The plan says "Kai should do this during heartbeats" but HEARTBEAT.md is empty. So nobody commits workspace changes automatically. The workspace git backup — which is now **required** for DR — doesn't stay current.

**Fix options:**

1. Add a workspace commit task to HEARTBEAT.md as part of the plan
2. Add workspace git push to the daily maintenance script
3. Note explicitly that Kamil should manually commit/push periodically until heartbeats are configured

### S5. Tailscale Serve config may use wrong key names

**Section:** Phase 7.2

```json5
{
  gateway: {
    bind: "loopback",
    tailscale: { mode: "serve" },
    auth: { allowTailscale: true },
  },
}
```

`allowTailscale` may not be the actual config key. The OpenClaw gateway config reference should be checked. If this config is wrong, it either gets rejected (strict validation blocks gateway start) or silently ignored.

**Fix:** Verify against the config reference (`openclaw config schema` or the docs). If unsure, mark this section as "verify config keys on your version" rather than presenting it as copy-paste ready.

### S6. Gateway auth token change described as hot-reloadable, but it's not

**Section:** Phase 8.5

The note at the bottom says "Most config changes are picked up automatically (hot reload). Only gateway server settings (port, bind, auth mode) require restart." But changing the gateway auth **token** IS a gateway server setting. If someone follows the plan — generates a token, puts it in config — they need to explicitly restart the gateway.

**Fix:** Change the note to: "After setting the gateway token, restart the gateway: `openclaw gateway restart`. The token is a server setting and isn't hot-reloaded."

### S7. Node version constraint "<=23" is arbitrary

**Section:** Phase 2.5 and checklist

The plan says `node --version # must be >= 22.x.x and <= 23.x.x`. OpenClaw docs say "Node 22 or newer" — no upper bound. Node 23 is odd-numbered (not LTS, short-lived), so it's an unusual recommendation.

**Fix:** Say "must be >= 22.x.x" and add: "Very new major versions (24+) may have untested compatibility — check OpenClaw release notes before using."

---

## 🟢 MINOR — Nice to fix, low impact

### M1. `pgrep` pattern in Phase 5.5 could match unintended processes

`kill $(pgrep -f "openclaw.*gateway")` — the `.*` is broad. Could match `openclaw-gateway-helper` or similar. Use `-x` for exact match or a tighter pattern: `pgrep -f "openclaw gateway"`.

### M2. Rollback doesn't verify itself

If npm rollback fails (e.g., old version no longer on registry), the script alerts about the original failure but doesn't detect the double failure. Add a version check after rollback.

### M3. `security audit --deep` hedging is confusing

Phase 5.3 says `openclaw security audit --deep # deeper audit (if --deep flag exists)`. Either include it or don't. The parenthetical doubt is weird in a step-by-step guide.

### M4. Cost table minimum is $255 but $50 API is insurance

The "API fallback budget" is listed as $50-100 but described as "insurance, may not be used." Including it in the minimum total ($255) is misleading if it's truly insurance. Should be $205 + $50-100 insurance = $205-305.

### M5. DR git clone URL format with embedded PAT is insecure

Phase 10.6 step 3: `git clone https://username:PAT@github.com/...` puts the token in the URL, which may be logged in bash history, git config, or process lists. Use `GIT_ASKPASS` or credential helper instead.

### M6. Phase 9.2 could link back to Phase 6 more explicitly

"The daily maintenance script in Phase 6 includes OpenClaw auto-update" — add: "(see Phase 6.3 for the full script)".

### M7. Missing: update OpenClaw on the CC container before migrating?

The current instance runs 2026.2.13 (4 months old). Should the plan recommend updating to latest on the CC container first, to ensure config compatibility? Minor since `doctor` handles migrations, but avoids surprises.

---

## ✅ WHAT v5.0 GOT RIGHT (improvements over v4.2.1)

1. **Combined maintenance script** — Single script, single restart, single log. Much cleaner.
2. **HOLD_VERSION mechanism** — Simple, elegant pause for auto-updates.
3. **Honest about setup-token** — No longer pretending auto-refresh definitely works.
4. **Firewall fix** — `--setallowsigned on` is the right call.
5. **File permissions** — `chmod 600` on config files. Should've been there from the start.
6. **Encrypted Time Machine** — Required, not optional. Correct.
7. **Full vs clean migration** — Explicit choice with tradeoffs explained.
8. **Git remote required** — DR actually works now.
9. **Doctor --non-interactive** — Safer than --yes in automation.
10. **LaunchAgent logout warning** — Important detail that was missing.

---

## 📋 CHANGES NEEDED FOR v5.1

**Must fix:**

1. Replace `timeout` with macOS-compatible alternative in Phase 6.1 (C1)
2. Remove dead `openclaw message send` from alert function (C2)
3. Change git remote URL from SSH to HTTPS in Phase 4.3 (C3)

**Should fix:** 4. Restructure Node install as conditional flow (S1) 5. Add fnm PATH note for launchd or recommend brew-only for servers (S2) 6. Initialize `UPDATE_SUCCESS=false` at script top (S3) 7. Address workspace commit gap (S4) 8. Verify Tailscale Serve config keys or mark as "verify" (S5) 9. Fix gateway auth restart note (S6) 10. Fix Node version constraint wording (S7)

This is a much shorter list than last time. v5.0 is close to production-ready.
