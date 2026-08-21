# Two-Pane Agent Workflow Specification

## Purpose

A minimal collaboration protocol for running two AI agent sessions on the same repository.

- One main session owns normal work.
- One expert session provides additional reasoning on request.
- A single shared file carries one message at a time between them.

The human decides which session handles each task. The human is the only router.

## Roles

### Main

The default role. A session with no role configured is main. Main owns normal work on the repository and can be any harness, for example codex or pi.

### Expert

The consultation role, for analysis, second opinions, and difficult problems. The expert is launched with the `expert` script and is codex by default.

Both roles have full access to the repository. Nothing in the protocol restricts what a session may do. "Main owns normal work" is a convention the human enforces by routing, not a rule the protocol enforces.

## The inbox

All communication flows through one file:

```
.agents/INBOX.md
```

The inbox is a single slot. It holds at most one message at a time.

- Write only into an empty inbox. If you need to write and it is not empty, tell the human. Never overwrite.
- A message is addressed by sender. If the `from:` line names the other role, the message is yours.
- Reading consumes. The reader archives the message and empties the file, so the same message is never read twice and the next writer always finds an empty slot.
- One session writes at a time. The human serializes. The protocol has no locking.

## Message format

A message is a `from:` line followed by free-form content:

```
from: main

Question or content for the other session...
```

## Procedures

### Writing a message

1. Check the inbox is empty.
2. Write the `from:` line with your role, then the content.

### Reading and consuming

1. Read `.agents/INBOX.md`.
2. If the `from:` line names the other role, the message is yours.
3. Archive it first: copy the message to `.agents/archive/<YYYY-MM-DD-HHMMSS>-from-<role>.md`.
4. Then empty the inbox.

Archive before emptying. A crash mid-consume then loses nothing.

## Components

Two items, copied into any repository that adopts the workflow.

### 1. The protocol skill

```
.agents/skills/two-pane-workflow
```

One skill describing this protocol. Codex and pi both discover `.agents/skills` automatically and list the skill in every session, loading it when the task matches its description. The description must stay scoped to inbox and role words so the skill never triggers during normal work.

No edits to AGENTS.md or any other repo file. The skill is the whole protocol.

### 2. The expert script

An executable at the repo root, run as `./expert`:

```bash
#!/usr/bin/env bash
export AGENT_ROLE=expert
herdr pane current &>/dev/null && herdr pane rename expert
exec codex "You are the EXPERT session in the two-pane workflow. Protocol: .agents/skills/two-pane-workflow/SKILL.md. Check the inbox." "$@"
```

What it does:

- Sets `AGENT_ROLE=expert`, the machine-readable source of truth for role detection.
- Renames the herdr pane to "expert" when running inside herdr, so the two windows are distinguishable.
- Starts codex with an initial prompt that announces the role, points at the protocol skill, and tells the session to check the inbox. Extra arguments pass through, so `./expert --model <id>` still works.

The launch itself is the human's trigger. No other automatic reading exists in the protocol.

Swapping which harness plays expert means editing the `exec` line.

## Role detection

The role comes from the environment:

```
AGENT_ROLE=expert
```

Unset means main. Only the expert session needs configuration. The protocol skill reads `$AGENT_ROLE` rather than parsing prose.

## Installation

Copy two items into the target repo:

1. `.agents/skills/two-pane-workflow/`
2. `expert` (the script), then `chmod +x expert`

Nothing else. No dotfiles changes, no AGENTS.md edits, no dependencies.

In repos where `.agents/.gitignore` excludes vendored skills, keep the protocol tracked:

```
skills/*
!skills/two-pane-workflow/
```

In pi, approve the per-project trust prompt once when first asked. Pi gates `.agents/skills` behind project trust; codex does not.

## Principles

- Keep the protocol simple.
- The human decides which session handles each task. The human is the only router.
- The human is the serializer. One session writes at a time.
- Write only into an empty inbox.
- Main owns normal work. Expert provides additional reasoning.
- Both roles may do anything. Restrictions are conventions, not rules.
- No polling, no automatic routing, no orchestration.
- The main session needs a harness that discovers skills in `.agents/skills`. The expert additionally needs a harness that accepts an initial prompt.
