# Mac Mini Full Plan — Architecture, Auth & Strategy

## Current Setup (for reference)

```
Claude Code session (Max sub $200/mo)
 │
 ├── powers CC itself
 └── issues sk-ant-si-* ephemeral session token
      │
      └── OpenClaw reads from /home/claude/.claude/remote/.session_ingress_token
           │
           └── hits api.anthropic.com directly (billed to Max sub)
                │
                └── Kai → Telegram → Kamil

⚠️ Session-coupled: CC dies = token dies = Kai dies
```

## Mac Mini Target Architecture

```
📱 Kamil (anywhere)
 │
 ├── Telegram (daily chat)
 │
 ▼
🖥️ Mac Mini M4 24GB (always on)
 │
 ├── launchd (auto-restart on boot/crash)
 │   └── OpenClaw Gateway (daemon)
 │       ├── Telegram plugin
 │       ├── Cron scheduler
 │       └── Kai (main agent)
 │           ├── SOUL.md, MEMORY.md, workspace
 │           └── future sub-agents
 │
 ├── Setup Token (sk-ant-oat01-*) → Max sub ($200/mo flat)
 │   └── auto-refresh script (weekly cron)
 │
 ├── Tailscale (optional, remote admin)
 │
 └── Claude Code CLI (dev tool only, NOT runtime dependency)
     └── used to debug/configure/fix openclaw when needed
```

## Key Difference from Current Setup

- Current: OpenClaw piggybacks on CC's ephemeral session token (fragile)
- Mac Mini: OpenClaw uses its own setup-token (long-lived, independent)
- CC becomes a mechanic, not the engine

## Auth Method: Setup Token

- Uses `claude setup-token` from Claude Code CLI
- Routes through $200/mo Max subscription (no per-token cost)
- Officially supported by OpenClaw as "preferred Anthropic auth"
- Token stored at `~/.openclaw/agents/<agentId>/agent/auth-profiles.json`
- See `mac-mini-setup-token.md` for step-by-step setup

## Auto Token Refresh Script

Token doesn't auto-refresh like OAuth did. Script to automate it:

```bash
#!/bin/bash
# auto-refresh-token.sh

# 1. Generate new setup token
NEW_TOKEN=$(claude setup-token --print 2>/dev/null)

# 2. Feed it into openclaw
echo "$NEW_TOKEN" | openclaw models auth paste-token --provider anthropic --yes

# 3. Restart gateway to pick up new creds
openclaw gateway restart

# 4. Verify
openclaw models status --check
if [ $? -eq 0 ]; then
    echo "✅ Token refreshed successfully"
else
    echo "❌ Token refresh failed — notify Kamil"
    # TODO: send telegram alert on failure
fi
```

Schedule via macOS launchd or cron (weekly recommended):

```bash
0 4 * * 1 /path/to/auto-refresh-token.sh
```

### To verify on mac mini:

- Does `claude setup-token` have a `--print` or non-interactive flag?
- How long do tokens last before expiring?
- Does gateway need full restart or just reload?

## Risk Assessment

### Why it should be safe

- `claude setup-token` is Anthropic's own CLI tool
- OpenClaw docs list it as preferred auth
- Not a hack — it's a published, documented command
- Provided as the official replacement after OAuth was killed

### Why it might not last

- Same pattern as OAuth (sub → token → third-party → unlimited)
- If too many people abuse it, Anthropic could restrict it
- Possible future actions: rate limits, client fingerprinting, ToS changes

### Mitigation strategy

1. ✅ Setup token as PRIMARY auth
2. 🔄 Keep an API key configured as FALLBACK in openclaw
3. 💰 Budget $50-100/mo API insurance money
4. 🧠 Run routine/sub-agent tasks on Sonnet (cheaper if fallback needed)
5. 📋 Refresh token weekly, not aggressively
6. 🚫 Don't abuse — reasonable usage, not 10 agents at max throughput 24/7
7. 🔧 System designed so swapping auth is a one-line config change

## Monthly Cost

| Item                | Cost                |
| ------------------- | ------------------- |
| Claude Max sub      | $200                |
| Electricity         | ~$5                 |
| Telegram bot        | free                |
| Tailscale           | free                |
| API fallback budget | $50-100 (insurance) |
| **Total**           | **~$255-305/mo**    |

## Setup Checklist (when mac mini arrives)

1. [ ] macOS basics — homebrew, node 22+
2. [ ] Install OpenClaw — `npm install -g openclaw`
3. [ ] Install Claude Code — `npm install -g @anthropic-ai/claude-code`
4. [ ] Generate token — `claude setup-token`
5. [ ] Run onboard — `openclaw onboard` (telegram bot + paste token)
6. [ ] Migrate workspace — SOUL.md, MEMORY.md, guides/, memory/
7. [ ] Configure fallback API key
8. [ ] Start gateway — `openclaw gateway start`
9. [ ] Set up launchd — auto-start openclaw on boot
10. [ ] Set up token refresh cron — weekly auto-refresh script
11. [ ] Optional — install Tailscale for remote CLI access
12. [ ] Test everything end-to-end via Telegram
