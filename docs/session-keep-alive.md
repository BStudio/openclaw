# Session Keep-Alive System

## Overview

The Session Keep-Alive system prevents active sessions from timing out by periodically updating their `updatedAt` timestamps. This is different from heartbeats, which explicitly restore timestamps to allow idle expiry.

## Why Use Session Keep-Alive?

### Problem

- OpenClaw sessions expire based on idle timeout or daily reset
- Sessions are marked as "stale" when `updatedAt` timestamp is too old
- Heartbeats explicitly **restore** `updatedAt` to allow idle expiry
- Active work sessions can timeout during long-running tasks

### Solution

Session Keep-Alive actively **updates** session timestamps to prevent expiry:

- Updates `updatedAt` for all active sessions
- Runs periodically (every 60 seconds by default)
- Keeps sessions alive during active work
- No manual timer management needed

## Architecture

### How Sessions Expire

Sessions can expire in two ways:

1. **Daily Reset** - At configured hour (default 4 AM), sessions older than last reset are stale
2. **Idle Reset** - Sessions with `updatedAt + idleMinutes * 60_000 < now` are stale

### How Keep-Alive Prevents Expiry

The keep-alive daemon:

1. Reads session store: `~/.openclaw/agents/{agent}/sessions/sessions.json`
2. Updates `updatedAt` to current timestamp for all sessions
3. Saves updated store atomically
4. Repeats every N seconds (default: 60)

## Components

### 1. Timestamp Update Script

**File:** `scripts/update-session-timestamps.sh`

Updates session timestamps for one or all agents.

```bash
# Update all agents (default)
./scripts/update-session-timestamps.sh

# Update specific agent
./scripts/update-session-timestamps.sh main

# Update all explicitly
./scripts/update-session-timestamps.sh all
```

### 2. Keep-Alive Daemon

**File:** `scripts/session-keep-alive-daemon.sh`

Runs indefinitely, calling the update script periodically.

```bash
# Start with default 60s interval
./scripts/session-keep-alive-daemon.sh

# Start with custom interval (30 seconds)
./scripts/session-keep-alive-daemon.sh 30
```

### 3. Daemon Starter

**File:** `scripts/start-session-keep-alive.sh`

Convenient wrapper to start the daemon in the background.

```bash
./scripts/start-session-keep-alive.sh
```

Checks if already running, starts daemon, reports PID and log location.

## Usage

### Manual Start

```bash
# Start the keep-alive daemon
./scripts/start-session-keep-alive.sh
```

Output:

```
🚀 Starting session keep-alive service...
✅ Session keep-alive started successfully
   PID: 12345
   Log: /tmp/session-keep-alive.log

💡 To view logs:
   tail -f /tmp/session-keep-alive.log

🛑 To stop:
   kill 12345
```

### Automatic Start (Recommended)

Add to your build or startup process:

```bash
# In build script or post-install hook
nohup bash scripts/session-keep-alive-daemon.sh 60 > /tmp/session-keep-alive.log 2>&1 &
```

### Check Status

```bash
# View logs
tail -f /tmp/session-keep-alive.log

# Check if running
ps aux | grep session-keep-alive-daemon | grep -v grep

# Read PID file
cat /tmp/session-keep-alive.pid
```

### Stop Daemon

```bash
# Kill by PID from file
kill $(cat /tmp/session-keep-alive.pid)

# Kill by name
pkill -f session-keep-alive-daemon
```

## Configuration

### Update Interval

Controlled by argument to daemon script (seconds):

```bash
# Fast updates (every 30s)
./scripts/session-keep-alive-daemon.sh 30

# Slow updates (every 5min)
./scripts/session-keep-alive-daemon.sh 300
```

**Recommendation:** 60 seconds (default) balances responsiveness with overhead.

### Target Agents

The timestamp update script defaults to updating all agents:

```bash
# All agents (default)
./scripts/update-session-timestamps.sh all

# Specific agent only
./scripts/update-session-timestamps.sh main
```

To target specific agents, modify the daemon script to pass agent ID.

## Logs

All output goes to `/tmp/session-keep-alive.log`:

```
[03:17:03] 🚀 Session keep-alive daemon started
[03:17:03] ⏱️  Update interval: 60s

  ✓ main: 2 session(s)
  ✓ nova: 2 session(s)
  ✓ sage: 2 session(s)
✅ Updated 6 session(s) total at 03:17:03
```

### Log Format

- **Timestamp** - `[HH:MM:SS]`
- **Status Icons** - 🚀 (start), ✓ (success), ⚠️ (warning)
- **Per-Agent Counts** - Sessions updated per agent
- **Total Summary** - Total sessions updated

## Comparison: Heartbeat vs Keep-Alive

| Feature         | Heartbeat                              | Session Keep-Alive                      |
| --------------- | -------------------------------------- | --------------------------------------- |
| **Purpose**     | Periodic agent turns for alerts        | Prevent session timeout                 |
| **Timestamp**   | **Restores** updatedAt (allows expiry) | **Updates** updatedAt (prevents expiry) |
| **Model Calls** | Yes (runs agent turn)                  | No (just updates JSON)                  |
| **Cost**        | API calls for each heartbeat           | Free (local file operations)            |
| **Visibility**  | Can deliver messages to channels       | Silent (no user-visible output)         |
| **Use Case**    | Check inboxes, alert on issues         | Keep work sessions alive                |
| **Default**     | 30min interval                         | 60s interval                            |

### When to Use Which

**Use Heartbeat when:**

- You want periodic agent check-ins
- Agent should alert you about pending items
- You need scheduled monitoring

**Use Session Keep-Alive when:**

- You have long-running work sessions
- You want to prevent idle timeout
- Sessions should stay alive during active work
- You don't need agent turns, just timestamp updates

**Use Both when:**

- You want periodic alerts (heartbeat)
- AND active sessions should never timeout (keep-alive)

## Advanced: TypeScript Implementation

For more sophisticated logic, use the TypeScript implementation:

**File:** `scripts/session-keep-alive.ts`

```bash
# Run with tsx
pnpm exec tsx scripts/session-keep-alive.ts

# With options
pnpm exec tsx scripts/session-keep-alive.ts --interval=30 --activity-threshold=10

# Dry run
pnpm exec tsx scripts/session-keep-alive.ts --dry-run
```

Features:

- Activity threshold filtering (only keep alive recently active sessions)
- Per-agent targeting
- Dry run mode
- Integrated logging

**Note:** Currently the bash implementation is simpler and more reliable for production use.

## Troubleshooting

### Sessions Still Expiring

1. Check daemon is running:

   ```bash
   ps aux | grep session-keep-alive-daemon
   ```

2. Verify updates are happening:

   ```bash
   tail -f /tmp/session-keep-alive.log
   ```

3. Check session idle timeout config:
   ```bash
   grep -A5 "session.*idle" ~/.openclaw/openclaw.json
   ```

### Daemon Exits Immediately

1. Check for errors in log:

   ```bash
   cat /tmp/session-keep-alive.log
   ```

2. Verify session store exists:

   ```bash
   ls -la ~/.openclaw/agents/*/sessions/sessions.json
   ```

3. Test update script manually:
   ```bash
   bash scripts/update-session-timestamps.sh
   ```

### High Resource Usage

If updating too frequently:

```bash
# Increase interval to 5 minutes
pkill -f session-keep-alive-daemon
./scripts/session-keep-alive-daemon.sh 300
```

## Best Practices

1. **Start on Session Begin** - Launch daemon when starting work session
2. **Stop on Session End** - Kill daemon when closing session
3. **Monitor Logs** - Occasionally check logs for errors
4. **Tune Interval** - Adjust based on your idle timeout settings
5. **Use with Heartbeat** - Combine with heartbeat for full coverage

## Integration Examples

### With SessionStart Hook

Create `~/.openclaw/hooks/SessionStart:resume`:

```bash
#!/usr/bin/env bash
# Start session keep-alive daemon on session resume
nohup bash scripts/session-keep-alive-daemon.sh 60 > /tmp/session-keep-alive.log 2>&1 &
echo "Session keep-alive daemon started"
```

### With Build Process

In `package.json`:

```json
{
  "scripts": {
    "postinstall": "nohup bash scripts/session-keep-alive-daemon.sh 60 > /tmp/session-keep-alive.log 2>&1 &"
  }
}
```

### With Docker/Containers

In `Dockerfile` or startup script:

```dockerfile
CMD ["bash", "-c", "scripts/session-keep-alive-daemon.sh 60 & exec openclaw-gateway"]
```

## Security Considerations

- **File Permissions** - Session stores contain conversation history; protect appropriately
- **Multi-User Systems** - Each user's daemon updates their own session stores under `~/.openclaw`
- **Atomic Updates** - Script uses temp files and `mv` for atomic updates, preventing corruption

## Performance

- **CPU Usage** - Minimal (<0.1% on most systems)
- **Memory** - Constant small footprint
- **I/O** - One file read + write per agent per interval
- **Network** - None (local file operations only)

## Future Enhancements

Potential improvements:

- [ ] Activity-based filtering (only update recently active sessions)
- [ ] Session-specific keep-alive (target individual sessions)
- [ ] Integration with OpenClaw heartbeat system
- [ ] Graceful shutdown on gateway stop
- [ ] Metrics/monitoring endpoint
