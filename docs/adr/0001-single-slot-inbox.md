# Single-slot inbox with consume-on-read

The inbox (`.agents/INBOX.md`) holds one message at a time: writers may only write into an empty inbox, and the reader archives the message to `.agents/archive/` and empties the file as part of reading. We chose this over an append-only shared log because sessions are stateless between runs and a log would force read cursors, message IDs, and "which messages are new" bookkeeping onto them, while a single consumed slot needs none of that and makes stale messages from old tasks impossible. The cost is strict turn-taking and no message batching, which the human router already provides.

## Considered options

- **Append-only log** (rejected): simple writes, but every reader needs a cursor or re-reads everything forever, and old messages accumulate and confuse new tasks.
- **One file per message** (rejected): no cursor problem, but now the protocol needs naming rules and a way to tell sessions which files to read.
