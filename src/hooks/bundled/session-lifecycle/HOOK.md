---
name: session-lifecycle
description: "Session lifecycle notifications and keep-alive management"
homepage: https://docs.openclaw.ai/hooks#session-lifecycle
metadata:
  {
    "openclaw":
      {
        "emoji": "🔄",
        "events": ["session:start", "session:end", "gateway:stop"],
        "requires": { "bins": ["node"] },
        "install": [{ "id": "bundled", "kind": "bundled", "label": "Bundled with OpenClaw" }],
      },
  }
---

# Session Lifecycle Hook

Provides notifications for session start/end events and integrates with the session keep-alive daemon.

## What It Does

- **Session Start**: Notifies when a session begins and starts the keep-alive daemon
- **Session End**: Notifies when a session ends with duration and message count
- **Gateway Stop**: Cleanup when gateway stops

## Features

- 🚀 Starts session keep-alive daemon automatically on session start
- 👋 Stops keep-alive daemon when session ends
- 📊 Reports session duration and message count
- 🔔 Visual notifications with timestamps
- 📝 Logs all events to `/tmp/session-lifecycle-hook.log` for monitoring
- 📄 Maintains current status in `/tmp/session-lifecycle-status.json`

## Requirements

- Node.js must be installed
- Session keep-alive scripts in `scripts/` directory

## Configuration

No configuration needed. The hook automatically:

- Starts `session-keep-alive-daemon.sh` on session start
- Stops the daemon on session end or gateway stop
- Logs all events to stdout

## Monitoring Hook Activity

### Real-time log monitoring

```bash
# Watch hook events in real-time
tail -f /tmp/session-lifecycle-hook.log
```

### Check current session status

```bash
# View current session status
cat /tmp/session-lifecycle-status.json

# Or with pretty formatting
jq . /tmp/session-lifecycle-status.json
```

### Monitor keep-alive daemon

```bash
# Watch daemon activity
tail -f /tmp/session-keep-alive.log
```

## Example Output

**Console/Log Output:**

```
🚀 [03:15:00] Session started: abc123def456
   Keep-alive daemon: STARTED (PID: 7890)

👋 [03:45:30] Session ended: abc123def456
   Duration: 30m 30s
   Messages: 42
   Keep-alive daemon: STOPPED
```

**Status File (`/tmp/session-lifecycle-status.json`):**

```json
{
  "event": "session_start",
  "sessionId": "abc123def456",
  "timestamp": "2026-02-15T03:15:00.123Z",
  "daemonStatus": "STARTED (PID: 7890)",
  "daemonPid": 7890,
  "resumedFrom": "xyz789"
}
```
