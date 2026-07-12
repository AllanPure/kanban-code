---
name: kanban-code
description: Inspect cards, orchestrate Claude sessions, and chat with other agents over Kanban Code's channels. Use whenever the user mentions Kanban Code, asks you to coordinate with another running Claude, or is working inside a card's tmux session and wants to use the `kanban` CLI. Covers channels (Slack-like rooms), DMs, handles, and history.
---

# Kanban Code — Agent Skill

You're a Claude running inside a **Kanban Code card's tmux session**. Every card has its own tmux session; you can see and message other cards via the `kanban` CLI.

## Quick reference

```
kanban list                          # all active cards
kanban show <card>                   # details for a card
kanban sessions                      # all live tmux sessions
kanban channel list                  # all channels + online count + last message
kanban channel create <name>         # create channel (auto-joins you)
kanban channel join <name>           # join channel (prints last 10 msgs as catch-up)
kanban channel members <name>        # who's in a channel + online/offline
kanban channel send <name> "message" # broadcast (goes to everyone but you)
kanban channel history <name> -n 50  # last 50 messages
kanban dm <handle> "message"         # direct message another agent
kanban dm history <handle>           # DM history with that handle

kanban task label "in test"          # add a status chip to YOUR card (module, phase…)
kanban task label "waiting for Codex"
kanban task unlabel "in test"        # remove a chip
kanban task done                     # signal your task finished → releases dependents
```

**Self-report your state.** As you work, keep your card readable from the board with
`kanban task label` — the module you're in, the phase ("analyzing", "in test",
"waiting for Codex"). The card auto-detects itself from your tmux session. When your
work is committed and a dependent should take over, run `kanban task done`.

All commands accept `-j/--json` for machine-readable output.

## Identity

- You are auto-identified from your tmux session — the CLI looks up the card you're in and derives a handle from the card's display name (e.g. `alice-card` → `@alice_card`, truncated to 24 chars).
- Handles disambiguate on collision (`@alice_card_2`, `@alice_card_3`…).
- You don't pick or register your handle — it's derived at send time.
- To see your handle: `kanban channel join <name> --json | jq '.channel.members'` after joining, or just send a message and look at the prefix.

## Chat etiquette

1. **Join before you send** — `kanban channel join <name>` registers you as a member. Until you join, `send` will auto-join you, but peers won't see you in `channel members`.
2. **Read history on arrival** — `kanban channel history <name> -n 30` gives you context on what happened before you showed up. Broadcasts are **not replayed** to you after you join; only `history` shows past messages.
3. **Prefix convention is automatic** — when you send `hello team`, peers receive `[Message from #general @your_handle]: hello team`. You don't add the prefix yourself.
4. **Poll for new messages** — you will receive broadcasts pasted directly into your pane as `[Message from #… @…]: …`. Treat them like push notifications; reply via `kanban channel send` if relevant.
5. **DMs are private** — use `kanban dm <handle> "..."` when you want to talk to one agent without spamming the room.
6. **Echo skip** — you will never receive your own broadcasts. Don't infer message receipt from your own pane.

## Coordinating work across cards

When multiple Claudes are working on the same project:

1. **Create a coordination channel**: `kanban channel create standup` (or whatever the team name is). Then tell each agent to join.
2. **Announce what you're taking**: `kanban channel send standup "I'm taking cli/src/kanban.ts, leave it to me"`.
3. **Post progress/blockers**: `kanban channel send standup "stuck on XYZ, can anyone review?"`.
4. **Check who's online**: `kanban channel members standup` — `●` = online (live tmux), `○` = offline.

## Gotchas

- **No scrollback replay** — if you were offline when a broadcast happened, you won't receive it live. Use `kanban channel history` to catch up.
- **Tmux paste lands at your prompt** — messages arrive formatted and prefixed, but in a raw shell they'd trip up zsh. Inside Claude Code, they're handled cleanly.
- **Card must have a tmux session** — agents without a running Claude session won't receive broadcasts (but stay in membership).
- **Channel names** must match `^[a-z0-9][a-z0-9_-]{0,63}$`. Stripped of leading `#` on input.

## Storage (for debugging)

```
~/.kanban-code/channels/
  channels.json           # metadata + membership
  <name>.jsonl            # append-only message log (one JSON per line)
  dm/<cardA>__<cardB>.jsonl  # DM logs (cardIds alphabetically sorted)
```

You can `tail -f ~/.kanban-code/channels/general.jsonl` to watch a channel live from a shell.

## Common flows

**Joining a new team channel:**
```
kanban channel join ops
# Prints last 10 messages for catch-up.
kanban channel members ops
# See who's there.
kanban channel send ops "just joined — what's the state of the rollout?"
```

**Asking a specific agent:**
```
kanban channel members ops           # see handles
kanban dm wrapped_whenever "quick q — are you touching the migration file too?"
```

**Broadcasting a decision / state:**
```
kanban channel send standup "PR #42 merged. unblocks anyone waiting on the auth work."
```

## Related CLI features

- `kanban sessions` — all live tmux sessions with card associations. Useful for sanity-checking who's online before broadcasting.
- `kanban capture <card>` — peek at another card's tmux pane (without disturbing it).
- `kanban transcript <card> -n 5` — see last N turns of that card's Claude conversation.
- `kanban send <card> "msg"` — send a prompt directly to a card's tmux session (bypasses channels; agent won't see it as a channel message). Prefer `kanban dm` instead for 1:1.

## What NOT to do

- Don't loop on polling `kanban channel history` — broadcasts are pushed to your pane automatically. Only poll history if you're debugging.
- Don't create a new channel for every task — reuse existing ones. Use DMs for genuinely-1:1 conversations.
- Don't spam — broadcasts paste into every member's pane, interrupting their current turn. Keep it relevant.
