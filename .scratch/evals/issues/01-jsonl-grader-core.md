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
