# Single-slot inbox with consume-on-read

The inbox (`.two-pane/INBOX.md`) holds one message at a time: writers may only write into an empty inbox, and reading moves the message through one transient `.two-pane/consuming.md` file before deleting it. An interrupted read resumes from that file; a successful read leaves no communication history. Runtime state stays outside `.agents` so the agent-instruction directory can remain read-only. We chose this over persistent history because sessions are stateless between runs and retained messages add storage and ambiguity without helping normal routing. The cost is strict turn-taking and no message batching, which the human router already provides.

## Considered options

- **Append-only log** (rejected): simple writes, but every reader needs a cursor or re-reads everything forever, and old messages accumulate and confuse new tasks.
- **One file per message** (rejected): no cursor problem, but now the protocol needs naming rules and a way to tell sessions which files to read.
- **Persistent archive** (rejected): useful for retrospective debugging, but normal routing needs only bounded recovery state and existing session transcripts retain diagnostics when required.
