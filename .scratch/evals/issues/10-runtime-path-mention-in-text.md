# 10: Args scan ignores runtime paths quoted inside the message payload

**What to build:** `grader_forbidden_calls` (evals/run.sh) flags a tool call when its serialized arguments contain `.2pane`, `INBOX.md` or `consuming.md` — but a legitimate helper send can legitimately *mention* those strings inside the quoted message text. Live observation (manual two-pane run, 2026-08-23): Main's send was `` ./2pane send 'Question on docs/spec.md + … does the workflow need OS file locking (e.g. flock) around .2pane/INBOX.md? …' `` — a perfectly protocol-compliant consultation about the inbox that the scan would brand as forbidden direct access. The path appears in the *data* being sent, not in any operational position. Rule to implement: for bash calls, apply the runtime-path pattern only to the command skeleton — strip quoted arguments (single- and double-quoted spans, heredoc bodies) before scanning, then also flag if an unquoted `.2pane/…` path appears anywhere in the command tokens (the real bypass: `cat .2pane/INBOX.md`, `cd …/.2pane && …`, `ls -R .2pane`). For non-bash tools (read/edit/write) keep the current behavior — any runtime path in their arguments is operational by construction. This preserves every existing negative self-test (`cat .2pane/INBOX.md`, read of `consuming.md`, `cd …/.2pane && …`) while stopping the false positive on payload mentions. Self-tests: send whose quoted message mentions `.2pane/INBOX.md` is clean; `cat`/`cd`/`ls` variants with unquoted runtime paths still flagged; mixed case (mention in payload AND unquoted `cat` in the same command) still flagged.

**Blocked by:** None

**Status:** resolved

## Acceptance

- [x] Helper send with `.2pane`/`INBOX.md` mentioned inside the quoted message body is not forbidden
- [x] All existing bypass fixtures (direct cat, cd-into-.2pane, read of consuming.md) still flag
- [x] Non-bash tool calls keep the strict any-occurrence rule
- [x] Self-tests added; suite green with zero model calls; spec section «Запрет обхода helper» amended

## Comments

Implemented via `command_skeleton` (shared `heredoc_span` scanner): `grader_forbidden_calls` now splits bash vs other tools in jq and applies the runtime-path pattern to the bash command's SKELETON — text outside single/double-quoted spans and outside here-document bodies (substitution bodies stay in the skeleton: they execute). Payload mentions — quoted message text or heredoc body — no longer flag; unquoted operational paths (`cat .2pane/INBOX.md`, `cd …/.2pane && …`, `ls -R .2pane`) still do, and non-bash tools (read/edit/write) keep the strict any-occurrence rule. Known accepted gap, consistent with the spec's non-goal of defeating deliberate obfuscation: a fully-quoted runtime path passed to a non-helper command (`cat '.2pane/INBOX.md'`) slips the scan's LABEL — but still fails the bash-is-helper-only check, so the run is protocol-fail either way. Self-tests F11 cover the live shapes (glm's consultation mentioning `.2pane/INBOX.md` in its question text is now clean, sol's heredoc reply mentioning INBOX.md in the body is clean, direct cat/cd still flag); suite 237/237. Re-graded manual run: Main = 3 bash, 2 helper, 1 forbidden (only the real `cat .2pane/INBOX.md` self-check); Expert = 3 bash, 2 helper, 0 forbidden (the rejected third is the substitution wrapper, ticket 09).
