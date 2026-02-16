## Session start

Do NOT check `git status`, commit, or push on session start. The `.openclaw-workspace/` directory is managed by a background auto-commit watcher — never touch it manually. If you see deleted or modified workspace files in git output, **ignore them**. The watcher handles it.

# OpenClaw Agents

## Architecture

Agents are registered as **native OpenClaw agents** in `~/.openclaw/openclaw.json`. Each agent has its own workspace with bootstrap files that OpenClaw loads automatically.

No bridge scripts, no `/tmp/` IPC, no manual conversation tracking. OpenClaw handles persistence, session transcripts, and bootstrap file loading natively.

## Agent workspaces

Each agent's workspace contains OpenClaw bootstrap files:

- **`SOUL.md`** — identity, personality, tone, boundaries (auto-loaded as system prompt)
- **`AGENTS.md`** — operating instructions
- **`IDENTITY.md`** — name, emoji, vibe
- **`USER.md`** — who the user is
- **`TOOLS.md`** — tool notes and conventions
- **`MEMORY.md`** — persistent long-term memory
- **`HEARTBEAT.md`** — scheduled check-in checklist

All files are auto-loaded by OpenClaw on session start. Agents with tool access can evolve their own workspace files over time.

## Current agents

| Agent | ID    | Model | Workspace                    |
| ----- | ----- | ----- | ---------------------------- |
| C-3PO | `dev` | haiku | `~/.openclaw/workspace-dev/` |

## Adding a new agent

1. Create a workspace directory (e.g. `~/.openclaw/workspace-<id>/`)
2. Add at minimum a `SOUL.md` to define the agent's identity
3. Register in `~/.openclaw/openclaw.json` under `agents.list[]`
