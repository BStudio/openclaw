# Mac Mini Setup — Claude Max via Setup Token

Use your $200/mo Claude Max subscription with OpenClaw instead of paying per-API-call.

## Prerequisites

- Mac Mini M4 with OpenClaw installed
- Claude Max subscription ($200/mo)
- Node.js 22+ installed

## Steps

### 1. Install Claude Code CLI

```bash
npm install -g @anthropic-ai/claude-code
```

### 2. Generate setup token

```bash
claude setup-token
```

This authenticates with your Max sub and outputs a token. Copy it.

### 3. Paste into OpenClaw

```bash
openclaw models auth setup-token --provider anthropic
```

Or if generated on a different machine:

```bash
openclaw models auth paste-token --provider anthropic
```

### 4. Verify

```bash
openclaw models status
```

Shows auth status + token expiry. Use `--check` flag for automation (exits 1 if expired).

### 5. Restart gateway

```bash
openclaw gateway restart
```

## Notes

- Token lives at: `~/.openclaw/agents/<agentId>/agent/auth-profiles.json`
- Token does NOT auto-refresh — re-run `claude setup-token` when it expires
- If running Claude Code CLI + OpenClaw on same account, one may get logged out (token sink). Best to dedicate the account to OpenClaw only.
- Check health anytime: `openclaw models status --check`

## Cost

$0 extra beyond your Max subscription. No per-token API charges.
