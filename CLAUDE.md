# OpenClaw Bot Bridge

## How it works

Bot personas are registered in `scripts/bots.json`. Each bot has:

- **`id`** — unique name, becomes the IPC subdirectory
- **`prefix`** — the trigger string the user types before their message
- **`model`** — which Claude model the subagent uses (`haiku`, `sonnet`, `opus`)
- **`persona`** — system prompt for the subagent
- **`sessionKey`** — OpenClaw session to inject into

## Routing rules

When the user's message starts with a registered bot prefix, route it through the bridge:

1. Strip the prefix from the message
2. Read `/tmp/openclaw-bridge/<bot-id>/conversation.json` for history
3. Append the user's message (role: `user`) to that conversation file
4. Spawn a subagent using the bot's **model** with its **persona** as system prompt and the full conversation history
5. Run `/tmp/openclaw-bridge/<bot-id>/inject.sh "<response>"` to inject into OpenClaw
6. Display the response to the user

If `/tmp/openclaw-bridge/<bot-id>/` doesn't exist, run `bash scripts/c3po-bridge-setup.sh` first.

## Current bots

| Prefix | Bot  | Model | Persona                                                               |
| ------ | ---- | ----- | --------------------------------------------------------------------- |
| `>>`   | c3po | haiku | C-3PO protocol droid — anxious, overly formal, worried about the odds |

To add a new bot, append an entry to `scripts/bots.json` and re-run the setup script.
