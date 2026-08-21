---
name: two-pane-workflow
description: 2pane inbox routing between Main and Expert. Use for explicit send/receive requests or AGENT_ROLE configuration.
---

# Two-pane workflow

The human triggers and serializes each inbox action. `AGENT_ROLE=expert` selects Expert; unset selects Main.

After any send, report its result in one line and yield until the human requests the next inbox action.

## Send

Run `./2pane send 'message'`.

## Receive

1. Run `./2pane take`. Empty output means the inbox is empty; report that and yield.
2. Complete the printed request.
3. Send only its requested result fields directly with `./2pane send 'reply'`; `send` performs the slot check.
