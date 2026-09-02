# 01: JSONL grader core with synthetic-fixture self-tests

**What to build:** The deterministic grading brain of the eval, runnable and verifiable with zero model calls. A self-test mode feeds small synthetic pi-JSONL sessions through the grader helpers and reports pass/fail, so the extraction logic is proven before any pi run exists. The grader handles: selecting `type == "message"` entries and working with the nested `.message`; extracting tool calls from assistant `toolCall` content blocks (name + command for bash); pairing each tool call to its `toolResult` by id and checking `isError`, result text and file state; recognizing a helper invocation only as a standalone shell token `./2pane` with subcommand `send` or `take` (mere mentions in text don't count); flagging any tool call whose serialized arguments contain the runtime paths; extracting the final answer as the last assistant message with `stopReason == "stop"`, joining only `text` content blocks (thinking, intermediate text and tool output excluded); and summing usage per role from assistant messages, nested `toolResult` usage, and `compaction`/`branch_summary` entries.

This is a deliberate prefactor: every later ticket builds on these helpers, and the synthetic fixtures guard against a pi JSONL format change silently producing empty grading.

**Blocked by:** None (can start immediately)

**Status:** resolved

- [x] Synthetic fixtures cover: successful helper call, errored tool result, intermediate assistant text, missing final message, assistant usage, nested toolResult usage, `compaction` and `branch_summary` usage
- [x] Helper-call detection accepts standalone `./2pane send ...` / `./2pane take` and rejects mentions embedded in other text or chained shell commands
- [x] Forbidden-path detection fires on tool arguments containing the runtime paths and does not fire on a normal helper invocation
- [x] Final-message extraction returns only text blocks of the last `stopReason == "stop"` assistant message, or a clean "absent" signal
- [x] Usage summation produces input/output/cacheRead/cacheWrite/totalTokens/cost totals, modelCalls and toolCalls counts from the fixture set
- [x] Self-tests run without any model call and fail loudly (nonzero exit) when any expectation breaks

## Comments

Implemented in `evals/run.sh` as a `self-test` subcommand (grader core + fixtures in one self-contained file, per the spec's file layout). 32 checks, all passing, zero model calls.

- Grader helpers: `grader_tool_events` (call→result pairing by id, ok/error/unresolved), `grader_bash_calls`, `grader_helper_calls` (first-token `./2pane` + subcommand + quote-aware standalone scan), `grader_forbidden_calls` (`.2pane`/`INBOX.md`/`consuming.md` in serialized args), `grader_final_text` (last stop assistant, text blocks only, clean absent signal), `grader_usage` (assistant + nested toolResult + compaction/branch_summary, modelCalls, toolCalls).
- Session-format shapes were cross-checked against real pi sessions on this machine, including an entry-level `compaction` usage object (with an extra `reasoning` field). `branch_summary` was not observable in any real session; it is handled symmetrically with compaction and pinned by fixture only.
- Decisions: modelCalls counts assistant messages (nested toolResult usage adds tokens only); cost fields are rounded to 12 decimals in `grader_usage` so output stays byte-stable across jq float printing — gates run on integer token counts, costs are reporting data; a final message whose text blocks are all empty counts as absent.
- Verification: `bash -n`, `shellcheck` clean, `evals/run.sh self-test` → pass=32 fail=0 exit=0; all four existing `tests/*.sh` still pass; usage errors and unknown commands exit 2.
- The `protocol`/`baseline`/`economy` subcommands exist as exit-2 stubs — the CLI seam for tickets 02–07.

- 2026-08-22 bugfix: `grader_reads_outside_fixture` falsely flagged reads made through the physical (symlink-resolved) spelling of the eval workdir. On macOS `/tmp` is a symlink to `/private/tmp`, and a live economy run (results `20260822T130756Z-62114`) was graded `protocol-fail` because the model read `docs/spec.md` and the ADR via `/private/tmp/2pane-workflow-eval-workdir/...` — the same fixture files, canonical spelling. The grader now resolves the workdir with `pwd -P` and accepts both spellings; when the workdir does not exist only the literal spelling matches (an empty alias must match nothing). Deterministic self-test added (own symlink + `pwd -P`, platform-independent); suite 219/219; live re-run of the same economy command classifies `pass`, verdict `pass`. Recorded runs are never regraded in place — the false `protocol-fail` stays in that result directory as history.

- 2026-08-22 change: helper-call recognition now accepts an inert `cd DIR &&` prefix before the standalone `./2pane send|take` (live observation: glm-5.3 spells the call `cd <workdir> && ./2pane send ...`; the cd is inert and the helper runs correctly, so grading it as "bash but not helper" conflated a spelling quirk with real bypasses). Rule: split on unquoted `&&` (quote-aware), the LAST segment must be the standalone helper as before, every earlier segment must be a `cd …` with no chaining/redirection. Everything else still rejects — helper-not-last, pipes, non-cd segments, non-send/take — and the forbidden-path args scan is unchanged, so `cd …/.2pane && ./2pane take` passes shape but is flagged by the scan (pinned by self-test as the defense-in-depth pair). Re-grading the stored glm-5.3 protocol sessions with the new grader: S2 flips to pass, S1 recognizes the send but still fails on the extra `ls` exploration, S4 still fails on real direct access — form forgiven, substance not. Suite 227/227; baselines unaffected (their assertions are unchanged and a more permissive grader cannot un-pass a published baseline).
