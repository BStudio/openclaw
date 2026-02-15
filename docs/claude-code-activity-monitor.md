# Claude Code Activity Monitor

## Problem

When running OpenClaw inside a Claude Code container session, the container auto-closes after ~5 minutes of inactivity. However, OpenClaw agents running inside the container are invisible to Claude Code's activity detection, causing premature session termination even when agents are actively working.

## Solution

The **Claude Code Activity Monitor** solves this by:

1. **Monitoring OpenClaw session activity** - Watches the session store for `updatedAt` timestamp changes
2. **Signaling to Claude Code** - Sends periodic stdout pings when agents are active
3. **Automatic lifecycle management** - Starts/stops automatically via SessionStart/SessionEnd hooks

## How It Works

### Activity Detection

The monitor checks the OpenClaw session store (`~/.openclaw/agents/{agent-id}/sessions.json`) for recent activity:

- Checks every 30 seconds (configurable)
- Sessions with `updatedAt` within the last 3 minutes are considered active
- When any agent is active, the monitor sends keepalive pings to Claude Code

### Claude Code Integration

Claude Code detects session activity through:

- **stdout output** - Any console output resets the idle timer
- **Process activity** - Running processes signal activity

The monitor sends minimal stdout pings (`[openclaw-activity] {timestamp}`) every 60 seconds when agents are active.

### Automatic Startup

The `session-lifecycle` hook automatically:

- **Starts** the activity monitor when a Claude Code session begins
- **Detects** Claude Code environment (via `CLAUDE_CODE_SESSION` env var)
- **Skips** when not in Claude Code (no overhead for normal usage)
- **Stops** the monitor when the session ends

## Architecture

```
┌─────────────────────────────────────────┐
│     Claude Code Container Session        │
│  ┌────────────────────────────────────┐  │
│  │   OpenClaw Gateway/Agents          │  │
│  │                                    │  │
│  │  • Agent processes running         │  │
│  │  • Session store updates           │  │
│  │    (updatedAt timestamps)          │  │
│  └────────────────┬───────────────────┘  │
│                   │                       │
│  ┌────────────────▼───────────────────┐  │
│  │  Activity Monitor (background)     │  │
│  │                                    │  │
│  │  1. Watch session store            │  │
│  │  2. Detect active agents           │  │
│  │  3. Send stdout pings ────────────────┼──► Claude Code
│  └────────────────────────────────────┘  │   (resets idle timer)
│                                          │
└──────────────────────────────────────────┘
```

## Files

### Core Implementation

- **`scripts/claude-code-activity-monitor.ts`**
  - Main activity monitor implementation
  - Watches session store for activity
  - Sends keepalive pings to stdout

- **`src/hooks/bundled/session-lifecycle/handler.ts`**
  - SessionStart/SessionEnd hook
  - Automatically starts/stops the activity monitor
  - Only runs in Claude Code sessions

### Generated Files (runtime)

- `/tmp/claude-code-activity-monitor.pid` - Process ID
- `/tmp/claude-code-activity-monitor.log` - Activity monitor logs
- `/tmp/session-lifecycle-hook.log` - Hook execution logs

## Configuration

### Default Settings

```typescript
{
  checkIntervalMs: 30_000,      // Check every 30 seconds
  pingIntervalMs: 60_000,       // Ping every 60 seconds when active
  idleThresholdMinutes: 3,      // Consider idle after 3 minutes
  agentId: "default"            // Monitor default agent
}
```

### Command-Line Options

```bash
# Run with custom settings
tsx scripts/claude-code-activity-monitor.ts \
  --check-interval=15 \
  --ping-interval=30 \
  --idle-threshold=5 \
  --verbose

# Dry run mode (no pings)
tsx scripts/claude-code-activity-monitor.ts --dry-run --verbose
```

## Environment Detection

The monitor only runs in Claude Code sessions, detected via:

```typescript
const isClaudeCodeSession =
  process.env.CLAUDE_CODE_SESSION ||
  process.env.CODESPACE_NAME ||
  process.env.GITPOD_WORKSPACE_ID ||
  false;
```

## Testing

### Manual Testing

```bash
# Dry run with verbose logging
tsx scripts/claude-code-activity-monitor.ts --dry-run --verbose

# Check if it's running
cat /tmp/claude-code-activity-monitor.pid
ps -p $(cat /tmp/claude-code-activity-monitor.pid)

# View logs
tail -f /tmp/claude-code-activity-monitor.log
tail -f /tmp/session-lifecycle-hook.log
```

### Expected Behavior

1. **Session starts** → Hook starts activity monitor in background
2. **Agents are active** → Monitor sends periodic pings to stdout
3. **Agents go idle** → Monitor stops pinging (allows container to close)
4. **Session ends** → Hook stops activity monitor

## Debugging

### Check Hook Logs

```bash
tail -f /tmp/session-lifecycle-hook.log
```

Look for:

```
🚀 [HH:MM:SS] Session started: {session-id}
   Claude Code activity monitor: STARTED (PID: {pid})
```

### Check Activity Monitor Logs

```bash
tail -f /tmp/claude-code-activity-monitor.log
```

Look for:

```
[timestamp] [claude-code-activity] info: Agents became active
[timestamp] [claude-code-activity] debug: Sent ping to Claude Code
```

### Check Process Status

```bash
# Is the monitor running?
ps aux | grep claude-code-activity-monitor

# What's the PID?
cat /tmp/claude-code-activity-monitor.pid

# Is the process alive?
ps -p $(cat /tmp/claude-code-activity-monitor.pid)
```

## Troubleshooting

### Monitor Not Starting

**Symptom:** Hook says "FAILED" or "SKIPPED"

**Solutions:**

1. Check if in Claude Code session: `echo $CLAUDE_CODE_SESSION`
2. Verify script exists: `ls -l scripts/claude-code-activity-monitor.ts`
3. Check permissions: `ls -l /tmp/claude-code-activity-monitor.pid`

### Container Still Closing

**Symptom:** Container closes even when agents are active

**Solutions:**

1. Check if pings are being sent:
   ```bash
   grep "openclaw-activity" /tmp/claude-code-activity-monitor.log
   ```
2. Verify activity detection:
   ```bash
   # Run in verbose mode
   tsx scripts/claude-code-activity-monitor.ts --verbose
   ```
3. Check session timestamps:
   ```bash
   cat ~/.openclaw/agents/default/sessions.json | jq '.[] | {updatedAt}'
   ```

### High CPU Usage

**Symptom:** Activity monitor using too much CPU

**Solutions:**

1. Increase check interval:
   ```bash
   # Check every 60 seconds instead of 30
   tsx scripts/claude-code-activity-monitor.ts --check-interval=60
   ```
2. Increase ping interval:
   ```bash
   # Ping every 2 minutes instead of 1
   tsx scripts/claude-code-activity-monitor.ts --ping-interval=120
   ```

## Performance Impact

- **Minimal overhead** - Only runs in Claude Code sessions
- **Efficient polling** - Checks every 30s (not continuously)
- **Background process** - Uses `unref()` to avoid blocking
- **Automatic cleanup** - Stops when session ends

## Future Enhancements

Potential improvements:

1. **File watching** - Use `fs.watch()` instead of polling
2. **Multiple agents** - Monitor all agents, not just default
3. **Smart thresholds** - Adjust ping frequency based on activity level
4. **Health checks** - Self-monitor and restart if stuck

## Related Documentation

- [Session Lifecycle Hooks](./hooks/session-lifecycle.md)
- [Session Management](./sessions.md)
- [Claude Code Integration](./claude-code.md)
