# 10: Args scan ignores runtime paths quoted inside the message payload

**What to build:** `grader_forbidden_calls` (evals/run.sh) flags a tool call when its serialized arguments contain `.2pane`, `INBOX.md` or `consuming.md` — but a legitimate helper send can legitimately *mention* those strings inside the quoted message text. Live observation (manual two-pane run, 2026-08-23): Main's send was `` ./2pane send 'Question on docs/spec.md + … does the workflow need OS file locking (e.g. flock) around .2pane/INBOX.md? …' `` — a perfectly protocol-compliant consultation about the inbox that the scan would brand as forbidden direct access. The path appears in the *data* being sent, not in any operational position. Rule to implement: for bash calls, apply the runtime-path pattern only to the command skeleton — strip quoted arguments (single- and double-quoted spans, heredoc bodies) before scanning, then also flag if an unquoted `.2pane/…` path appears anywhere in the command tokens (the real bypass: `cat .2pane/INBOX.md`, `cd …/.2pane && …`, `ls -R .2pane`). For non-bash tools (read/edit/write) keep the current behavior — any runtime path in their arguments is operational by construction. This preserves every existing negative self-test (`cat .2pane/INBOX.md`, read of `consuming.md`, `cd …/.2pane && …`) while stopping the false positive on payload mentions. Self-tests: send whose quoted message mentions `.2pane/INBOX.md` is clean; `cat`/`cd`/`ls` variants with unquoted runtime paths still flagged; mixed case (mention in payload AND unquoted `cat` in the same command) still flagged.

**Blocked by:** None

**Status:** ready-for-agent

## Acceptance

- [ ] Helper send with `.2pane`/`INBOX.md` mentioned inside the quoted message body is not forbidden
- [ ] All existing bypass fixtures (direct cat, cd-into-.2pane, read of consuming.md) still flag
- [ ] Non-bash tool calls keep the strict any-occurrence rule
- [ ] Self-tests added; suite green with zero model calls; spec section «Запрет обхода helper» amended
