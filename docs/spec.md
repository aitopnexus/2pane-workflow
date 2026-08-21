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

The consultation role, for analysis, second opinions, and difficult problems. The Expert is launched with `./2pane expert` and is codex by default.

Both roles have full access to the repository. Nothing in the protocol restricts what a session may do. "Main owns normal work" is a convention the human enforces by routing, not a rule the protocol enforces.

## The inbox

All communication flows through one file:

```
.2pane/INBOX.md
```

The inbox is a single slot. It holds at most one message at a time.
Runtime state stays outside `.agents`, leaving the agent-instruction directory read-only while the helper writes inside the normal workspace boundary.

- Write only into an empty inbox. If you need to write and it is not empty, tell the human. Never overwrite.
- A message is addressed by sender. If the `from:` line names the other role, the message is yours.
- Reading consumes. The reader returns the message and frees the inbox without retaining communication history.
- One session writes at a time. The human serializes. The protocol has no locking.

## Message format

A message is a `from:` line followed by free-form content:

```
from: main

Question or content for the other session...
```

## Procedures

### Writing a message

Run:

```bash
./2pane send 'message'
```

The helper checks the inbox and atomically writes the sender and content. It rejects a non-empty inbox without changing it.

### Reading and consuming

Run:

```bash
./2pane take
```

The helper validates that the sender is the other role, moves the message to `.2pane/consuming.md`, recreates the empty inbox, and prints the message. A successful take deletes the transient file; a later take resumes it after an interruption. It prints nothing when neither file contains a message.

A reply can go directly through `2pane send`; its built-in slot check replaces another inbox read.
After sending, the session reports success and yields. A later human request starts the reply read.
Replies contain only the result fields the request asks for.

## Components

Two items are copied into any repository that adopts the workflow.

### 1. The protocol skill

```
.agents/skills/two-pane-workflow
```

One skill tells the model when to call the state helper and when to act on its output. Codex and pi both discover `.agents/skills` automatically and load it when the task matches its description. The description stays scoped to inbox and workflow-role words.

### 2. The `2pane` executable

An executable at the repo root, with one command for each workflow operation:

```text
2pane
2pane expert [codex-options...]
2pane send [message]
2pane take
2pane init
```

Running `2pane` without arguments, or with `--help`, prints usage. It owns role validation, initialization, busy-slot checks, atomic publication, transient consume recovery, and Expert launching. The model does not reproduce those mechanics.

What it does:

- Initializes runtime state without changing an existing message.
- Sets `AGENT_ROLE=expert`, the machine-readable source of truth for role detection.
- Renames the herdr pane to "expert" when running inside herdr, so the two windows are distinguishable.
- Keeps shell, editing, native cached web search, and project skills while disabling capabilities unrelated to repository consultation.
- Caps retained tool output at 4,000 tokens so large command results do not inflate later turns.
- Starts codex without an initial inbox check. Extra arguments pass through, so `./2pane expert --model <id>` still works. Use `EXPERT_FULL=1 ./2pane expert` when a consultation needs the normal plugin and tool set.

Launching Expert spends no model turn on an empty inbox. The human explicitly asks a pane to read when a message is waiting.

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
2. `2pane`

Then run `chmod +x 2pane`. No global configuration, AGENTS.md edits, or external dependencies are required.

Ignore runtime state in the target repository:

```text
.2pane/
```

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
- Publish only through `2pane send`; it rejects a busy inbox.
- Keep only transient recovery state; successful reads leave no communication history.
- Main owns normal work. Expert provides additional reasoning.
- Both roles may do anything. Restrictions are conventions, not rules.
- No polling, no automatic routing, no orchestration.
- Each session needs a harness that discovers skills in `.agents/skills`.
