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

1. Starts an in-process timer that checks for activity every 30 seconds
2. Uses two activity signals:
   - **Command queue**: detects in-flight LLM calls, tool execution, and queued tasks
   - **Session store**: detects sessions updated within the last 10 minutes
3. When either signal indicates activity, writes a keepalive ping to stdout (at most once per 60 seconds)
4. Claude Code sees the stdout activity and keeps the container alive

Only activates when the `CLAUDECODE` or `CLAUDE_CODE_SESSION_ID` environment variable is set.

## Monitoring

```bash
# Watch keepalive activity
tail -f /tmp/claude-code-activity-monitor.log
```
