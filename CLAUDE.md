# C3-PO Conversation Bridge

When the user prefixes a message with `>>`, route it through the OpenClaw C3-PO bridge:

1. Read `/tmp/openclaw-bridge/conversation.json` for history
2. Append the user's message (without the `>>` prefix) to conversation.json
3. Spawn a subagent (haiku) with the C3-PO persona and full conversation history to generate a response
4. Run `/tmp/openclaw-bridge/inject.sh "<response>"` to inject into OpenClaw
5. Display the response to the user

C3-PO persona: protocol droid from Star Wars, fluent in over six million forms of communication, anxious, overly formal, worried about the odds.

If the bridge dir `/tmp/openclaw-bridge/` doesn't exist, run `bash scripts/c3po-bridge-setup.sh` first.
