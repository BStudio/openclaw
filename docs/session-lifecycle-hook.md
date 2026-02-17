# Session Lifecycle Hook

Automatic session start/end notifications with integrated keep-alive daemon management.

## Overview

The session lifecycle hook automatically:

- **Starts** the keep-alive daemon when sessions begin
- **Notifies** you when sessions start and end
- **Stops** the keep-alive daemon when sessions close
- **Reports** session duration and message counts

## Installation

The hook is located at `~/.openclaw/hooks/session-lifecycle/`.

### Enable the Hook

```bash
# Enable the hook (requires gateway restart to discover)
openclaw hooks enable session-lifecycle

# Restart gateway to load the hook
openclaw gateway restart
```

### Enable Internal Hooks

To use session lifecycle hooks, you must enable internal hooks in your config:

```json5
// ~/.openclaw/openclaw.json
{
  hooks: {
    internal: {
      enabled: true,
    },
  },
}
```

## What It Does

### On Session Start

When a session starts or resumes:

```
🚀 [03:15:00] Session started: abc123def456
   Keep-alive daemon: STARTED (PID: 7890)
```

**Actions:**

- Logs session ID and timestamp
- Starts `session-keep-alive-daemon.sh` automatically
- Shows PID if already running

### On Session End

When a session ends:

```
👋 [03:45:30] Session ended: abc123def456
   Duration: 30m 30s
   Messages: 42
   Keep-alive daemon: STOPPED
```

**Actions:**

- Logs session duration and message count
- Stops the keep-alive daemon gracefully
- Cleans up PID file

### On Gateway Stop

When the gateway shuts down:

```
🛑 [04:00:00] Gateway stopping (shutdown)
   Keep-alive daemon: STOPPED
```

**Actions:**

- Ensures keep-alive daemon is stopped
- Cleanup on gateway shutdown

## Integration with Keep-Alive System

This hook integrates seamlessly with the session keep-alive system:

| Component    | Responsibility                                      |
| ------------ | --------------------------------------------------- |
| **Hook**     | Starts/stops daemon based on session lifecycle      |
| **Daemon**   | Periodically updates session timestamps (every 60s) |
| **Sessions** | Stay alive as long as timestamps are fresh          |

### Flow Diagram

```
Session Start
    ↓
Hook: Start daemon
    ↓
Daemon: Update timestamps every 60s
    ↓
Sessions: Never timeout (timestamps always fresh)
    ↓
Session End
    ↓
Hook: Stop daemon
    ↓
Sessions: Can timeout normally
```

## Configuration

### Hook Configuration

The hook itself requires no configuration. It automatically:

- Detects the project root (current working directory)
- Finds `scripts/session-keep-alive-daemon.sh`
- Manages PID file at `/tmp/session-keep-alive.pid`
- Logs to `/tmp/session-keep-alive.log`

### Keep-Alive Configuration

To adjust the keep-alive behavior, edit the daemon script:

```bash
# Default: update every 60 seconds
./scripts/session-keep-alive-daemon.sh 60

# Fast updates: every 30 seconds
./scripts/session-keep-alive-daemon.sh 30
```

Or modify the hook handler to pass different intervals.

## Manual Control

### Start Daemon Manually

```bash
./scripts/start-session-keep-alive.sh
```

### Stop Daemon Manually

```bash
# Kill by PID
kill $(cat /tmp/session-keep-alive.pid)

# Or use pkill
pkill -f session-keep-alive-daemon
```

### Check Status

```bash
# Check if running
ps aux | grep session-keep-alive-daemon | grep -v grep

# View logs
tail -f /tmp/session-keep-alive.log

# Check PID
cat /tmp/session-keep-alive.pid
```

## Troubleshooting

### Hook Not Loading

1. **Enable internal hooks:**

   ```json5
   {
     hooks: {
       internal: {
         enabled: true,
       },
     },
   }
   ```

2. **Restart gateway:**

   ```bash
   openclaw gateway restart
   ```

3. **Verify hook is discovered:**
   ```bash
   openclaw hooks list | grep session-lifecycle
   ```

### Daemon Not Starting

1. **Check script exists:**

   ```bash
   ls -la scripts/session-keep-alive-daemon.sh
   ```

2. **Verify permissions:**

   ```bash
   chmod +x scripts/session-keep-alive-daemon.sh
   ```

3. **Test manually:**
   ```bash
   bash scripts/session-keep-alive-daemon.sh 60
   ```

### Daemon Not Stopping

1. **Check PID file:**

   ```bash
   cat /tmp/session-keep-alive.pid
   ```

2. **Force kill:**

   ```bash
   kill -9 $(cat /tmp/session-keep-alive.pid)
   rm /tmp/session-keep-alive.pid
   ```

3. **Check for orphaned processes:**
   ```bash
   ps aux | grep session-keep-alive-daemon
   ```

## Logs

### Hook Logs

The hook logs to stdout, which appears in:

- Gateway logs
- `openclaw logs` output
- Console during gateway startup

### Daemon Logs

The keep-alive daemon logs to `/tmp/session-keep-alive.log`:

```bash
# View logs
tail -f /tmp/session-keep-alive.log

# Check recent updates
tail -20 /tmp/session-keep-alive.log
```

Example log output:

```
[03:15:01] 🚀 Session keep-alive daemon started
[03:15:01] ⏱️  Update interval: 60s

  ✓ main: 2 session(s)
  ✓ nova: 2 session(s)
  ✓ sage: 2 session(s)
✅ Updated 6 session(s) total at 03:15:01
```

## Advanced Usage

### Custom Intervals Per Hook

Modify `handler.ts` to pass custom intervals:

```typescript
// In session_start hook:
const scriptPath = path.join(projectRoot, "scripts/session-keep-alive-daemon.sh");
const interval = 30; // Custom interval in seconds

const { stdout } = await execAsync(
  `nohup bash "${scriptPath}" ${interval} > "${LOG_FILE}" 2>&1 & echo $!`,
  { cwd: projectRoot },
);
```

### Multiple Sessions

The keep-alive daemon updates ALL agent sessions, so:

- Single daemon handles all sessions
- No need for per-session daemons
- Efficient resource usage

### Conditional Start

Modify the hook to only start for specific sessions:

```typescript
export async function session_start(
  event: PluginHookSessionStartEvent,
  ctx: PluginHookSessionContext,
): Promise<void> {
  // Only start for specific agent
  if (ctx.agentId !== "main") {
    return;
  }

  // Start daemon...
}
```

## Best Practices

1. **Enable on Production** - Prevents sessions from timing out during long work
2. **Monitor Logs** - Check daemon logs occasionally for errors
3. **Restart Gateway** - After hook changes, restart gateway to reload
4. **Test Manually First** - Test daemon manually before relying on hook
5. **Set Appropriate Intervals** - Balance update frequency with resource usage

## See Also

- [Session Keep-Alive System](/docs/session-keep-alive.md)
- [Hooks Documentation](/docs/automation/hooks.md)
- [Session Management](/docs/concepts/session.md)
