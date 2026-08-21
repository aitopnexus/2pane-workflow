---
name: two-pane-workflow
description: Two-pane workflow protocol. Use when the human mentions the inbox or .agents/INBOX.md, the other session, the main or expert role, AGENT_ROLE, or the two-pane workflow.
---

# Two-pane workflow

You are one of two sessions the human runs on this repository, coordinated through a single shared file.

## Detect your role

Run `echo "${AGENT_ROLE:-main}"`. The value is your role, `expert` or `main`.

## The inbox

`.agents/INBOX.md` is a single slot holding at most one message, addressed by sender:

    from: main

    Message content for the other session.

A message is for you when its `from:` line names the other role.

## Write a message

1. Read `.agents/INBOX.md`. An empty file is your green light.
2. Write the whole message in one write: the `from:` line with your role, then the content.

A non-empty inbox means an unread message awaits the other session. Tell the human and wait; overwriting destroys it.

## Consume a message

1. Read `.agents/INBOX.md`.
2. When the `from:` line names the other role, the message is yours.
3. Archive first: copy the message to `.agents/archive/<timestamp>-from-<role>.md`, where `<timestamp>` is the output of `date +%Y-%m-%d-%H%M%S` and `<role>` is the sender on the `from:` line. Create the directory if needed.
4. Empty `.agents/INBOX.md`.
5. Do the work described in the archived message.
6. When the work needs a reply, write your own message with the write procedure.

The consume is complete when the archive file exists, the inbox is empty, and any reply is written.

## Rules

- The human is the only router. Touch the inbox exactly when triggered: by the human, or by your launch prompt telling you to check it once.
- The human serializes writers. One session writes at a time; the protocol has no locking.
- Both roles have full access to the repository. Main owning normal work is a convention the human enforces by routing.
