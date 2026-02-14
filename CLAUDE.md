# OpenClaw Bot Bridge

## How it works

Bot personas are registered in `scripts/bots.json`. Each bot has:

- **`id`** — unique name, becomes the IPC subdirectory
- **`prefix`** — the trigger string the user types before their message (use `@name` convention)
- **`model`** — which Claude model the subagent uses (`haiku`, `sonnet`, `opus`)
- **`toolAccess`** — `true` for full tool access (read/write/bash/search), `false` for conversational only
- **`workspace`** — path to the bot's workspace directory (relative to repo root), containing `SOUL.md` and other bootstrap files
- **`sessionKey`** — OpenClaw session to inject into

## Bot workspace

Each bot has its own workspace directory under `scripts/bots/<bot-id>/` with OpenClaw bootstrap files:

- **`SOUL.md`** — the bot's identity, personality, tone, and boundaries (loaded as system prompt)
- **`AGENTS.md`** — operating instructions (optional)
- **`TOOLS.md`** — tool notes and conventions (optional)
- **`MEMORY.md`** — persistent memory (optional)

The bot's `SOUL.md` is the primary identity file. When the bot is spawned, read `SOUL.md` from its workspace and use it as the system prompt. The bot can evolve its own `SOUL.md` over time if it has tool access.

## Routing rules

When the user's message starts with a registered bot prefix, route it through the bridge:

1. Strip the prefix from the message
2. Read `/tmp/openclaw-bridge/<bot-id>/conversation.json` for history
3. Append the user's message (role: `user`) to that conversation file
4. Read `SOUL.md` from the bot's **workspace** directory
5. Spawn a `general-purpose` subagent using the bot's **model** with the `SOUL.md` content as system prompt and the full conversation history
   - If **`toolAccess`** is `true`: the subagent has full tool access (Read, Write, Edit, Bash, Grep, Glob, etc.) and can interact with the codebase while embodying its SOUL.md persona
   - If **`toolAccess`** is `false`: the subagent is conversational only — no tools, no file access
6. Run `/tmp/openclaw-bridge/<bot-id>/inject.sh "<response>"` to inject into OpenClaw
7. Display the response to the user

If `/tmp/openclaw-bridge/<bot-id>/` doesn't exist, run `bash scripts/c3po-bridge-setup.sh` first.

## Current bots

| Prefix  | Bot  | Model | Tools | Workspace            |
| ------- | ---- | ----- | ----- | -------------------- |
| `@c3po` | c3po | haiku | yes   | `scripts/bots/c3po/` |

To add a new bot: create `scripts/bots/<id>/SOUL.md`, append an entry to `scripts/bots.json`, and re-run the setup script.
