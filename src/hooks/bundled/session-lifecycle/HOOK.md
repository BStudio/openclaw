---
name: session-lifecycle
description: "Keep Claude Code container sessions alive during agent activity"
homepage: https://docs.openclaw.ai/hooks#session-lifecycle
metadata:
  {
    "openclaw":
      {
        "emoji": "🔄",
        "events": ["gateway:startup"],
        "install": [{ "id": "bundled", "kind": "bundled", "label": "Bundled with OpenClaw" }],
      },
  }
---

# Session Lifecycle Hook

Keeps Claude Code container sessions alive when OpenClaw agents are actively working.

## Problem

Claude Code containers auto-close after ~5 minutes of inactivity. When OpenClaw agents run inside a container, their activity is invisible to Claude Code, causing premature session termination.

## How It Works

On gateway startup (in Claude Code sessions only):

1. Starts an in-process timer that polls the session store every 30 seconds
2. When any session has been updated within the last 3 minutes, writes a keepalive ping to stdout
3. Claude Code sees the stdout activity and keeps the container alive

Only activates when the `CLAUDECODE` or `CLAUDE_CODE_SESSION_ID` environment variable is set.

## Monitoring

```bash
# Watch keepalive activity
tail -f /tmp/claude-code-activity-monitor.log
```
