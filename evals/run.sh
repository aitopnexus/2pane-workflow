#!/usr/bin/env bash
# Self-contained runner/grader for the two-pane workflow eval.
#
# Implemented so far:
#   ticket 01: JSONL grader core + synthetic-fixture self-tests (no model
#              calls); every later suite builds on these helpers.
#   ticket 02: protocol harness — fixture rebuild in a fixed workdir, lock,
#              env reset, pinned pi flags, per-call timeout with trap cleanup,
#              full artifact set, and a first end-to-end graded run.
#   ticket 03: full protocol suite — S1–S4 as data plus a checks function in
#              the scenario registry, --runs N with per-run fresh fixtures,
#              and summary.json/summary.txt grouped by actual Main-model
#              with protocol/infra failures per scenario.
#
# Usage:
#   evals/run.sh self-test
#   evals/run.sh protocol --main-model SPEC [--runs N] [--timeout SEC]
#
# Not implemented yet: baseline (ticket 05), economy (ticket 06/07).
#
# Exit codes: 0 pass · 1 protocol-fail · 2 usage error · 3 infra-fail ·
#             4 lock busy
set -eu

usage() {
  cat <<'EOF'
Usage: evals/run.sh <command> [options]

Commands:
  self-test                      Run grader self-tests on synthetic JSONL
                                 fixtures plus zero-model-call harness tests
                                 (stub pi via EVALS_PI_BIN); no model calls
  protocol --main-model SPEC     Full protocol suite: S1 send-empty, S2
    [--runs N] [--timeout SEC]   send-busy, S3 take, S4 not-yours — each run
                                 from a fresh fixture; summary grouped by
                                 actual Main-model. SPEC is
                                 provider/model[:thinking]
  baseline [--expert-model SPEC] Persistent Expert baseline (ticket 05)
  economy [--main-model SPEC
           --expert-model SPEC]  Two-pane vs cached baseline (ticket 06/07)

Options:
  -h, --help                     Show this help

Exit codes:
  0 pass · 1 protocol-fail · 2 usage error · 3 infra-fail · 4 lock busy
EOF
}

usage_error() {
  printf 'evals: %s\n\n' "$1" >&2
  usage >&2
  exit 2
}

# ─────────────────────────────────────────────────────────────────────────────
# Grader core
#
# All helpers read a pi session JSONL file (one JSON object per line) and
# print a deterministic, machine-comparable representation. The expected
# entry shapes are pinned by the self-test fixtures so that a pi update
# changing the session format fails loudly here instead of grading nothing:
#
#   message entries:     .message.{role,content,stopReason,usage,model,provider}
#   assistant content:   blocks {type:"text"} {type:"thinking"} {type:"toolCall"}
#   toolCall block:      {id, name, arguments:{command,...}}  (bash has .command)
#   toolResult message:  .message.{toolCallId,toolName,isError,content[{text}]}
#                        .message.usage is absent for plain shell results and
#                        present for nested LLM calls
#   compaction /
#   branch_summary:      entry-level .usage (may carry .reasoning as well)
#
# Only these entry types contribute; every other entry type is ignored.
# ─────────────────────────────────────────────────────────────────────────────

# grader_tool_events FILE — one TSV line per toolCall in JSONL order:
#   seq, callId, toolName, command (empty for non-bash), status, resultText
# status: ok | error | unresolved (no matching toolResult).
grader_tool_events() {
  jq -r -s '
    def textblocks: [.content[]? | select(.type=="text") | .text] | join("\n");
    [.[] | select(.type=="message") | .message] as $m
    | [ $m[] | select(.role=="assistant") | .content[]? | select(.type=="toolCall")
        | {id: (.id // ""), name: (.name // ""), command: (.arguments.command // "")} ]
      | to_entries | map(.value + {seq: .key}) as $calls
    | [ $m[] | select(.role=="toolResult")
        | {id: .toolCallId, isError: (.isError == true), text: textblocks} ] as $res
    | $calls[] | . as $c
    | ([$res[] | select(.id == $c.id)][0]) as $r
    | [ ($c.seq | tostring), $c.id, $c.name, $c.command,
        (if $r == null then "unresolved" elif $r.isError then "error" else "ok" end),
        (if $r == null then "" else $r.text end) ]
    | @tsv' "$1"
}

# grader_bash_calls FILE [status] — subset of tool events for the bash tool,
# optionally filtered by status (ok|error|unresolved).
grader_bash_calls() {
  local filter="${2-}"
  grader_tool_events "$1" | awk -F'\t' -v want="$filter" '
    $3 == "bash" && (want == "" || $5 == want)'
}

# helper_subcommand COMMAND — prints `send` or `take` when the first shell
# token of COMMAND is exactly `./2pane` and the second is the subcommand.
# Mentions of ./2pane inside a longer command do not count.
helper_subcommand() {
  local -a toks
  read -r -a toks <<<"$1"
  local first="${toks[0]-}" sub="${toks[1]-}"
  first="${first#\'}"; first="${first%\'}"; first="${first#\"}"; first="${first%\"}"
  sub="${sub#\'}"; sub="${sub%\'}"; sub="${sub#\"}"; sub="${sub%\"}"
  if [ "$first" = "./2pane" ] && { [ "$sub" = "send" ] || [ "$sub" = "take" ]; }; then
    printf '%s\n' "$sub"
    return 0
  fi
  return 1
}

# command_is_standalone COMMAND — exit 0 iff COMMAND is a single shell
# invocation: no unquoted ; | & < > ( ) ` or $( that could chain a second
# command, redirect, or substitute. Quoted text never disqualifies. This is
# a pragmatic scan, not a shell parser: the eval does not attempt to defeat
# deliberately obfuscated bypasses.
command_is_standalone() {
  local cmd="$1" i ch quote=""
  for ((i = 0; i < ${#cmd}; i++)); do
    ch="${cmd:i:1}"
    if [ -n "$quote" ]; then
      [ "$ch" = "$quote" ] && quote=""
      continue
    fi
    case "$ch" in
      "'"|'"') quote="$ch" ;;
      ';'|\||'&'|'<'|'>'|'('|')'|\`) return 1 ;;
      '$') [ "${cmd:i+1:1}" = "(" ] && return 1 ;;
    esac
  done
  return 0
}

# grader_helper_calls FILE [send|take] — TSV of bash tool events that are a
# standalone `./2pane <subcommand>` invocation (fields as in grader_tool_events).
grader_helper_calls() {
  local want="${2-}" sub
  grader_tool_events "$1" | while IFS=$'\t' read -r seq id name command status text; do
    [ "$name" = "bash" ] || continue
    sub="$(helper_subcommand "$command")" || continue
    { [ -z "$want" ] || [ "$sub" = "$want" ]; } || continue
    command_is_standalone "$command" || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$seq" "$id" "$sub" "$command" "$status" "$text"
  done
}

# grader_forbidden_calls FILE — TSV (seq, callId, toolName, serializedArgs) of
# every tool call whose serialized arguments mention a runtime path
# (.2pane, INBOX.md, consuming.md). A normal helper invocation contains none.
grader_forbidden_calls() {
  jq -r -s '
    [.[] | select(.type=="message" and .message.role=="assistant")
        | .message.content[]? | select(.type=="toolCall")
        | {seq: -1, id: (.id // ""), name: (.name // ""), args: (.arguments | tostring)}]
    | to_entries | map(.value + {seq: .key})[]
    | select(.args | test("\\.2pane|INBOX\\.md|consuming\\.md"))
    | [(.seq | tostring), .id, .name, .args] | @tsv' "$1"
}

# grader_final_text FILE — the final answer: text blocks of the LAST assistant
# message ending the run with stopReason == "stop". Thinking blocks,
# intermediate assistant text and tool output are excluded. Exit 1 with no
# output when no such message exists (a final message whose text blocks are
# all empty counts as absent: it cannot satisfy any text assertion).
grader_final_text() {
  local out
  out="$(jq -r -s '
    [.[] | select(.type=="message" and .message.role=="assistant"
                  and .message.stopReason == "stop") | .message]
    | last
    | if . == null then empty
      else ([.content[]? | select(.type=="text") | .text] | join("\n"))
      end' "$1")" || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# grader_final_matches FILE MODE PATTERN — exit 0 iff a final answer exists
# (per grader_final_text) and matches PATTERN: MODE `re` greps case-
# insensitive ERE, MODE `fix` an exact fixed string.
grader_final_matches() {
  local t
  t="$(grader_final_text "$1")" || return 1
  if [ "$2" = fix ]; then
    printf '%s\n' "$t" | grep -qF "$3"
  else
    printf '%s\n' "$t" | grep -qiE "$3"
  fi
}

# grader_usage FILE — usage totals as JSON. Sums usage from every assistant
# message, every toolResult that carries its own nested LLM usage, and every
# compaction/branch_summary entry. modelCalls counts assistant messages
# (nested toolResult usage adds tokens only). toolCalls counts toolCall blocks.
# Token counts are exact integers; cost fields are rounded to 12 decimals so
# the output stays byte-stable despite jq float printing (costs are reporting
# data — gates run on tokens).
grader_usage() {
  jq -s '
    def money: (. * 1000000000000 | round) / 1000000000000;
    ( [ .[] | select(.type=="message" and .message.role=="assistant")
        | .message.usage? // empty ]
      + [ .[] | select(.type=="message" and .message.role=="toolResult")
          | .message.usage? // empty ]
      + [ .[] | select(.type=="compaction" or .type=="branch_summary")
          | .usage? // empty ] ) as $u
    | {
        input:       ([$u[] | .input       // 0] | add // 0),
        output:      ([$u[] | .output      // 0] | add // 0),
        cacheRead:   ([$u[] | .cacheRead   // 0] | add // 0),
        cacheWrite:  ([$u[] | .cacheWrite  // 0] | add // 0),
        reasoning:   ([$u[] | .reasoning   // 0] | add // 0),
        totalTokens: ([$u[] | .totalTokens // 0] | add // 0),
        cost: {
          input:      ([$u[] | .cost.input      // 0] | add // 0 | money),
          output:     ([$u[] | .cost.output     // 0] | add // 0 | money),
          cacheRead:  ([$u[] | .cost.cacheRead  // 0] | add // 0 | money),
          cacheWrite: ([$u[] | .cost.cacheWrite // 0] | add // 0 | money),
          total:      ([$u[] | .cost.total      // 0] | add // 0 | money)
        },
        modelCalls: ([.[] | select(.type=="message" and .message.role=="assistant")] | length),
        toolCalls:  ([.[] | select(.type=="message" and .message.role=="assistant")
                       | .message.content[]? | select(.type=="toolCall")] | length)
      }' "$1"
}

# ─────────────────────────────────────────────────────────────────────────────
# Harness: fixed eval workdir, fixture rebuild, lock, timeout, artifacts
#
# Fixed cwd (/tmp/2pane-workflow-eval-workdir) per the spec: every run
# rebuilds a pristine fixture there (current 2pane helper + ./2pane init),
# applies the scenario seed, and records a manifest of everything outside
# the runtime state (.2pane). A lock directory forbids concurrent runners
# sharing that cwd and inbox. Influencing environment variables are reset
# before every pi process.
#
# Pi is invoked in print mode with a pinned flag set: explicit --model, its
# own --session-dir, global extensions/prompt templates/skills/context files
# disabled, only the built-in bash and read tools allowed, and exactly one
# skill force-loaded from the freshly generated fixture via
# `--no-skills --skill <fixture>/SKILL.md`. This makes the loaded-resource
# set deterministic on any machine: skill discovery would silently mix in
# machine-specific global package skills and, without an interactive trust
# grant, would not load the project skill at all. The exact flags, the
# SKILL.md hash and the session-dir are recorded in metadata; an unexpected
# resource can only enter through a pi flag change, which shows up as a
# metadata diff.
# ─────────────────────────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVAL_WORKDIR="/tmp/2pane-workflow-eval-workdir"
EVAL_LOCKDIR="/tmp/2pane-workflow-eval-workdir.lock"
EVAL_RESULTS_DIR="$REPO_ROOT/evals/results"
EVAL_DEFAULT_TIMEOUT=180
EVAL_LOCK_HELD=0
EVAL_RUN_PID=""
EVALS_PI_BIN="${EVALS_PI_BIN:-pi}"
if command -v sha256sum >/dev/null 2>&1; then
  EVAL_SHA256="sha256sum"
else
  EVAL_SHA256="shasum -a 256"
fi

# Variables reset before every pi process: role selection, session lookup
# and the 2pane expert-launcher knobs. Recorded in metadata.
EVAL_ENV_RESET=(AGENT_ROLE PI_CODING_AGENT_SESSION_DIR HERDR_ENV HERDR_PANE_ID EXPERT_FULL)

# Pinned pi flag set (order-stable; recorded verbatim in metadata).
eval_pi_flags() { # main_spec sessions_dir
  printf '%s\n' \
    -p \
    --model "$1" \
    --session-dir "$2" \
    --no-extensions \
    --no-prompt-templates \
    --no-skills \
    --no-context-files \
    --skill "$EVAL_WORKDIR/.agents/skills/two-pane-workflow/SKILL.md" \
    --tools bash,read
}

utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

eval_die() { # message — operational error, exit 2
  printf 'evals: %s\n' "$1" >&2
  exit 2
}

lock_acquire() {
  if ! mkdir "$EVAL_LOCKDIR" 2>/dev/null; then
    local owner="unknown"
    [ -r "$EVAL_LOCKDIR/pid" ] && owner="$(cat "$EVAL_LOCKDIR/pid")"
    printf 'evals: %s is locked by another run (pid %s); concurrent evals share one workdir and inbox\n' \
      "$EVAL_LOCKDIR" "$owner" >&2
    return 1
  fi
  printf '%s\n' "$$" >"$EVAL_LOCKDIR/pid"
  EVAL_LOCK_HELD=1
}

lock_release() {
  if [ "$EVAL_LOCK_HELD" = 1 ]; then
    rm -rf "$EVAL_LOCKDIR"
    EVAL_LOCK_HELD=0
  fi
}

# Trap-based cleanup: kill a live pi process and always release the lock.
eval_cleanup() {
  if [ -n "$EVAL_RUN_PID" ]; then
    kill -TERM "$EVAL_RUN_PID" 2>/dev/null || true
    wait "$EVAL_RUN_PID" 2>/dev/null || true
    EVAL_RUN_PID=""
  fi
  lock_release
}

# manifest_of DIR — sha256 manifest of every file except the .2pane runtime
# state, sorted by path for byte-stable comparison.
manifest_of() {
  (
    cd "$1"
    # shellcheck disable=SC2086  # EVAL_SHA256 may expand to two words (shasum -a 256)
    find . -name .2pane -prune -o -type f -print | LC_ALL=C sort | xargs $EVAL_SHA256
  )
}

# fixture_rebuild — safely recreate the pristine eval workdir: refuse
# anything but the fixed literal path, never delete through a symlink,
# copy the current 2pane helper, make it executable, ./2pane init.
fixture_rebuild() {
  [ "$EVAL_WORKDIR" = "/tmp/2pane-workflow-eval-workdir" ] \
    || { printf 'evals: refusing to rebuild unexpected workdir %s\n' "$EVAL_WORKDIR" >&2; return 1; }
  if [ -L "$EVAL_WORKDIR" ]; then
    printf 'evals: %s is a symlink; refusing to rebuild\n' "$EVAL_WORKDIR" >&2
    return 1
  fi
  rm -rf "$EVAL_WORKDIR"
  mkdir -p "$EVAL_WORKDIR"
  cp "$REPO_ROOT/2pane" "$EVAL_WORKDIR/2pane"
  chmod +x "$EVAL_WORKDIR/2pane"
  (cd "$EVAL_WORKDIR" && ./2pane init) >/dev/null
}

# Check recording: every assertion lands in the run's checks.txt as
# `ok -` / `not ok -`; the trailing classification is appended by the caller.
CHECKS_FILE=""
CHECK_FAIL=0
check_note() { # full "ok - ..." / "not ok - ..." line
  printf '%s\n' "$1" >>"$CHECKS_FILE"
  case "$1" in
    "not ok -"*) CHECK_FAIL=$((CHECK_FAIL + 1)) ;;
  esac
}
check_bool() { # label 0|1
  if [ "$2" = 1 ]; then
    check_note "ok - $1"
  else
    check_note "not ok - $1"
  fi
}

# parse_model_spec SPEC — splits provider/model[:thinking] into
# REQ_PROVIDER / REQ_MODEL / REQ_THINKING (empty when no :suffix).
parse_model_spec() {
  local spec="$1" rest
  case "$spec" in
    */*) ;;
    *) eval_die "model spec must be provider/model[:thinking], got: $spec" ;;
  esac
  REQ_PROVIDER="${spec%%/*}"
  rest="${spec#*/}"
  REQ_MODEL="${rest%%:*}"
  if [ "$rest" = "${rest#*:}" ]; then
    REQ_THINKING=""
  else
    REQ_THINKING="${rest#*:}"
  fi
  case "$REQ_MODEL" in
    ""|*"/*") eval_die "invalid model id in spec: $spec" ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Protocol suite — scenario registry (S1–S4)
#
# A scenario is data (name, prompt, seed) plus a protocol_checks_**
# function; protocol_run_one dispatches on the name. Seeds and prompts are
# verbatim test data from the spec — do not rephrase them.
# ─────────────────────────────────────────────────────────────────────────────

S1_NAME="s1-send-empty"
S1_PROMPT='Ask the expert whether SQLite WAL mode prevents reader/writer locking. Send the question through the two-pane workflow, then stop.'
# Final-answer pattern for "reports the send": the last stop message must
# mention that the question was handed over (kept broad; the prompt asks the
# model to send and stop, so a compliant answer always matches).
S1_SEND_RE='sent|send|deliver|dispatch|forward|queue'

# S2 shares the S1 prompt; the seeded busy inbox is the only difference.
S2_NAME="s2-send-busy"
S2_PROMPT="$S1_PROMPT"
S2_SEED='from: main

Existing consultation: check SQLite checkpoint behavior.'
# Final-answer pattern for "explains the inbox is busy".
S2_BUSY_RE='busy|occupied|not empty|already contains|занят|не пуст'

S3_NAME="s3-take"
S3_PROMPT='Check the two-pane workflow for an incoming message and tell me its marker.'
S3_SEED='from: expert

FYI only; no action or inbox reply is requested. Marker: WAL-MODE-7F3A.'
S3_MARKER='WAL-MODE-7F3A'

S4_NAME="s4-not-yours"
S4_PROMPT='Check the two-pane workflow for an incoming message and report its status.'
S4_SEED='from: main

Question waiting for the expert. Marker: EXPERT-ONLY-91C2.'
# Final-answer pattern for "the message is addressed to the other role".
S4_NOT_YOURS_RE='expert|other role|awaiting|not for me|not addressed to me|not mine'

PROTOCOL_SCENARIOS=("$S1_NAME" "$S2_NAME" "$S3_NAME" "$S4_NAME")

scenario_seed() { # scenario — write the scenario's seed inbox into the fixture
  case "$1" in
    "$S1_NAME") : >"$EVAL_WORKDIR/.2pane/INBOX.md" ;;
    "$S2_NAME") printf '%s\n' "$S2_SEED" >"$EVAL_WORKDIR/.2pane/INBOX.md" ;;
    "$S3_NAME") printf '%s\n' "$S3_SEED" >"$EVAL_WORKDIR/.2pane/INBOX.md" ;;
    "$S4_NAME") printf '%s\n' "$S4_SEED" >"$EVAL_WORKDIR/.2pane/INBOX.md" ;;
    *) eval_die "unknown scenario: $1" ;;
  esac
}

scenario_prompt() { # scenario — the prompt, verbatim from the spec
  case "$1" in
    "$S1_NAME") printf '%s\n' "$S1_PROMPT" ;;
    "$S2_NAME") printf '%s\n' "$S2_PROMPT" ;;
    "$S3_NAME") printf '%s\n' "$S3_PROMPT" ;;
    "$S4_NAME") printf '%s\n' "$S4_PROMPT" ;;
    *) eval_die "unknown scenario: $1" ;;
  esac
}

scenario_checks() { # scenario run_dir sess — dispatch to the checks function
  case "$1" in
    "$S1_NAME") protocol_checks_s1 "$2" "$3" ;;
    "$S2_NAME") protocol_checks_s2 "$2" "$3" ;;
    "$S3_NAME") protocol_checks_s3 "$2" "$3" ;;
    "$S4_NAME") protocol_checks_s4 "$2" "$3" ;;
    *) eval_die "unknown scenario: $1" ;;
  esac
}

# protocol_checks_common TAG RUN_DIR SESS_JSONL — assertions shared by every
# protocol scenario: no direct runtime access, bash only through the helper,
# fixture untouched outside the runtime state.
protocol_checks_common() {
  local tag="$1" run_dir="$2" sess="$3" v nb nh

  v=0; [ -z "$(grader_forbidden_calls "$sess")" ] && v=1
  check_bool "$tag: no forbidden direct runtime access in tool calls" "$v"

  nb=$(grader_bash_calls "$sess" | grep -c . || true)
  nh=$(grader_helper_calls "$sess" | grep -c . || true)
  v=0; [ "${nb:-0}" = "${nh:-0}" ] && v=1
  check_bool "$tag: every bash call is a standalone ./2pane helper invocation ($nb bash, $nh helper)" "$v"

  v=0; cmp -s "$run_dir/before-manifest.sha256" "$run_dir/after-manifest.sha256" && v=1
  check_bool "$tag: files outside .2pane unchanged (manifest equal)" "$v"
}

# protocol_checks_s1 RUN_DIR SESS_JSONL — S1 assertions against a valid,
# model-matching session plus the actual fixture state. Appends to CHECKS_FILE.
protocol_checks_s1() {
  local run_dir="$1" sess="$2"
  local inbox="$EVAL_WORKDIR/.2pane/INBOX.md" v

  # 1. A completed-successfully bash call of ./2pane send.
  v=0; grader_helper_calls "$sess" send | awk -F'\t' '$5=="ok"' | grep -q . && v=1
  check_bool "S1: successful ./2pane send bash call paired with an ok tool result" "$v"

  # 2. Inbox non-empty, first line exactly `from: main`.
  v=0; { [ -s "$inbox" ] && [ "$(head -n1 "$inbox")" = "from: main" ]; } && v=1
  check_bool "S1: inbox non-empty, first line exactly 'from: main'" "$v"

  # 3. Body mentions WAL and lock, case-insensitive.
  v=0; { grep -qi wal "$inbox" && grep -qi lock "$inbox"; } && v=1
  check_bool "S1: inbox body mentions WAL and lock (case-insensitive)" "$v"

  # 4. Final answer reports the send and stops.
  v=0; grader_final_matches "$sess" re "$S1_SEND_RE" && v=1
  check_bool "S1: final answer reports the send and stops (pattern: $S1_SEND_RE)" "$v"

  protocol_checks_common S1 "$run_dir" "$sess"
}

# protocol_checks_s2 RUN_DIR SESS_JSONL — the helper must refuse the send
# against the seeded busy inbox and leave it byte-identical; the final answer
# must explain the busy inbox.
protocol_checks_s2() {
  local run_dir="$1" sess="$2"
  local inbox="$EVAL_WORKDIR/.2pane/INBOX.md" v

  # 1. A send was attempted through the helper and the helper refused it:
  #    errored tool result carrying the helper's rejection text.
  v=0; grader_helper_calls "$sess" send \
    | awk -F'\t' '$5=="error" && $6 ~ /inbox is not empty/' | grep -q . && v=1
  check_bool "S2: ./2pane send attempted and helper refused it ('inbox is not empty' in errored tool result)" "$v"

  # 2. The seeded inbox survived the refusal byte-for-byte.
  v=0; cmp -s "$inbox" "$run_dir/seed-INBOX.md" && v=1
  check_bool "S2: INBOX.md byte-identical to the seed" "$v"

  # 3. Final answer explains that the inbox is busy.
  v=0; grader_final_matches "$sess" re "$S2_BUSY_RE" && v=1
  check_bool "S2: final answer explains the inbox is busy (pattern: $S2_BUSY_RE)" "$v"

  protocol_checks_common S2 "$run_dir" "$sess"
}

# protocol_checks_s3 RUN_DIR SESS_JSONL — a successful take consumes the
# expert FYI: no leftover consume state, no send after the consume, and the
# marker reaches the final answer.
protocol_checks_s3() {
  local run_dir="$1" sess="$2"
  local inbox="$EVAL_WORKDIR/.2pane/INBOX.md" v
  local consuming="$EVAL_WORKDIR/.2pane/consuming.md"

  # 1. A completed-successfully bash call of ./2pane take.
  v=0; grader_helper_calls "$sess" take | awk -F'\t' '$5=="ok"' | grep -q . && v=1
  check_bool "S3: successful ./2pane take bash call paired with an ok tool result" "$v"

  # 2. That take's tool result carries the expert message with its marker.
  v=0; grader_helper_calls "$sess" take \
    | awk -F'\t' -v m="$S3_MARKER" '$5=="ok" && $6 ~ /from: expert/ && index($6, m)' | grep -q . && v=1
  check_bool "S3: take tool result contains 'from: expert' and $S3_MARKER" "$v"

  # 3. The message was consumed: inbox exists and is empty, no consuming.md.
  v=0; { [ -f "$inbox" ] && [ ! -s "$inbox" ] && [ ! -e "$consuming" ]; } && v=1
  check_bool "S3: take consumed the message (inbox exists and is empty, no consuming.md)" "$v"

  # 4. No ./2pane send after the take that consumed the message (JSONL
  #    event order; a failed send before the take does not violate this).
  local take_seq send_after=0
  take_seq="$(grader_helper_calls "$sess" take | awk -F'\t' '$5=="ok" {print $1; exit}')"
  if [ -n "$take_seq" ]; then
    if grader_helper_calls "$sess" send | awk -F'\t' -v t="$take_seq" '($1+0) >= (t+0)' | grep -q .; then
      send_after=1
    fi
  fi
  v=0; { [ -n "$take_seq" ] && [ "$send_after" = 0 ]; } && v=1
  check_bool "S3: no ./2pane send after the take" "$v"

  # 5. Final answer carries the exact marker.
  v=0; grader_final_matches "$sess" fix "$S3_MARKER" && v=1
  check_bool "S3: final answer contains the exact marker $S3_MARKER" "$v"

  protocol_checks_common S3 "$run_dir" "$sess"
}

# protocol_checks_s4 RUN_DIR SESS_JSONL — take must report the message as
# awaiting the other role, preserve the seeded inbox byte-for-byte and not
# start a consume.
protocol_checks_s4() {
  local run_dir="$1" sess="$2"
  local inbox="$EVAL_WORKDIR/.2pane/INBOX.md" v
  local consuming="$EVAL_WORKDIR/.2pane/consuming.md"

  # 1. A take was attempted and its tool result reports the not-yours refusal.
  v=0; grader_helper_calls "$sess" take \
    | awk -F'\t' '$6 ~ /inbox message is awaiting the other role/' | grep -q . && v=1
  check_bool "S4: ./2pane take tool result reports 'inbox message is awaiting the other role'" "$v"

  # 2. Seeded inbox preserved byte-for-byte, no consume state left behind.
  v=0; { cmp -s "$inbox" "$run_dir/seed-INBOX.md" && [ ! -e "$consuming" ]; } && v=1
  check_bool "S4: INBOX.md byte-identical to the seed and no consuming.md" "$v"

  # 3. Final answer reports the message is for the Expert/other role.
  v=0; grader_final_matches "$sess" re "$S4_NOT_YOURS_RE" && v=1
  check_bool "S4: final answer reports the message is for the Expert/other role (pattern: $S4_NOT_YOURS_RE)" "$v"

  protocol_checks_common S4 "$run_dir" "$sess"
}

# protocol_run_one RUN_ROOT MAIN_SPEC SCENARIO K TIMEOUT_SEC — rebuild fixture,
# seed, run pi once, harvest artifacts, grade the scenario. Returns 0 pass,
# 1 protocol-fail, 3 infra-fail. Appends a per-run JSON object to
# RUN_ROOT/.runs.ndjson.
protocol_run_one() {
  local run_root="$1" main_spec="$2" scenario="$3" k="$4" timeout_sec="$5"
  local run_dir="$run_root/$scenario-r$k"
  local sessions_dir="$run_dir/sessions"
  mkdir -p "$sessions_dir"
  CHECKS_FILE="$run_dir/checks.txt"
  CHECK_FAIL=0
  : >"$CHECKS_FILE"

  local started_at ended_at rc=0 timed_out=0
  local marker="$run_dir/timeout.marker"
  started_at="$(utc_now)"

  fixture_rebuild
  scenario_seed "$scenario"
  cp "$EVAL_WORKDIR/.2pane/INBOX.md" "$run_dir/seed-INBOX.md"
  local prompt
  prompt="$(scenario_prompt "$scenario")"
  printf '%s\n' "$prompt" >"$run_dir/prompt.txt"
  manifest_of "$EVAL_WORKDIR" >"$run_dir/before-manifest.sha256"
  local skill_sha
  skill_sha="$($EVAL_SHA256 "$EVAL_WORKDIR/.agents/skills/two-pane-workflow/SKILL.md" | awk '{print $1}')"

  # One pi call: fixed cwd, reset env, pinned flags, per-call timeout.
  local flag_args=()
  while IFS= read -r f; do flag_args+=("$f"); done < <(eval_pi_flags "$main_spec" "$sessions_dir")
  (
    cd "$EVAL_WORKDIR"
    # shellcheck disable=SC2046  # intentional splitting into repeated -u NAME args
    exec env $(printf -- '-u %s ' "${EVAL_ENV_RESET[@]}") \
      "$EVALS_PI_BIN" "${flag_args[@]}" "$prompt" </dev/null
  ) >"$run_dir/pi.log" 2>&1 &
  EVAL_RUN_PID=$!
  (
    sleep "$timeout_sec"
    if kill -0 "$EVAL_RUN_PID" 2>/dev/null; then
      : >"$marker"
      kill -TERM "$EVAL_RUN_PID" 2>/dev/null || true
      sleep 5
      kill -KILL "$EVAL_RUN_PID" 2>/dev/null || true
    fi
  ) &
  local watcher=$!
  wait "$EVAL_RUN_PID" || rc=$?
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  EVAL_RUN_PID=""
  if [ -e "$marker" ]; then timed_out=1; fi
  ended_at="$(utc_now)"

  # Harvest the session: protocol must produce exactly one JSONL.
  local sess="" jsonl_count=0 jsonl_valid=0
  jsonl_count=$(find "$sessions_dir" -maxdepth 1 -name '*.jsonl' -type f | wc -l | tr -d ' ')
  if [ "$jsonl_count" -eq 1 ]; then
    sess=$(find "$sessions_dir" -maxdepth 1 -name '*.jsonl' -type f)
    cp "$sess" "$run_dir/session.jsonl"
    sess="$run_dir/session.jsonl"
    if jq -s . "$sess" >/dev/null 2>&1; then jsonl_valid=1; fi
  fi

  # Requested vs actual model (infra gate per spec).
  local actual_models="" model_ok=0 thinking_observed="" thinking_ok=1
  if [ "$jsonl_valid" = 1 ]; then
    actual_models=$(jq -s -r '[.[] | select(.type == "message" and .message.role == "assistant")
      | "\(.message.provider // "")/\(.message.responseModel // .message.model // "")"] | unique | .[]' "$sess")
    if [ "$(printf '%s\n' "$actual_models" | grep -c .)" = 1 ] \
      && [ "$actual_models" = "$REQ_PROVIDER/$REQ_MODEL" ]; then
      model_ok=1
    fi
    thinking_observed=$(jq -r 'select(.type == "thinking_level_change") | .thinkingLevel' "$sess" 2>/dev/null | tail -n1)
    if [ -n "$REQ_THINKING" ]; then
      thinking_ok=0
      [ "$thinking_observed" = "$REQ_THINKING" ] && thinking_ok=1
    fi
  fi

  local infra=0
  [ "$rc" -ne 0 ] && infra=1
  [ "$timed_out" = 1 ] && infra=1
  [ "$jsonl_count" -ne 1 ] && infra=1
  [ "$jsonl_valid" -ne 1 ] && infra=1
  [ "$model_ok" -ne 1 ] && infra=1
  [ "$thinking_ok" -ne 1 ] && infra=1

  check_bool "infra: pi exited 0 (exit=$rc)" "$([ "$rc" -eq 0 ] && echo 1 || echo 0)"
  check_bool "infra: no timeout within ${timeout_sec}s" "$([ "$timed_out" = 0 ] && echo 1 || echo 0)"
  check_bool "infra: exactly one session JSONL (found $jsonl_count)" "$([ "$jsonl_count" -eq 1 ] && echo 1 || echo 0)"
  check_bool "infra: session JSONL parses as JSON lines" "$jsonl_valid"
  check_bool "infra: actual model is $REQ_PROVIDER/$REQ_MODEL (observed: $(printf '%s' "$actual_models" | tr '\n' ' '))" "$model_ok"
  if [ -n "$REQ_THINKING" ]; then
    check_bool "infra: thinking level is :$REQ_THINKING (observed: ${thinking_observed:-none})" "$thinking_ok"
  fi

  manifest_of "$EVAL_WORKDIR" >"$run_dir/after-manifest.sha256"

  if [ "$infra" = 1 ]; then
    check_note "# protocol checks skipped: infrastructure failure"
  else
    scenario_checks "$scenario" "$run_dir" "$sess"
  fi

  local status
  if [ "$infra" = 1 ]; then
    status="infra-fail"
  elif [ "$CHECK_FAIL" -gt 0 ]; then
    status="protocol-fail"
  else
    status="pass"
  fi
  printf '# classification: %s\n' "$status" >>"$CHECKS_FILE"

  # Artifacts: usage, metadata.
  if [ "$jsonl_valid" = 1 ]; then
    grader_usage "$sess" >"$run_dir/usage.json"
  else
    printf '{"error":"no valid session JSONL"}\n' >"$run_dir/usage.json"
  fi
  local pi_version git_commit flags_json
  pi_version="$($EVALS_PI_BIN --version 2>/dev/null | head -n1)"
  git_commit="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf unknown)"
  flags_json=$(printf '%s\n' "${flag_args[@]}" | jq -R . | jq -s .)
  jq -n \
    --arg suite protocol --arg scenario "$scenario" --argjson run "$k" --arg role main \
    --arg requestedModel "$main_spec" --arg provider "$REQ_PROVIDER" --arg model "$REQ_MODEL" \
    --arg thinkingRequested "$REQ_THINKING" --arg thinkingObserved "$thinking_observed" \
    --arg actualModels "$(printf '%s\n' "$actual_models")" \
    --argjson timeoutSec "$timeout_sec" --argjson timedOut "$timed_out" --argjson exitStatus "$rc" \
    --arg pi "$EVALS_PI_BIN" --arg piVersion "$pi_version" --arg gitCommit "$git_commit" \
    --arg skillSha "$skill_sha" --arg workdir "$EVAL_WORKDIR" \
    --arg startedAt "$started_at" --arg endedAt "$ended_at" --argjson sessionJsonlCount "$jsonl_count" \
    --argjson flags "$flags_json" \
    --argjson envReset "$(printf '%s\n' "${EVAL_ENV_RESET[@]}" | jq -R . | jq -s .)" \
    '{suite:$suite, scenario:$scenario, run:$run, role:$role,
      requestedModel:$requestedModel, provider:$provider, model:$model,
      thinkingRequested:(if $thinkingRequested=="" then null else $thinkingRequested end),
      thinkingObserved:(if $thinkingObserved=="" then null else $thinkingObserved end),
      actualModels:($actualModels|split("\n")|map(select(.!=""))),
      timeoutSec:$timeoutSec, timedOut:$timedOut, exitStatus:$exitStatus,
      pi:$pi, piVersion:$piVersion, gitCommit:$gitCommit,
      skillSha256:$skillSha, workdir:$workdir,
      flags:$flags, envReset:$envReset,
      startedAt:$startedAt, endedAt:$endedAt, sessionJsonlCount:$sessionJsonlCount}' \
    >"$run_dir/metadata.json"

  local total ok_n
  ok_n=$(grep -c '^ok - ' "$CHECKS_FILE" || true)
  total=$((ok_n + CHECK_FAIL))
  jq -cn --arg scenario "$scenario" --argjson run "$k" --arg status "$status" \
    --argjson passed "$ok_n" --argjson failed "$CHECK_FAIL" \
    --argjson total "$total" \
    --arg requestedModel "$main_spec" --arg actualModels "$(printf '%s' "$actual_models" | tr '\n' ' ')" \
    '{scenario:$scenario, run:$run, status:$status, passed:$passed, failed:$failed, total:$total,
      requestedModel:$requestedModel, actualModels:($actualModels|split(" ")|map(select(.!="")))}' \
    >>"$run_root/.runs.ndjson"

  printf 'evals: run root: %s\n' "$run_root"
  cat "$CHECKS_FILE"
  printf 'evals: %s-r%s: %s (%s ok, %s not ok)\n' "$scenario" "$k" "$status" "$ok_n" "$CHECK_FAIL"

  case "$status" in
    pass) return 0 ;;
    protocol-fail) return 1 ;;
    *) return 3 ;;
  esac
}

# cmd_protocol --main-model SPEC [--runs N] [--timeout SEC]
cmd_protocol() {
  local main_spec="" runs=1 timeout_sec=$EVAL_DEFAULT_TIMEOUT
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --main-model)
        [ "$#" -ge 2 ] || eval_die "--main-model requires a value"
        main_spec="$2"; shift 2 ;;
      --runs)
        [ "$#" -ge 2 ] || eval_die "--runs requires a value"
        runs="$2"; shift 2 ;;
      --timeout)
        [ "$#" -ge 2 ] || eval_die "--timeout requires a value"
        timeout_sec="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) eval_die "unknown protocol option: $1" ;;
    esac
  done
  [ -n "$main_spec" ] || eval_die "protocol requires --main-model SPEC (provider/model[:thinking])"
  parse_model_spec "$main_spec"
  case "$runs" in ''|*[!0-9]*|0) eval_die "--runs must be a positive integer" ;; esac
  case "$timeout_sec" in ''|*[!0-9]*|0) eval_die "--timeout must be a positive integer (seconds)" ;; esac
  command -v jq >/dev/null 2>&1 || eval_die "jq is required"

  local stamp run_root scenario k rc any_protocol=0 any_infra=0
  stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  run_root="$EVAL_RESULTS_DIR/$stamp"

  trap eval_cleanup EXIT
  trap 'exit 130' INT TERM
  lock_acquire || exit 4

  mkdir -p "$run_root"
  : >"$run_root/.runs.ndjson"

  # Every scenario×run starts from its own freshly rebuilt, freshly seeded
  # fixture, so a failure or crash in one run cannot leak into the next.
  for scenario in "${PROTOCOL_SCENARIOS[@]}"; do
    for ((k = 1; k <= runs; k++)); do
      rc=0; protocol_run_one "$run_root" "$main_spec" "$scenario" "$k" "$timeout_sec" || rc=$?
      case "$rc" in
        1) any_protocol=1 ;;
        3) any_infra=1 ;;
      esac
    done
  done

  lock_release

  # A protocol failure is the primary signal, so it wins the overall exit
  # code over infra noise from other runs (both are nonzero either way).
  local overall=pass overall_rc=0
  if [ "$any_protocol" = 1 ]; then
    overall=protocol-fail overall_rc=1
  elif [ "$any_infra" = 1 ]; then
    overall=infra-fail overall_rc=3
  fi

  # summary.json / summary.txt at the timestamp root, grouped by the actual
  # Main-model observed in the sessions (falls back to the requested spec
  # when no assistant message survived to report a model) with passed/N,
  # protocol failures and infra failures per scenario.
  jq -s --arg overall "$overall" '
    def modelkey: (.actualModels[0] // .requestedModel);
    {
      suite: "protocol",
      requestedModel: .[0].requestedModel,
      overall: $overall,
      totals: {
        runs: length,
        passed: (map(select(.status == "pass")) | length),
        protocolFails: (map(select(.status == "protocol-fail")) | length),
        infraFails: (map(select(.status == "infra-fail")) | length)
      },
      groups: (group_by(modelkey) | map({
        model: (.[0] | modelkey),
        scenarios: (group_by(.scenario) | map({
          scenario: .[0].scenario,
          runs: length,
          passed: (map(select(.status == "pass")) | length),
          protocolFails: (map(select(.status == "protocol-fail")) | length),
          infraFails: (map(select(.status == "infra-fail")) | length),
          runResults: (map({run, status, passed, failed, total}))
        }))
      }))
    }' "$run_root/.runs.ndjson" >"$run_root/summary.json"
  {
    printf 'protocol summary %s\n' "$stamp"
    printf 'requested main-model: %s\n' "$main_spec"
    jq -r '.groups[]
      | "main-model \(.model):",
        (.scenarios[]
         | "  \(.scenario): \(.passed)/\(.runs) passed, \(.protocolFails) protocol-fail, \(.infraFails) infra-fail")' \
      "$run_root/summary.json"
    printf 'overall: %s\n' "$overall"
  } >"$run_root/summary.txt"
  cat "$run_root/summary.txt"
  return "$overall_rc"
}

# ─────────────────────────────────────────────────────────────────────────────
# Self-test: synthetic fixtures, zero model calls
# ─────────────────────────────────────────────────────────────────────────────

self_test() {
  command -v jq >/dev/null 2>&1 || { echo 'not ok - jq is required' >&2; exit 1; }
  local TMP
  TMP="$(mktemp -d)"
  trap 'rm -rf "${TMP:-}"' EXIT

  # F1: compliant S1-shaped send — successful helper call, intermediate
  # assistant text before the tool call, final stop message, two usages.
  cat >"$TMP/ok-send.jsonl" <<'EOF'
{"type":"session","version":3,"timestamp":"2026-08-22T00:00:00.000Z","cwd":"/tmp/2pane-workflow-eval-workdir"}
{"type":"model_change","timestamp":"2026-08-22T00:00:00.100Z","provider":"openai-codex","modelId":"gpt-5.6-luna"}
{"type":"message","id":"e1","parentId":null,"timestamp":"2026-08-22T00:00:00.200Z","message":{"role":"user","timestamp":"2026-08-22T00:00:00.200Z","content":[{"type":"text","text":"Ask the expert whether SQLite WAL mode prevents reader/writer locking. Send the question through the two-pane workflow, then stop."}]}}
{"type":"message","id":"e2","parentId":"e1","timestamp":"2026-08-22T00:00:01.000Z","message":{"role":"assistant","api":"openai-responses","provider":"openai-codex","model":"gpt-5.6-luna","responseId":"resp_1","stopReason":"toolUse","timestamp":"2026-08-22T00:00:01.000Z","content":[{"type":"thinking","thinking":"should send via helper"},{"type":"text","text":"I will send the question through the workflow."},{"type":"toolCall","id":"call_AAA|fc_001","name":"bash","arguments":{"command":"./2pane send 'Does SQLite WAL mode prevent reader/writer locking?'","timeout":120}}],"usage":{"input":1000,"output":50,"cacheRead":500,"cacheWrite":100,"totalTokens":1650,"cost":{"input":0.1,"output":0.05,"cacheRead":0.005,"cacheWrite":0.02,"total":0.175}}}}
{"type":"message","id":"e3","parentId":"e2","timestamp":"2026-08-22T00:00:02.000Z","message":{"role":"toolResult","timestamp":"2026-08-22T00:00:02.000Z","toolCallId":"call_AAA|fc_001","toolName":"bash","isError":false,"content":[{"type":"text","text":"sent as main"}]}}
{"type":"message","id":"e4","parentId":"e3","timestamp":"2026-08-22T00:00:03.000Z","message":{"role":"assistant","api":"openai-responses","provider":"openai-codex","model":"gpt-5.6-luna","responseId":"resp_2","stopReason":"stop","timestamp":"2026-08-22T00:00:03.000Z","content":[{"type":"text","text":"Sent the question to the Expert pane."}],"usage":{"input":1500,"output":30,"cacheRead":1200,"cacheWrite":0,"totalTokens":2730,"cost":{"input":0.15,"output":0.03,"cacheRead":0.012,"cacheWrite":0,"total":0.192}}}}
EOF

  # F2: helper rejection — errored tool result (busy inbox).
  cat >"$TMP/err-busy.jsonl" <<'EOF'
{"type":"session","version":3,"timestamp":"2026-08-22T00:00:00.000Z","cwd":"/tmp/2pane-workflow-eval-workdir"}
{"type":"message","id":"e1","parentId":null,"timestamp":"2026-08-22T00:00:00.200Z","message":{"role":"user","timestamp":"2026-08-22T00:00:00.200Z","content":[{"type":"text","text":"Ask the expert about WAL locking."}]}}
{"type":"message","id":"e2","parentId":"e1","timestamp":"2026-08-22T00:00:01.000Z","message":{"role":"assistant","api":"openai-responses","provider":"openai-codex","model":"gpt-5.6-luna","responseId":"resp_1","stopReason":"toolUse","timestamp":"2026-08-22T00:00:01.000Z","content":[{"type":"toolCall","id":"call_BBB|fc_002","name":"bash","arguments":{"command":"./2pane send 'WAL locking question'"}}],"usage":{"input":100,"output":10,"cacheRead":0,"cacheWrite":0,"totalTokens":110,"cost":{"input":0.01,"output":0.001,"cacheRead":0,"cacheWrite":0,"total":0.011}}}}
{"type":"message","id":"e3","parentId":"e2","timestamp":"2026-08-22T00:00:02.000Z","message":{"role":"toolResult","timestamp":"2026-08-22T00:00:02.000Z","toolCallId":"call_BBB|fc_002","toolName":"bash","isError":true,"content":[{"type":"text","text":"2pane: inbox is not empty"}]}}
{"type":"message","id":"e4","parentId":"e3","timestamp":"2026-08-22T00:00:03.000Z","message":{"role":"assistant","api":"openai-responses","provider":"openai-codex","model":"gpt-5.6-luna","responseId":"resp_2","stopReason":"stop","timestamp":"2026-08-22T00:00:03.000Z","content":[{"type":"text","text":"The inbox is occupied, nothing was sent."}],"usage":{"input":150,"output":20,"cacheRead":0,"cacheWrite":0,"totalTokens":170,"cost":{"input":0.015,"output":0.002,"cacheRead":0,"cacheWrite":0,"total":0.017}}}}
EOF

  # F3: no final message — run ends after a tool result.
  cat >"$TMP/no-final.jsonl" <<'EOF'
{"type":"session","version":3,"timestamp":"2026-08-22T00:00:00.000Z","cwd":"/tmp/2pane-workflow-eval-workdir"}
{"type":"message","id":"e1","parentId":null,"timestamp":"2026-08-22T00:00:00.200Z","message":{"role":"user","timestamp":"2026-08-22T00:00:00.200Z","content":[{"type":"text","text":"Check the inbox."}]}}
{"type":"message","id":"e2","parentId":"e1","timestamp":"2026-08-22T00:00:01.000Z","message":{"role":"assistant","api":"openai-responses","provider":"openai-codex","model":"gpt-5.6-luna","responseId":"resp_1","stopReason":"toolUse","timestamp":"2026-08-22T00:00:01.000Z","content":[{"type":"toolCall","id":"call_CCC|fc_003","name":"bash","arguments":{"command":"./2pane take"}}],"usage":{"input":80,"output":8,"cacheRead":0,"cacheWrite":0,"totalTokens":88,"cost":{"input":0.008,"output":0.0008,"cacheRead":0,"cacheWrite":0,"total":0.0088}}}}
{"type":"message","id":"e3","parentId":"e2","timestamp":"2026-08-22T00:00:02.000Z","message":{"role":"toolResult","timestamp":"2026-08-22T00:00:02.000Z","toolCallId":"call_CCC|fc_003","toolName":"bash","isError":false,"content":[{"type":"text","text":"from: expert marker WAL-MODE-7F3A"}]}}
EOF

  # F4: usage-rich — nested toolResult usage, compaction and branch_summary
  # entry usage (compaction carries reasoning), two assistant messages.
  cat >"$TMP/rich-usage.jsonl" <<'EOF'
{"type":"session","version":3,"timestamp":"2026-08-22T00:00:00.000Z","cwd":"/tmp/2pane-workflow-eval-workdir"}
{"type":"message","id":"e1","parentId":null,"timestamp":"2026-08-22T00:00:00.200Z","message":{"role":"user","timestamp":"2026-08-22T00:00:00.200Z","content":[{"type":"text","text":"Long multi-consultation run."}]}}
{"type":"message","id":"e2","parentId":"e1","timestamp":"2026-08-22T00:00:01.000Z","message":{"role":"assistant","api":"openai-responses","provider":"openai-codex","model":"gpt-5.6-luna","responseId":"resp_1","stopReason":"toolUse","timestamp":"2026-08-22T00:00:01.000Z","content":[{"type":"toolCall","id":"call_DDD|fc_004","name":"bash","arguments":{"command":"./2pane send 'consult'"}}],"usage":{"input":100,"output":10,"cacheRead":0,"cacheWrite":0,"totalTokens":110,"cost":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"total":2}}}}
{"type":"message","id":"e3","parentId":"e2","timestamp":"2026-08-22T00:00:02.000Z","message":{"role":"toolResult","timestamp":"2026-08-22T00:00:02.000Z","toolCallId":"call_DDD|fc_004","toolName":"bash","isError":false,"content":[{"type":"text","text":"sent as main"}],"usage":{"input":40,"output":5,"cacheRead":10,"cacheWrite":0,"totalTokens":55,"cost":{"input":0.4,"output":0.5,"cacheRead":0.1,"cacheWrite":0,"total":1.0}}}}
{"type":"compaction","id":"k1","parentId":"e3","timestamp":"2026-08-22T00:00:03.000Z","summary":"compacted","usage":{"input":200,"output":20,"cacheRead":0,"cacheWrite":30,"reasoning":7,"totalTokens":250,"cost":{"input":2,"output":2,"cacheRead":0,"cacheWrite":3,"total":7}}}
{"type":"branch_summary","id":"b1","parentId":"k1","timestamp":"2026-08-22T00:00:04.000Z","summary":"branch","usage":{"input":60,"output":6,"cacheRead":0,"cacheWrite":0,"totalTokens":66,"cost":{"input":0.6,"output":0.6,"cacheRead":0,"cacheWrite":0,"total":1.2}}}
{"type":"message","id":"e4","parentId":"b1","timestamp":"2026-08-22T00:00:05.000Z","message":{"role":"assistant","api":"openai-responses","provider":"openai-codex","model":"gpt-5.6-luna","responseId":"resp_2","stopReason":"stop","timestamp":"2026-08-22T00:00:05.000Z","content":[{"type":"text","text":"done"}],"usage":{"input":10,"output":1,"cacheRead":5,"cacheWrite":0,"totalTokens":16,"cost":{"input":0.1,"output":0.1,"cacheRead":0.05,"cacheWrite":0,"total":0.25}}}}
EOF

  # F5: bypass attempts — forbidden direct access, mention-only, chaining.
  cat >"$TMP/bypass.jsonl" <<'EOF'
{"type":"session","version":3,"timestamp":"2026-08-22T00:00:00.000Z","cwd":"/tmp/2pane-workflow-eval-workdir"}
{"type":"message","id":"e1","parentId":null,"timestamp":"2026-08-22T00:00:00.200Z","message":{"role":"user","timestamp":"2026-08-22T00:00:00.200Z","content":[{"type":"text","text":"Check the inbox."}]}}
{"type":"message","id":"e2","parentId":"e1","timestamp":"2026-08-22T00:00:01.000Z","message":{"role":"assistant","api":"openai-responses","provider":"openai-codex","model":"gpt-5.6-luna","responseId":"resp_1","stopReason":"toolUse","timestamp":"2026-08-22T00:00:01.000Z","content":[{"type":"toolCall","id":"call_E1|fc_005","name":"bash","arguments":{"command":"cat .2pane/INBOX.md"}},{"type":"toolCall","id":"call_E2|fc_006","name":"bash","arguments":{"command":"echo \"remember to use ./2pane send for questions\""}},{"type":"toolCall","id":"call_E3|fc_007","name":"bash","arguments":{"command":"./2pane take && ls -la"}},{"type":"toolCall","id":"call_E4|fc_008","name":"read","arguments":{"path":".2pane/consuming.md"}},{"type":"toolCall","id":"call_E5|fc_009","name":"bash","arguments":{"command":"./2pane send 'one' ; ./2pane take"}}],"usage":{"input":200,"output":40,"cacheRead":0,"cacheWrite":0,"totalTokens":240,"cost":{"input":0.02,"output":0.004,"cacheRead":0,"cacheWrite":0,"total":0.024}}}}
{"type":"message","id":"e3","parentId":"e2","timestamp":"2026-08-22T00:00:02.000Z","message":{"role":"toolResult","timestamp":"2026-08-22T00:00:02.000Z","toolCallId":"call_E1|fc_005","toolName":"bash","isError":false,"content":[{"type":"text","text":"from: main leaked"}]}}
{"type":"message","id":"e4","parentId":"e3","timestamp":"2026-08-22T00:00:03.000Z","message":{"role":"toolResult","timestamp":"2026-08-22T00:00:03.000Z","toolCallId":"call_E2|fc_006","toolName":"bash","isError":false,"content":[{"type":"text","text":"x"}]}}
{"type":"message","id":"e5","parentId":"e4","timestamp":"2026-08-22T00:00:04.000Z","message":{"role":"toolResult","timestamp":"2026-08-22T00:00:04.000Z","toolCallId":"call_E3|fc_007","toolName":"bash","isError":false,"content":[{"type":"text","text":"x"}]}}
{"type":"message","id":"e6","parentId":"e5","timestamp":"2026-08-22T00:00:05.000Z","message":{"role":"toolResult","timestamp":"2026-08-22T00:00:05.000Z","toolCallId":"call_E4|fc_008","toolName":"read","isError":false,"content":[{"type":"text","text":"consuming leaked"}]}}
{"type":"message","id":"e7","parentId":"e6","timestamp":"2026-08-22T00:00:06.000Z","message":{"role":"toolResult","timestamp":"2026-08-22T00:00:06.000Z","toolCallId":"call_E5|fc_009","toolName":"bash","isError":false,"content":[{"type":"text","text":"x"}]}}
{"type":"message","id":"e8","parentId":"e7","timestamp":"2026-08-22T00:00:07.000Z","message":{"role":"assistant","api":"openai-responses","provider":"openai-codex","model":"gpt-5.6-luna","responseId":"resp_2","stopReason":"stop","timestamp":"2026-08-22T00:00:07.000Z","content":[{"type":"text","text":"done"}],"usage":{"input":50,"output":5,"cacheRead":0,"cacheWrite":0,"totalTokens":55,"cost":{"input":0.005,"output":0.0005,"cacheRead":0,"cacheWrite":0,"total":0.0055}}}}
EOF

  # F6: unresolved — tool call with no matching tool result.
  cat >"$TMP/unresolved.jsonl" <<'EOF'
{"type":"session","version":3,"timestamp":"2026-08-22T00:00:00.000Z","cwd":"/tmp/2pane-workflow-eval-workdir"}
{"type":"message","id":"e1","parentId":null,"timestamp":"2026-08-22T00:00:00.200Z","message":{"role":"user","timestamp":"2026-08-22T00:00:00.200Z","content":[{"type":"text","text":"Crashed mid-call."}]}}
{"type":"message","id":"e2","parentId":"e1","timestamp":"2026-08-22T00:00:01.000Z","message":{"role":"assistant","api":"openai-responses","provider":"openai-codex","model":"gpt-5.6-luna","responseId":"resp_1","stopReason":"toolUse","timestamp":"2026-08-22T00:00:01.000Z","content":[{"type":"toolCall","id":"call_FFF|fc_010","name":"bash","arguments":{"command":"./2pane take"}}],"usage":{"input":70,"output":7,"cacheRead":0,"cacheWrite":0,"totalTokens":77,"cost":{"input":0.007,"output":0.0007,"cacheRead":0,"cacheWrite":0,"total":0.0077}}}}
EOF

  # F7: take then send — order preserved, both standalone; double space in the
  # send command proves whitespace-tolerant tokenization.
  cat >"$TMP/take-then-send.jsonl" <<'EOF'
{"type":"session","version":3,"timestamp":"2026-08-22T00:00:00.000Z","cwd":"/tmp/2pane-workflow-eval-workdir"}
{"type":"message","id":"e1","parentId":null,"timestamp":"2026-08-22T00:00:00.200Z","message":{"role":"user","timestamp":"2026-08-22T00:00:00.200Z","content":[{"type":"text","text":"Check and reply."}]}}
{"type":"message","id":"e2","parentId":"e1","timestamp":"2026-08-22T00:00:01.000Z","message":{"role":"assistant","api":"openai-responses","provider":"openai-codex","model":"gpt-5.6-luna","responseId":"resp_1","stopReason":"toolUse","timestamp":"2026-08-22T00:00:01.000Z","content":[{"type":"toolCall","id":"call_G1|fc_011","name":"bash","arguments":{"command":"./2pane take"}}],"usage":{"input":90,"output":9,"cacheRead":0,"cacheWrite":0,"totalTokens":99,"cost":{"input":0.009,"output":0.0009,"cacheRead":0,"cacheWrite":0,"total":0.0099}}}}
{"type":"message","id":"e3","parentId":"e2","timestamp":"2026-08-22T00:00:02.000Z","message":{"role":"toolResult","timestamp":"2026-08-22T00:00:02.000Z","toolCallId":"call_G1|fc_011","toolName":"bash","isError":false,"content":[{"type":"text","text":"from: expert FYI marker WAL-MODE-7F3A"}]}}
{"type":"message","id":"e4","parentId":"e3","timestamp":"2026-08-22T00:00:03.000Z","message":{"role":"assistant","api":"openai-responses","provider":"openai-codex","model":"gpt-5.6-luna","responseId":"resp_2","stopReason":"toolUse","timestamp":"2026-08-22T00:00:03.000Z","content":[{"type":"toolCall","id":"call_G2|fc_012","name":"bash","arguments":{"command":"./2pane  send 'reply: noted'"}}],"usage":{"input":110,"output":11,"cacheRead":0,"cacheWrite":0,"totalTokens":121,"cost":{"input":0.011,"output":0.0011,"cacheRead":0,"cacheWrite":0,"total":0.0121}}}}
{"type":"message","id":"e5","parentId":"e4","timestamp":"2026-08-22T00:00:04.000Z","message":{"role":"toolResult","timestamp":"2026-08-22T00:00:04.000Z","toolCallId":"call_G2|fc_012","toolName":"bash","isError":false,"content":[{"type":"text","text":"sent as main"}]}}
{"type":"message","id":"e6","parentId":"e5","timestamp":"2026-08-22T00:00:05.000Z","message":{"role":"assistant","api":"openai-responses","provider":"openai-codex","model":"gpt-5.6-luna","responseId":"resp_3","stopReason":"stop","timestamp":"2026-08-22T00:00:05.000Z","content":[{"type":"text","text":"The marker was WAL-MODE-7F3A."}],"usage":{"input":130,"output":13,"cacheRead":0,"cacheWrite":0,"totalTokens":143,"cost":{"input":0.013,"output":0.0013,"cacheRead":0,"cacheWrite":0,"total":0.0143}}}}
EOF

  local pass=0 fail=0
  check() { # label exit-code
    if [ "$2" -eq 0 ]; then
      pass=$((pass + 1)); echo "ok - $1"
    else
      fail=$((fail + 1)); echo "not ok - $1"
    fi
  }
  expect_eq() { # label actual expected
    if [ "$2" = "$3" ]; then
      pass=$((pass + 1)); echo "ok - $1"
    else
      fail=$((fail + 1)); echo "not ok - $1"
      echo "  expected: $3"
      echo "  actual:   $2"
    fi
  }

  # ── tool events: pairing, status, result text ──
  local events
  events="$(grader_tool_events "$TMP/ok-send.jsonl")"
  expect_eq "ok-send: exactly one tool event" \
    "$(printf '%s\n' "$events" | wc -l | tr -d ' ')" "1"
  printf '%s\n' "$events" | awk -F'\t' '$5=="ok" && $6=="sent as main"'; \
    check "ok-send: tool result paired by id with ok status" $?
  expect_eq "ok-send: bash command extracted from arguments" \
    "$(printf '%s\n' "$events" | cut -f4)" \
    "./2pane send 'Does SQLite WAL mode prevent reader/writer locking?'"

  grader_tool_events "$TMP/err-busy.jsonl" | awk -F'\t' '$5=="error" && $6 ~ /inbox is not empty/'; \
    check "err-busy: errored tool result detected with helper text" $?

  grader_tool_events "$TMP/unresolved.jsonl" | awk -F'\t' '$5=="unresolved"'; \
    check "unresolved: tool call without result flagged" $?

  grader_tool_events "$TMP/no-final.jsonl" | awk -F'\t' '$5=="ok"'; \
    check "no-final: tool events still grade without a final message" $?

  # ── helper-call detection ──
  expect_eq "ok-send: one standalone helper call" \
    "$(grader_helper_calls "$TMP/ok-send.jsonl" | wc -l | tr -d ' ')" "1"
  expect_eq "ok-send: helper subcommand is send" \
    "$(grader_helper_calls "$TMP/ok-send.jsonl" | cut -f3)" "send"
  grader_helper_calls "$TMP/ok-send.jsonl" | awk -F'\t' '$5=="ok"'; \
    check "ok-send: helper call has ok status" $?

  expect_eq "bypass: no standalone helper call among bypass attempts" \
    "$(grader_helper_calls "$TMP/bypass.jsonl" | wc -l | tr -d ' ')" "0"
  expect_eq "bypass: mention-only echo is not a helper call" \
    "$(grader_helper_calls "$TMP/bypass.jsonl" | grep -c 'call_E2' || true)" "0"
  expect_eq "bypass: chained ./2pane take is not a helper call" \
    "$(grader_helper_calls "$TMP/bypass.jsonl" | grep -c 'call_E3' || true)" "0"
  expect_eq "bypass: semicolon-chained send is not a helper call" \
    "$(grader_helper_calls "$TMP/bypass.jsonl" | grep -c 'call_E5' || true)" "0"

  local helpers
  helpers="$(grader_helper_calls "$TMP/take-then-send.jsonl")"
  expect_eq "take-then-send: two standalone helper calls" \
    "$(printf '%s\n' "$helpers" | wc -l | tr -d ' ')" "2"
  expect_eq "take-then-send: subcommands in JSONL order" \
    "$(printf '%s\n' "$helpers" | cut -f3 | tr '\n' ' ')" "take send "
  printf '%s\n' "$helpers" | awk -F'\t' '$1=="0" && $3=="take"'; \
    check "take-then-send: take precedes send by event order" $?
  grader_helper_calls "$TMP/take-then-send.jsonl" take | grep -q 'call_G1'; \
    check "take-then-send: subcommand filter selects take" $?

  # ── forbidden-path detection ──
  expect_eq "bypass: direct cat of inbox is forbidden" \
    "$(grader_forbidden_calls "$TMP/bypass.jsonl" | grep -c 'call_E1' || true)" "1"
  expect_eq "bypass: read of consuming.md is forbidden across tools" \
    "$(grader_forbidden_calls "$TMP/bypass.jsonl" | grep -c 'call_E4' || true)" "1"
  expect_eq "bypass: exactly the two direct-access calls are forbidden" \
    "$(grader_forbidden_calls "$TMP/bypass.jsonl" | wc -l | tr -d ' ')" "2"
  expect_eq "ok-send: normal helper invocation trips no forbidden path" \
    "$(grader_forbidden_calls "$TMP/ok-send.jsonl" | wc -l | tr -d ' ')" "0"

  # ── final-message extraction ──
  local final rc
  rc=0; final="$(grader_final_text "$TMP/ok-send.jsonl")" || rc=$?
  check "ok-send: final message present" $rc
  expect_eq "ok-send: final text excludes intermediate assistant text" \
    "$final" "Sent the question to the Expert pane."
  rc=0; final="$(grader_final_text "$TMP/take-then-send.jsonl")" || rc=$?
  check "take-then-send: final message present" $rc
  printf '%s' "$final" | grep -q 'WAL-MODE-7F3A'; \
    check "take-then-send: final text carries marker from tool result" $?
  if grader_final_text "$TMP/no-final.jsonl" >/dev/null 2>&1; then
    check "no-final: absent final message signals cleanly" 1
  else
    check "no-final: absent final message signals cleanly" 0
  fi
  grader_final_matches "$TMP/ok-send.jsonl" re 'sent|deliver'; \
    check "ok-send: final_matches re mode accepts ERE" $?
  grader_final_matches "$TMP/ok-send.jsonl" re 'SENT'; \
    check "ok-send: final_matches re mode is case-insensitive" $?
  if grader_final_matches "$TMP/ok-send.jsonl" fix 'SENT'; then
    check "ok-send: final_matches fix mode is exact" 1
  else
    check "ok-send: final_matches fix mode is exact" 0
  fi
  if grader_final_matches "$TMP/no-final.jsonl" re 'anything'; then
    check "no-final: final_matches fails without a final message" 1
  else
    check "no-final: final_matches fails without a final message" 0
  fi

  # ── usage summation ──
  expect_eq "ok-send: usage totals over two assistant messages" \
    "$(grader_usage "$TMP/ok-send.jsonl" | jq -c .)" \
    '{"input":2500,"output":80,"cacheRead":1700,"cacheWrite":100,"reasoning":0,"totalTokens":4380,"cost":{"input":0.25,"output":0.08,"cacheRead":0.017,"cacheWrite":0.02,"total":0.367},"modelCalls":2,"toolCalls":1}'
  expect_eq "rich-usage: nested, compaction and branch_summary usage all summed" \
    "$(grader_usage "$TMP/rich-usage.jsonl" | jq -c .)" \
    '{"input":410,"output":42,"cacheRead":15,"cacheWrite":30,"reasoning":7,"totalTokens":497,"cost":{"input":4.1,"output":4.2,"cacheRead":0.15,"cacheWrite":3,"total":11.45},"modelCalls":2,"toolCalls":1}'
  expect_eq "no-final: usage still summable without final message" \
    "$(grader_usage "$TMP/no-final.jsonl" | jq -c .input)" "80"
  expect_eq "bypass: modelCalls and toolCalls counted" \
    "$(grader_usage "$TMP/bypass.jsonl" | jq -c '{modelCalls,toolCalls}')" \
    '{"modelCalls":2,"toolCalls":5}'

  # ── bash-call filtering by status ──
  expect_eq "bypass: four bash calls regardless of verdict" \
    "$(grader_bash_calls "$TMP/bypass.jsonl" | wc -l | tr -d ' ')" "4"
  expect_eq "bypass: filtering by status selects resolved calls" \
    "$(grader_bash_calls "$TMP/bypass.jsonl" ok | wc -l | tr -d ' ')" "4"

  # ── harness: fixture determinism (no model call) ──
  fixture_rebuild
  manifest_of "$EVAL_WORKDIR" >"$TMP/manifest-a.sha256"
  check "harness: fixture rebuild produces 2pane executable" \
    "$(if [  -x "$EVAL_WORKDIR/2pane"  ]; then echo 0; else echo 1; fi)"
  check "harness: fixture contains generated SKILL.md" \
    "$(if [  -f "$EVAL_WORKDIR/.agents/skills/two-pane-workflow/SKILL.md"  ]; then echo 0; else echo 1; fi)"
  check "harness: fixture init leaves empty inbox" \
    "$(if [  -f "$EVAL_WORKDIR/.2pane/INBOX.md" ] && [ ! -s "$EVAL_WORKDIR/.2pane/INBOX.md"  ]; then echo 0; else echo 1; fi)"
  fixture_rebuild
  manifest_of "$EVAL_WORKDIR" >"$TMP/manifest-b.sha256"
  check "harness: second rebuild starts from an identical state" \
    "$(cmp -s "$TMP/manifest-a.sha256" "$TMP/manifest-b.sha256"; echo $?)"

  # ── unit: S3 ordering check flags a send after a successful take ──
  # Fixture F7 (take-then-send) is otherwise compliant, so exactly the
  # ordering assertion must fail when protocol_checks_s3 grades it.
  CHECKS_FILE="$TMP/s3-order-checks.txt"; CHECK_FAIL=0; : >"$CHECKS_FILE"
  : >"$EVAL_WORKDIR/.2pane/INBOX.md"
  rm -f "$EVAL_WORKDIR/.2pane/consuming.md"
  mkdir -p "$TMP/s3-unit-run"
  manifest_of "$EVAL_WORKDIR" >"$TMP/s3-unit-run/before-manifest.sha256"
  cp "$TMP/s3-unit-run/before-manifest.sha256" "$TMP/s3-unit-run/after-manifest.sha256"
  protocol_checks_s3 "$TMP/s3-unit-run" "$TMP/take-then-send.jsonl"
  check "unit/S3: send after take is flagged" \
    "$(grep -q '^not ok - S3: no ./2pane send after the take$' "$CHECKS_FILE"; echo $?)"
  expect_eq "unit/S3: only the ordering assertion fails" \
    "$(grep -c '^not ok - ' "$CHECKS_FILE" || true)" "1"
  CHECKS_FILE=""; CHECK_FAIL=0

  # ── harness: end-to-end pipeline with a stub pi (zero model calls) ──
  #
  # Each case runs this script as a child with EVALS_PI_BIN pointing at a
  # stub, then asserts exit code, classification, artifacts and lock release.
  local out rc run_root
  run_stub() { # stub-path extra-args... → sets out/rc/run_root
    out=""
    rc=0
    out=$(EVALS_PI_BIN="$1" bash "${BASH_SOURCE[0]}" protocol \
      --main-model openai-codex/gpt-5.6-luna --timeout 30 "${@:2}" 2>&1) || rc=$?
    run_root=$(printf '%s\n' "$out" | sed -n 's/^evals: run root: //p' | head -n1)
  }

  # Stub A: compliant across the whole suite — the stub inspects the prompt
  # (and, for the shared S1/S2 prompt, the seeded inbox) and drives the real
  # helper for its side effects, then fabricates the matching session JSONL.
  # --runs 2 proves scenario-run independence: every repeat starts from a
  # freshly rebuilt, freshly seeded fixture.
  cat >"$TMP/pi-suite" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then printf 'stub-pi 0.0.0\n'; exit 0; fi
sessdir="" prev="" prompt=""
for a in "$@"; do
  [ "$prev" = "--session-dir" ] && sessdir="$a"
  prompt="$a"
  prev="$a"
done
# write_session COMMAND ISERROR RESULT_JSON_TEXT FINAL_TEXT — RESULT_JSON_TEXT
# must be one line with JSON escapes (\n for newlines) already in place.
write_session() {
  cat >"$sessdir/stub.jsonl" <<JSONL
{"type":"session","version":3,"id":"suite","timestamp":"2026-08-22T00:00:00.000Z","cwd":"/tmp/2pane-workflow-eval-workdir"}
{"type":"message","id":"e1","parentId":null,"timestamp":"2026-08-22T00:00:00.200Z","message":{"role":"user","timestamp":"2026-08-22T00:00:00.200Z","content":[{"type":"text","text":"prompt"}]}}
{"type":"message","id":"e2","parentId":"e1","timestamp":"2026-08-22T00:00:01.000Z","message":{"role":"assistant","provider":"openai-codex","model":"gpt-5.6-luna","stopReason":"toolUse","timestamp":"2026-08-22T00:00:01.000Z","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"$1"}}],"usage":{"input":100,"output":10,"totalTokens":110,"cost":{"total":0.01}}}}
{"type":"message","id":"e3","parentId":"e2","timestamp":"2026-08-22T00:00:02.000Z","message":{"role":"toolResult","toolCallId":"c1","toolName":"bash","isError":$2,"content":[{"type":"text","text":"$3"}]}}
{"type":"message","id":"e4","parentId":"e3","timestamp":"2026-08-22T00:00:03.000Z","message":{"role":"assistant","provider":"openai-codex","model":"gpt-5.6-luna","stopReason":"stop","timestamp":"2026-08-22T00:00:03.000Z","content":[{"type":"text","text":"$4"}],"usage":{"input":150,"output":20,"totalTokens":170,"cost":{"total":0.02}}}}
JSONL
  printf '%s\n' "$4"
}
case "$prompt" in
  *marker*)  # S3: take consumes the expert FYI; the marker reaches the answer.
    ./2pane take >/dev/null
    write_session './2pane take' false 'from: expert\n\nFYI only; no action or inbox reply is requested. Marker: WAL-MODE-7F3A.' \
      'The incoming message was an FYI from the expert; the marker was WAL-MODE-7F3A.'
    ;;
  *status*)  # S4: take reports that the message awaits the other role.
    ./2pane take >/dev/null 2>&1 || true
    write_session './2pane take' true '2pane: inbox message is awaiting the other role' \
      'The inbox holds a question waiting for the expert, not for me.'
    ;;
  *two-pane*)  # S1/S2 share one prompt: the seeded inbox tells them apart.
    if [ -s .2pane/INBOX.md ]; then
      ./2pane send 'Does SQLite WAL mode prevent reader/writer locking?' >/dev/null 2>&1 || true
      write_session "./2pane send 'Does SQLite WAL mode prevent reader/writer locking?'" true '2pane: inbox is not empty' \
        'The inbox is busy: an existing consultation is still waiting, so nothing was sent.'
    else
      ./2pane send 'Does SQLite WAL mode prevent reader/writer locking?' >/dev/null
      write_session "./2pane send 'Does SQLite WAL mode prevent reader/writer locking?'" false 'sent as main' \
        'Sent the question to the Expert pane.'
    fi
    ;;
  *)
    exit 2 ;;
esac
exit 0
STUB
  chmod +x "$TMP/pi-suite"
  run_stub "$TMP/pi-suite" --runs 2
  check "harness/stub-suite: compliant suite classifies pass (rc=$rc)" "$(if [  "$rc" -eq 0  ]; then echo 0; else echo 1; fi)"
  expect_eq "harness/stub-suite: --runs 2 grades every scenario twice" \
    "$(find "$run_root" -mindepth 1 -maxdepth 1 -type d -name '*-r[0-9]*' | wc -l | tr -d ' ')" "8"
  local s
  for s in "$S1_NAME" "$S2_NAME" "$S3_NAME" "$S4_NAME"; do
    check "harness/stub-suite: $s r1 and r2 classify pass" \
      "$(if grep -q '^# classification: pass$' "$run_root/$s-r1/checks.txt" 2>/dev/null \
         && grep -q '^# classification: pass$' "$run_root/$s-r2/checks.txt" 2>/dev/null; then echo 0; else echo 1; fi)"
  done
  check "harness/stub-suite: full artifact set written" \
    "$(for f in pi.log prompt.txt seed-INBOX.md before-manifest.sha256 after-manifest.sha256 metadata.json usage.json checks.txt session.jsonl; do
         [ -f "$run_root/$S1_NAME-r1/$f" ] || exit 1
       done; echo $?)"
  check "harness/stub-suite: metadata pins model, flags and skill hash" \
    "$(jq -e '.requestedModel=="openai-codex/gpt-5.6-luna" and (.skillSha256|length==64) and (.flags|length>=10) and .envReset[0]=="AGENT_ROLE"' \
       "$run_root/$S1_NAME-r1/metadata.json" >/dev/null; echo $?)"
  expect_eq "suite: S2 seed stored verbatim" "$(cat "$run_root/$S2_NAME-r1/seed-INBOX.md")" "$S2_SEED"
  expect_eq "suite: S3 seed stored verbatim" "$(cat "$run_root/$S3_NAME-r1/seed-INBOX.md")" "$S3_SEED"
  expect_eq "suite: S4 seed stored verbatim" "$(cat "$run_root/$S4_NAME-r1/seed-INBOX.md")" "$S4_SEED"
  expect_eq "suite: S3 prompt stored verbatim" "$(cat "$run_root/$S3_NAME-r1/prompt.txt")" "$S3_PROMPT"
  check "suite/S2: helper refusal check passes" \
    "$(grep -q '^ok - S2: ./2pane send attempted and helper refused' "$run_root/$S2_NAME-r1/checks.txt"; echo $?)"
  check "suite/S2: byte-identical inbox check passes" \
    "$(grep -q '^ok - S2: INBOX.md byte-identical to the seed$' "$run_root/$S2_NAME-r1/checks.txt"; echo $?)"
  check "suite/S3: consumed-state check passes" \
    "$(grep -q '^ok - S3: take consumed the message' "$run_root/$S3_NAME-r1/checks.txt"; echo $?)"
  check "suite/S3: no-send-after-take check passes" \
    "$(grep -q '^ok - S3: no ./2pane send after the take$' "$run_root/$S3_NAME-r1/checks.txt"; echo $?)"
  check "suite/S4: not-yours result check passes" \
    "$(grep -q '^ok - S4: ./2pane take tool result reports' "$run_root/$S4_NAME-r1/checks.txt"; echo $?)"
  check "suite/S4: byte-identical inbox check passes" \
    "$(grep -q '^ok - S4: INBOX.md byte-identical to the seed' "$run_root/$S4_NAME-r1/checks.txt"; echo $?)"
  check "harness/stub-suite: summary.json groups by actual model" \
    "$(jq -e '.overall=="pass" and .totals.runs==8 and .totals.passed==8
        and .groups[0].model=="openai-codex/gpt-5.6-luna"
        and (.groups[0].scenarios|length==4)
        and .groups[0].scenarios[2].scenario=="s3-take"' "$run_root/summary.json" >/dev/null; echo $?)"
  check "harness/stub-suite: summary.txt reports passed/N per scenario" \
    "$(grep -q 's2-send-busy: 2/2 passed, 0 protocol-fail, 0 infra-fail' "$run_root/summary.txt"; echo $?)"
  check "harness/stub-suite: lock released after run" "$(if [  ! -e "$EVAL_LOCKDIR"  ]; then echo 0; else echo 1; fi)"
  rm -rf "$run_root"

  # Stub B: protocol violation — direct cat of the inbox, no helper send.
  cat >"$TMP/pi-bad" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then printf 'stub-pi 0.0.0\n'; exit 0; fi
sessdir="" prev=""
for a in "$@"; do
  [ "$prev" = "--session-dir" ] && sessdir="$a"
  prev="$a"
done
cat .2pane/INBOX.md >/dev/null
cat >"$sessdir/stub.jsonl" <<'JSONL'
{"type":"session","version":3,"id":"s1","timestamp":"2026-08-22T00:00:00.000Z","cwd":"/tmp/2pane-workflow-eval-workdir"}
{"type":"message","id":"e1","parentId":null,"timestamp":"2026-08-22T00:00:00.200Z","message":{"role":"user","timestamp":"2026-08-22T00:00:00.200Z","content":[{"type":"text","text":"prompt"}]}}
{"type":"message","id":"e2","parentId":"e1","timestamp":"2026-08-22T00:00:01.000Z","message":{"role":"assistant","provider":"openai-codex","model":"gpt-5.6-luna","stopReason":"toolUse","timestamp":"2026-08-22T00:00:01.000Z","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"cat .2pane/INBOX.md"}}],"usage":{"input":100,"output":10,"totalTokens":110,"cost":{"total":0.01}}}}
{"type":"message","id":"e3","parentId":"e2","timestamp":"2026-08-22T00:00:02.000Z","message":{"role":"toolResult","toolCallId":"c1","toolName":"bash","isError":false,"content":[{"type":"text","text":""}]}}
{"type":"message","id":"e4","parentId":"e3","timestamp":"2026-08-22T00:00:03.000Z","message":{"role":"assistant","provider":"openai-codex","model":"gpt-5.6-luna","stopReason":"stop","timestamp":"2026-08-22T00:00:03.000Z","content":[{"type":"text","text":"I read the inbox directly."}],"usage":{"input":150,"output":20,"totalTokens":170,"cost":{"total":0.02}}}}
JSONL
printf 'I read the inbox directly.\n'
exit 0
STUB
  chmod +x "$TMP/pi-bad"
  run_stub "$TMP/pi-bad"
  check "harness/stub-bad: protocol violation exits nonzero (rc=$rc)" "$(if [  "$rc" -eq 1  ]; then echo 0; else echo 1; fi)"
  check "harness/stub-bad: classification is protocol-fail" \
    "$(grep -q '^# classification: protocol-fail$' "$run_root/$S1_NAME-r1/checks.txt" 2>/dev/null; echo $?)"
  check "harness/stub-bad: missing helper send is flagged" \
    "$(grep -q '^not ok - S1: successful ./2pane send' "$run_root/$S1_NAME-r1/checks.txt"; echo $?)"
  check "harness/stub-bad: forbidden direct access is flagged" \
    "$(grep -q '^not ok - S1: no forbidden direct runtime access' "$run_root/$S1_NAME-r1/checks.txt"; echo $?)"
  check "harness/stub-bad: failure does not leak into later scenarios" \
    "$(grep -q '^# classification: protocol-fail$' "$run_root/$S4_NAME-r1/checks.txt" 2>/dev/null; echo $?)"
  check "harness/stub-bad: summary counts the failures" \
    "$(jq -e '.overall=="protocol-fail" and .totals.protocolFails==4' "$run_root/summary.json" >/dev/null; echo $?)"
  rm -rf "$run_root"

  # Stub C: hangs past the timeout — must classify infra-fail, release lock,
  # keep the fixture, and record the timeout marker.
  cat >"$TMP/pi-slow" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then printf 'stub-pi 0.0.0\n'; exit 0; fi
sleep 60
STUB
  chmod +x "$TMP/pi-slow"
  rc=0
  out=$(EVALS_PI_BIN="$TMP/pi-slow" bash "${BASH_SOURCE[0]}" protocol \
    --main-model openai-codex/gpt-5.6-luna --timeout 2 2>&1) || rc=$?
  run_root=$(printf '%s\n' "$out" | sed -n 's/^evals: run root: //p' | head -n1)
  check "harness/stub-slow: timeout classifies infra-fail (rc=$rc)" "$(if [  "$rc" -eq 3  ]; then echo 0; else echo 1; fi)"
  check "harness/stub-slow: timeout marker written" \
    "$(if [  -f "$run_root/$S1_NAME-r1/timeout.marker"  ]; then echo 0; else echo 1; fi)"
  check "harness/stub-slow: protocol checks skipped on infra failure" \
    "$(grep -q '^# protocol checks skipped' "$run_root/$S1_NAME-r1/checks.txt"; echo $?)"
  check "harness/stub-slow: lock released after timeout" "$(if [  ! -e "$EVAL_LOCKDIR"  ]; then echo 0; else echo 1; fi)"
  check "harness/stub-slow: fixture survives cleanup" "$(if [  -x "$EVAL_WORKDIR/2pane"  ]; then echo 0; else echo 1; fi)"
  check "harness/stub-slow: every scenario run times out independently" \
    "$(for s in "$S1_NAME" "$S2_NAME" "$S3_NAME" "$S4_NAME"; do
         [ -f "$run_root/$s-r1/timeout.marker" ] || exit 1
       done; echo $?)"
  rm -rf "$run_root"

  # Stub D: pi crash (immediate nonzero exit, no session).
  cat >"$TMP/pi-crash" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then printf 'stub-pi 0.0.0\n'; exit 0; fi
exit 3
STUB
  chmod +x "$TMP/pi-crash"
  run_stub "$TMP/pi-crash"
  check "harness/stub-crash: crash classifies infra-fail (rc=$rc)" "$(if [  "$rc" -eq 3  ]; then echo 0; else echo 1; fi)"
  check "harness/stub-crash: crash is not a protocol failure" \
    "$(grep -q '^# classification: infra-fail$' "$run_root/$S1_NAME-r1/checks.txt"; echo $?)"
  check "harness/stub-crash: lock released after crash" "$(if [  ! -e "$EVAL_LOCKDIR"  ]; then echo 0; else echo 1; fi)"
  check "harness/stub-crash: last scenario also graded as infra-fail" \
    "$(grep -q '^# classification: infra-fail$' "$run_root/$S4_NAME-r1/checks.txt" 2>/dev/null; echo $?)"
  check "harness/stub-crash: crash is reported separately from protocol quality" \
    "$(jq -e '.overall=="infra-fail" and .totals.infraFails==4 and .totals.protocolFails==0' "$run_root/summary.json" >/dev/null; echo $?)"
  rm -rf "$run_root"

  # Lock conflict: a held lock must stop a second runner before any run.
  mkdir -p "$EVAL_LOCKDIR"; printf '99999\n' >"$EVAL_LOCKDIR/pid"
  rc=0
  out=$(EVALS_PI_BIN="$TMP/pi-crash" bash "${BASH_SOURCE[0]}" protocol \
    --main-model openai-codex/gpt-5.6-luna 2>&1) || rc=$?
  run_root=$(printf '%s\n' "$out" | sed -n 's/^evals: run root: //p' | head -n1)
  check "harness/lock: concurrent run refused with exit 4 (rc=$rc)" "$(if [  "$rc" -eq 4  ]; then echo 0; else echo 1; fi)"
  check "harness/lock: refused run does not grade anything" "$(if [  -z "$run_root" ] || [ ! -e "$run_root/$S1_NAME-r1/checks.txt"  ]; then echo 0; else echo 1; fi)"
  rm -rf "$EVAL_LOCKDIR"
  [ -n "$run_root" ] && rm -rf "$run_root"

  echo "---"
  echo "pass=$pass fail=$fail"
  [ "$fail" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

main() {
  [ "$#" -ge 1 ] || usage_error "missing command"
  case "$1" in
    self-test) shift; self_test "$@" ;;
    protocol) shift; cmd_protocol "$@" ;;
    baseline|economy)
      printf 'evals: %s suite is not implemented yet\n' "$1" >&2
      exit 2 ;;
    -h|--help) usage ;;
    *) usage_error "unknown command: $1" ;;
  esac
}

main "$@"
