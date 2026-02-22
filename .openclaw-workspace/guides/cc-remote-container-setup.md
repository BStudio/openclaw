# CC Remote Container Setup (Disposable/Temporary)

How the current setup works — running OpenClaw inside a Claude Code remote container on Anthropic's cloud. Used as a temporary solution while waiting for permanent hardware (Mac Mini).

## Architecture

```
Kamil
 │
 ├── Telegram (chat with Kai)
 │
 ▼
Claude Code Remote (Anthropic cloud container)
 │
 ├── CC Opus 4.6 (admin layer, powered by Max sub $200/mo)
 │   └── started openclaw gateway as child process
 │
 ├── OpenClaw Gateway
 │   ├── reads sk-ant-si-* token from disk
 │   ├── re-reads on every API call (picks up refreshes automatically)
 │   ├── converts x-api-key → Bearer auth via fetch interceptor
 │   └── hits api.anthropic.com directly (billed to Max sub)
 │
 ├── Kai (main agent) → Telegram → Kamil
 │
 └── Keepalive system (prevents session timeout)
```

## Auth Flow

1. CC remote session issues ephemeral **session ingress token** (`sk-ant-si-*`)
2. Token is a JWT with **4-hour lifetime**
3. Stored at `/home/claude/.claude/remote/.session_ingress_token`
4. CC backend rotates the token on disk before expiry
5. OpenClaw re-reads from disk on every API call:
   ```javascript
   const SESSION_TOKEN_FILE = "/home/claude/.claude/remote/.session_ingress_token";
   const readFreshSessionToken = () => {
     return readFileSync(SESSION_TOKEN_FILE, "utf8").trim();
   };
   ```
6. If token changed → OpenClaw swaps automatically, logs: "REPLACING stale apiKey with fresh token from disk"
7. Token converted from `x-api-key` header to `Bearer` auth (anthropic requires this for session ingress tokens)

## JWT Token Structure

```json
{
  "iss": "session-ingress",
  "aud": ["anthropic-api"],
  "session_id": "session_xxxxx",
  "organization_uuid": "...",
  "account_email": "kamil@bagirov.ca",
  "application": "ccr",
  "iat": <issued_at>,
  "exp": <issued_at + 4hrs>
}
```

## Keepalive System

OpenClaw includes a session-lifecycle hook that prevents the remote container from timing out:

- **Check interval:** every 30 seconds
- **Ping interval:** every 60 seconds (when active)
- **Idle threshold:** 10 minutes
- **Endpoint:** `POST https://api.anthropic.com/v2/session_ingress/session/{id}/events`
- **Payload:** keepalive event with session/queue activity stats
- **Only activates** when `CLAUDECODE` or `CLAUDE_CODE_REMOTE_SESSION_ID` env vars are set

### How it determines "active":

- Active tasks in command queue > 0
- Queued tasks > 0
- Sessions updated within last 10 minutes

## OpenClaw Auth Storage

Two files store the credential:

**auth-profiles.json** (primary):

```json
{
  "profiles": {
    "session-ingress": {
      "type": "token",
      "provider": "anthropic",
      "token": "sk-ant-si-..."
    }
  }
}
```

**auth.json** (runtime cache):

```json
{
  "anthropic": {
    "type": "oauth",
    "access": "sk-ant-si-...",
    "refresh": "",
    "expires": <timestamp>
  }
}
```

## Key Environment Variables

| Variable                                       | Purpose                         |
| ---------------------------------------------- | ------------------------------- |
| `CLAUDE_CODE_REMOTE=true`                      | Identifies as remote CC session |
| `CLAUDE_CODE_REMOTE_SESSION_ID`                | Session ID for keepalive pings  |
| `CLAUDE_SESSION_INGRESS_TOKEN_FILE`            | Path to token file on disk      |
| `CLAUDE_CODE_ENTRYPOINT=remote`                | Entry point type                |
| `ANTHROPIC_BASE_URL=https://api.anthropic.com` | API endpoint                    |
| `CLAUDECODE=1`                                 | CC environment flag             |

## Limitations

- **Ephemeral:** container gets recycled when session ends
- **4-hour token TTL:** needs CC backend to refresh (automatic)
- **Session timeout:** keepalive prevents this but not guaranteed
- **No persistence:** if container dies, everything is gone
- **Billing:** rides Max sub via session ingress (not API credits)

## Why This Works (Temporarily)

- CC remote container has direct internet access (via egress proxy)
- Token refresh is handled by CC's infrastructure automatically
- Keepalive pings prevent anthropic from recycling the session
- OpenClaw re-reads token from disk, so refresh is seamless
- All billing goes through Max sub — $0 per-token cost

## Why We're Moving to Mac Mini

- Persistent hardware (no container recycling)
- No keepalive hacks needed
- Setup-token instead of ephemeral session tokens
- Survives reboots via launchd
- Full control over the environment
- Same $200/mo billing, but stable
