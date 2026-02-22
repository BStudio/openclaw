# Mac Mini Full Plan v4.2.1 — Deep Review (June 2026)

_Reviewed by Kai. Questioning everything._

---

## TL;DR

The plan is solid architecture. The bones are good. But it's 4 months old now, and some assumptions have drifted. I found **7 critical issues**, **12 significant concerns**, and **15 minor improvements**. The biggest risks are around the setup-token refresh automation (may not work non-interactively), Node version drift, and the firewall step potentially locking you out mid-setup.

---

## 🔴 CRITICAL — Must fix before executing

### C1. Node version drift — `brew install node` may install Node 24 now

**Section:** Phase 2.5

The plan says `brew install node` installs "currently 22.x+ LTS." That was true in Feb 2026. By now, Homebrew's `node` formula tracks the **latest** version, not LTS. If Node 24 has shipped, `brew install node` gives you Node 24, which OpenClaw may not support yet.

**Fix:** Check what `brew info node` shows before installing. If it's >22.x, use `brew install node@22` instead. Yes, it's keg-only and needs manual PATH setup — but that's a one-time cost vs. debugging an incompatible Node version. Alternatively, use `fnm` or `nvm` for explicit version control (OpenClaw docs mention this).

```bash
# Check first
brew info node | head -5
# If it shows 24.x:
brew install node@22
echo 'export PATH="/opt/homebrew/opt/node@22/bin:$PATH"' >> ~/.zprofile
```

Update the launchd plist PATH entries to include the keg-only path if needed.

### C2. `claude setup-token` non-interactive refresh — still unverified, probably doesn't work

**Section:** Phase 6

This was flagged as "unknown to verify first week" but it's the **foundation** of the auto-refresh strategy. Based on the OpenClaw docs (concepts/oauth.md), setup-token is described as a one-time paste flow:

> "Run `claude setup-token` on any machine, then paste it into OpenClaw"

There's no mention of non-interactive refresh. The flow is: generate token → paste → store. No refresh cycle. If the token expires, you generate a new one manually.

**Reality check:** The entire Phase 6 script likely fails every night and sends you a Telegram alert. It's effectively a "manual refresh with alerting" system, not "auto refresh."

**Fix options:**

1. **Accept manual refresh** — simplify the script to just monitor health and alert when expiring. Remove the auto-refresh attempt. You VNC/SSH in and run `claude setup-token` manually when needed.
2. **Test first** — before building all this automation, SSH into the Mac Mini and try: `claude setup-token 2>/dev/null` — does it output a token without opening a browser? If yes, the script works. If it opens a browser or hangs, it doesn't.
3. **Use API key as primary** — if setup-token refresh proves too manual, flip the architecture: API key as primary (with spending limits), setup-token as the cost-saving option when active. Less automation needed.

### C3. Firewall `--setblockall on` can lock you out during remote setup

**Section:** Phase 8.3

`sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setblockall on` blocks **all** incoming connections. The plan says "Tailscale is not affected" because it's outbound UDP. That's true for the Tailscale tunnel itself, but:

- **SSH over Tailscale**: The SSH connection comes in through the Tailscale interface as a local connection. Whether macOS Application Firewall blocks it depends on whether `sshd` is in the firewall's allowed list. Enabling "Remote Login" in System Settings should whitelist `sshd`, but `--setblockall on` overrides per-app allowances.
- **Screen Sharing over Tailscale**: Same issue. VNC traffic arrives via the Tailscale interface.

If you run this command while connected via SSH over Tailscale, **you may lose access**.

**Fix:**

- Test this on local network first (with physical access as backup)
- Use `--setallowsigned on` instead (allows signed system services like sshd)
- Or explicitly allow sshd + screensharingd before setting block-all:

```bash
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add /usr/sbin/sshd
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp /usr/sbin/sshd
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setblockall on
```

- Or just use `--setallowsigned on` — all Apple-signed services (SSH, Screen Sharing) are allowed, random unsigned incoming is blocked. Good enough for a home server.

### C4. `openclaw doctor --yes` in auto-update script could break config

**Section:** Phase 9.2, Step 5

After an update, the script runs `openclaw doctor --yes` which auto-accepts all repairs. Per the docs, `--fix` (alias for `--repair`, which `--yes` also triggers) "drops unknown config keys, listing each removal." If a new version deprecates a config key you're using, doctor auto-removes it without you knowing.

**Fix:** Use `openclaw doctor --non-interactive` instead. This runs migrations but skips interactive prompts (which would hang in a script anyway). Log the output. If doctor finds issues that need `--fix`, alert Kamil instead of auto-accepting.

```bash
"$OPENCLAW" doctor --non-interactive >> "$LOG" 2>&1
DOCTOR_EXIT=$?
if [ $DOCTOR_EXIT -ne 0 ]; then
    log "WARNING: doctor found issues (exit $DOCTOR_EXIT). Manual review needed."
    alert_kamil "⚠️ OpenClaw updated to $NEW_VERSION but doctor found issues. SSH in and run: openclaw doctor"
fi
```

### C5. Two gateway restarts within 90 minutes (token refresh + auto-update)

**Section:** Phase 6.3 + Phase 9.3

Token refresh at 4:00 AM restarts the gateway. Auto-update at 5:30 AM restarts it again. If Kamil is chatting at night (or a cron job is running), two restarts kill two conversations.

**Fix:** Combine into one script that runs at 4:00 AM:

1. Check token health → refresh if needed
2. Check for updates → update if available
3. Single restart at the end

Or: remove the gateway restart from token refresh (the token is just a file — OpenClaw may pick it up without restart). Verify: does OpenClaw re-read auth on every API call, or only on startup?

### C6. Migration backup is incomplete

**Section:** Phase 1

The plan backs up workspace files and config. But per OpenClaw's migration docs, you should copy the **entire** `~/.openclaw/` directory. The plan misses:

- `~/.openclaw/state/` (session data, cron jobs, device pairings)
- `~/.openclaw/agents/` complete (not just auth-profiles.json)

For a fresh Mac Mini setup, this might be intentional (clean start). But the plan should explicitly state what's being left behind and why.

**Fix:** Add a note: "This is a clean migration — we're starting fresh sessions, not carrying over history. If you want full session continuity, tar the entire `~/.openclaw/` directory instead."

### C7. `openclaw security audit --fix` / `--deep` — verify these flags still exist

**Section:** Phase 5.3, 8.2

The current docs show `openclaw security audit`, `openclaw security audit --deep`, and `openclaw security audit --fix`. These seem to match. However, `openclaw doctor --fix` is listed as the one that "writes a backup and drops unknown config keys" — make sure you're not confusing `doctor --fix` (config repair) with `security audit --fix` (security fixes). They do different things.

**Fix:** Verify the exact commands on the current version before executing. Run `openclaw security audit --help` first.

---

## 🟡 SIGNIFICANT — Should fix, won't break things if missed

### S1. No mention of `openclaw.json` file permissions

The config file contains the Telegram bot token, gateway auth token, and references to auth profiles. It should be readable only by the owner.

**Add to Phase 8:**

```bash
chmod 600 ~/.openclaw/openclaw.json
chmod 700 ~/.openclaw/
chmod -R 600 ~/.openclaw/agents/*/agent/auth-profiles.json
```

### S2. `openclaw onboard --install-daemon` — flag may not exist

The plan uses `openclaw onboard --install-daemon`. The current docs show `openclaw onboard` (interactive wizard) and `openclaw gateway install` (separate command). The `--install-daemon` flag isn't in the docs I checked.

**Fix:** Use the two-step approach:

```bash
openclaw onboard          # interactive setup
openclaw gateway install  # install launchd service separately
```

### S3. Time Machine backup should be encrypted

**Section:** Phase 10.1

FileVault encrypts the running disk, but if Time Machine backs up to an unencrypted external drive, all your tokens and keys sit in plaintext on that drive. Defeats the purpose.

**Add:** "When setting up Time Machine, check 'Encrypt backups' in the Time Machine preferences. You'll set a backup password — store it with your FileVault recovery key."

### S4. `gateway stop` vs daemon auto-restart — unclear behavior

**Section:** Phase 5.5

The plan tests daemon persistence by running `openclaw gateway stop`, waiting 10 seconds, then checking status. But `openclaw gateway stop` may cleanly unload the launchd service (not just kill the process). If so, launchd won't restart it because the service was intentionally stopped.

A real test of crash recovery would be:

```bash
# Find the gateway PID and kill it
kill $(pgrep -f "openclaw.*gateway")
sleep 10
openclaw gateway status  # should show it restarted
```

### S5. No mention of "don't log out"

**Section:** Phase 2 / General

The token refresh and auto-update scripts run as LaunchAgents (user-level), not LaunchDaemons (system-level). If the user logs out of macOS, all LaunchAgents stop. Since FileVault requires login on boot, and the Mac Mini stays logged in 24/7, this is usually fine. But should be stated explicitly: **never log out of the Mac Mini session — just lock the screen or let the display sleep.**

Also relevant: "Fast User Switching" to a different user account would stop the LaunchAgents.

### S6. Script error handling for `alert_kamil` function

**Sections:** Phase 6.2, 9.2

Both scripts read the bot token from `openclaw.json` using jq. If the config format changes (new nesting, different key name), the alert function silently fails. You'd have a broken token refresh AND no alert about it.

**Fix:** Add a secondary alert mechanism. Options:

- Healthchecks.io ping that stops when the script fails
- Write a marker file that a cron job checks
- Use `openclaw` CLI to send the alert instead of raw Telegram API (more resilient to config changes)

### S7. Auto-update doesn't check release notes or breaking changes

**Section:** Phase 9.2

The script blindly updates to the latest version. OpenClaw is pre-1.0 and "moving fast" (their words). A breaking change could land in any release. The script's rollback catches gateway/auth failures but not subtle breakage (e.g., changed cron behavior, different message formatting, new required config field).

**Suggestions:**

- Consider pinning to a version and updating manually every 1-2 weeks after checking release notes
- Or: add a `HOLD_VERSION` file that the script checks — if present, skip the update
- Or: update to minor versions only, not major (parse semver)

### S8. Disaster recovery `from scratch` assumes configs are available

**Section:** Phase 10.6

The "from scratch" recovery path says "re-create refresh-token.sh and auto-update.sh from this guide." But if the Mac Mini died and you don't have this guide handy, you're stuck. The guide itself should be backed up outside the Mac Mini.

**Fix:** The `workspace/reference/` backup (Phase 10.2.1) helps, but only if it was pushed to a remote. Make the git push to private remote **non-optional** for disaster recovery to work.

### S9. No macOS login item / keychain considerations

When FileVault boots and you enter the password, macOS logs in and starts LaunchAgents. But some things might need the login keychain unlocked (which happens at login). If any tool stores credentials in the macOS keychain, they need the keychain available.

OpenClaw stores auth in files (not keychain), so this is probably fine. But `claude setup-token` might interact with the keychain. Worth noting.

### S10. Missing: what if Anthropic deprecates setup-token?

**Section:** Risk Assessment

The risk section mentions "If mass-abused, Anthropic could restrict it." But doesn't address the scenario where Anthropic provides a **replacement** auth method. What's the pivot plan?

**Add:** "Monitor Anthropic changelogs and the OpenClaw Discord. If setup-token is deprecated, OpenClaw will likely add the replacement. Run `openclaw models auth add` to see available auth methods."

### S11. Config hot-reload vs restart

**Section:** Phase 4.2, general

The plan mentions restarting the gateway after config changes. But OpenClaw supports config hot-reload for most settings (the file is watched). Only a few settings (gateway server settings, bind address) require restart.

**Clarify:** "Most config changes are picked up automatically (hot reload). Only gateway server settings (port, bind, auth mode) require `openclaw gateway restart`."

### S12. VNC/Screen Sharing security

**Section:** Phase 2.4

Screen Sharing is enabled but no auth mechanism is specified. macOS Screen Sharing can use:

- Apple ID authentication
- Username/password authentication
- VNC password (less secure)

Since it's only accessible via Tailscale, the risk is lower. But should specify: use username/password auth (macOS account credentials), not VNC-only password.

---

## 🟢 MINOR — Nice to fix, low impact

### M1. `sudo systemsetup -settimezone` is partially deprecated

macOS has been deprecating `systemsetup` subcommands. Use System Settings GUI or `sudo systemsetup -settimezone` (still works but may warn). Not critical.

### M2. FileVault recovery key should mention iCloud escrow

If Kamil uses iCloud, escrowing the FileVault key to iCloud is convenient and secure for his threat model (home server, not state secrets).

### M3. Xcode CLT install takes time

`xcode-select --install` downloads several GB. Should note "this takes 5-15 minutes depending on internet speed."

### M4. `brew install --cask tailscale` vs App Store

Tailscale is also available from the Mac App Store. App Store version auto-updates. Cask version needs `brew upgrade --cask tailscale` manually. Personal preference but worth noting.

### M5. No mention of SSH config file for convenience

After setting up Tailscale, create `~/.ssh/config` on the PC:

```
Host mac-mini
    HostName 100.x.y.z
    User kamil
    IdentityFile ~/.ssh/id_ed25519
```

Then just `ssh mac-mini` from anywhere.

### M6. Monthly cost table missing Time Machine hardware

An external drive or NAS for Time Machine is a one-time cost (~$50-100) not mentioned in the cost table.

### M7. Healthchecks.io setup not detailed

The plan mentions it as an option but doesn't show how to set it up. Should include: create account → create check → copy UUID → add ping to HEARTBEAT.md or cron.

### M8. `npm cache clean --force` is aggressive

For disk cleanup, `npm cache clean --force` clears the entire npm cache. `npm cache verify` is gentler and usually sufficient.

### M9. `openclaw update --channel stable` — verify this command works for npm installs

The docs say: "If you installed via npm (no git metadata), `openclaw update` will try to update via your package manager. If it can't detect the install, use npm install directly." The `--channel` flag may only work for git installs.

### M10. Persistent gateway log — consider using OpenClaw's built-in rolling logs

The plan's persistent log option uses newsyslog. But OpenClaw already writes rolling daily logs to `/tmp/`. If you need persistence, consider just changing the log directory in config rather than adding rotation on top.

### M11. Auto-update Telegram alert on success is noisy

Getting a "✅ OpenClaw updated" message every time there's an update gets old fast. Consider only alerting on failure, or using a weekly digest.

### M12. Missing: test the complete flow on a weekend

Before relying on the Mac Mini as production, run it in parallel with the CC container for a day. Both can't poll Telegram simultaneously, but you can test everything except the Telegram connection, then do the switchover.

### M13. `which` vs `command -v`

Bash best practice: `command -v node` is more portable than `which node`. Minor.

### M14. Recovery git clone uses HTTPS — should mention GitHub PAT or deploy key

If the private repo needs auth, HTTPS clone requires a personal access token (PAT). Should mention this or set up a deploy key.

### M15. The checklist section repeats Phase 7/8 ordering

The checklist correctly shows "Remote Management → Security Hardening" but the section headers in the checklist say "(~15 min) — do first" and "(~20 min) — do after Tailscale" which is slightly confusing. Could be clearer.

---

## ✅ THINGS THAT ARE ACTUALLY GOOD

For balance — stuff the plan gets right:

1. **Layer separation diagram** — Excellent. Clear mental model for why updates are safe.
2. **FileVault + authrestart** — The handling of FileVault boot behavior is thorough and honest about the tradeoffs.
3. **Phase ordering (Tailscale before SSH hardening)** — Smart. Safety net before you lock things down.
4. **`set -uo pipefail` without `set -e`** — Correct. This was a real bug caught in v4.1.
5. **Rollback in auto-update** — The version recording + automatic rollback is solid defensive scripting.
6. **Healthchecks.io over UptimeRobot** — Correct insight that external monitors can't reach Tailscale IPs.
7. **Fallback API key** — Insurance without complexity.
8. **`brew pin node`** — Prevents the most common "brew upgrade broke everything" scenario.
9. **Reference copies in workspace git** — Good thinking for disaster recovery.
10. **Security note about deleting auth backup from Telegram** — Attention to detail.

---

## 📋 RECOMMENDED CHANGES SUMMARY

**Before executing, minimum viable fixes:**

1. ✅ Check what Node version `brew install node` gives — use `node@22` if needed (C1)
2. ✅ Test `claude setup-token` non-interactive behavior FIRST (C2)
3. ✅ Use `--setallowsigned on` instead of `--setblockall on` for firewall (C3)
4. ✅ Change `doctor --yes` to `doctor --non-interactive` in auto-update script (C4)
5. ✅ Combine token refresh + auto-update into one script or separate the restart (C5)
6. ✅ Add explicit note about clean migration vs full migration (C6)
7. ✅ Verify CLI flags exist on current version before executing (C7)
8. ✅ Encrypt Time Machine backups (S3)
9. ✅ Add `chmod 600` for config files (S1)
10. ✅ Make git remote push non-optional (S8)

**Version this review as input to v5.0 of the plan.**
