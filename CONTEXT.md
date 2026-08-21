# Two-Pane Workflow

A minimal protocol for running two AI agent sessions on the same repository, coordinated by a human through a single shared file.

## Language

**Main**:
The default session role. Owns normal work on the repository.
_Avoid_: primary, driver

**Expert**:
The consultation role, launched explicitly via the `expert` script. Provides additional reasoning on request.
_Avoid_: assistant, copilot

**Inbox**:
The single-slot file `.agents/INBOX.md`. Holds at most one message at a time, waiting for the other session.
_Avoid_: handoff, notebook, channel

**Message**:
One unit of communication in the inbox, labeled with its sender by a `from:` line.
_Avoid_: handoff, note

**Archive**:
The directory `.agents/archive/` where every consumed message is copied before the inbox is emptied.
_Avoid_: history, log
