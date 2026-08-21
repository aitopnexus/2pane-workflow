---
name: two-pane-workflow
description: Use when the human asks to send or read the two-pane inbox, or names Main, Expert, or AGENT_ROLE as a workflow role.
---

# Two-pane workflow

The human routes work between Main and Expert through one shared slot. `AGENT_ROLE=expert` selects Expert; an unset value selects Main. Launch Expert with `./2pane expert`.

## Send

Run `./2pane send 'message'`. It checks the slot and publishes the complete message. A busy-slot error means an unread message awaits the other session; tell the human.

Yield after a successful send; report the send and wait for a new human request before taking a reply.

## Receive

1. Run `./2pane take`. No output means the slot is empty.
2. Do the work in the printed message.
3. Send only the requested result fields through `./2pane send 'reply'`; its slot check replaces another read.
4. After sending the reply, yield with only a terse acknowledgment.

## Boundary

Touch the slot only when the human asks. The human is the router and serializes writers.
