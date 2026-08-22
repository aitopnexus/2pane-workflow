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
#   ticket 04: infra-fail taxonomy — requested/actual model pinning incl.
#              mid-session changes (assistant messages + model_change),
#              loaded-resource pinning (pinned skill reads, custom entries)
#              with an infra gate, and a violation-matrix of negative
#              self-tests (zero model calls).
#   ticket 05: baseline suite — the one expensive direct-Expert reference
#              run, cached persistently: economy fixture (helper + the two
#              docs), verbatim mode+task prompt, fingerprint-addressed
#              immutable store with an atomic active marker, reuse with no
#              model call, --refresh-baseline, publication only on pass.
#   ticket 06: economy E1 driver — a fresh Main-Model session receives the
#              mode instruction plus the verbatim task; the driver acts purely
#              as a human-router (inbox state decides who acts next), starts
#              or continues one Expert session per consultation cycle with
#              AGENT_ROLE=expert, resumes each role's single JSONL via pi
#              --session so context and usage never reset, counts zero
#              consultations as expert-skipped, and rails the whole run with
#              a wall-clock timeout and a pi-turn cap (both infra-fail).
#   ticket 07: economy verdict — median summed-Expert-tokens saving against
#              the immutable cached baseline, post-run --min-expert-saving
#              gate (economy-fail), per-result baseline reference (id,
#              fingerprint, session hash, usage snapshot), exploratory marker
#              on single-sample comparisons, and the full token+money cost
#              report (Main vs Expert vs baseline, Expert share).
#   fix 2026-08-22 #2: helper-call recognition accepts an inert `cd DIR &&`
#              prefix before the standalone `./2pane send|take` (observed
#              live: models spelling the call `cd <workdir> && ./2pane send`;
#              cd cannot read/write/pipe anything). The helper must be the
#              LAST segment; any other chaining, pipes, redirects or
#              non-send/take subcommands still fail, and the forbidden-path
#              args scan (which catches `cd …/.2pane && …`) is unchanged.
#   fix 2026-08-22 #1: grader_reads_outside_fixture also accepts the PHYSICAL
#              (symlink-resolved) spelling of the eval workdir — on macOS
#              /tmp → /private/tmp, and a model reading the fixture docs via
#              the canonical path was falsely flagged as reading outside
#              the fixture (deterministic self-test added).
#
# Usage:
#   evals/run.sh self-test
#   evals/run.sh protocol --main-model SPEC [--runs N] [--timeout SEC]
#   evals/run.sh baseline --expert-model SPEC [--timeout SEC]
#                        [--refresh-baseline]
#   evals/run.sh economy --main-model SPEC --expert-model SPEC
#                        [--runs N] [--timeout SEC] [--run-timeout SEC]
#                        [--turn-cap N] [--min-expert-saving PCT]
#                        [--baseline-id ID]
#
# Exit codes: 0 pass · 1 protocol-fail · 2 usage error · 3 infra-fail ·
#             4 lock busy · 5 economy-fail · 6 baseline-missing
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
  baseline --expert-model SPEC     The persistent Expert-only baseline: the
    [--timeout SEC]                one expensive direct-Expert run over the
    [--refresh-baseline]           economy task. A matching fingerprint is
                                   reused with no model call;
                                   --refresh-baseline forces a new immutable
                                   baseline and repoints the active marker
  economy --main-model SPEC        E1 two-pane vs the cached Expert-only
          --expert-model SPEC     baseline (tickets 06/07). The driver only
    [--runs N]                    routes by inbox state; Main alone decides
    [--timeout SEC]               how often to consult. Rails: --run-timeout
    [--run-timeout SEC]           (wall clock, default 600s) and --turn-cap
    [--turn-cap N]                (pi turns, default 8); either triggering is
    [--min-expert-saving PCT]     infra-fail. --min-expert-saving is a strict
    [--baseline-id ID]            post-run gate (economy-fail). A missing
                                  baseline exits 6 before any model call;
                                  --baseline-id pins a specific stored run

Options:
  -h, --help                     Show this help

Exit codes:
  0 pass · 1 protocol-fail · 2 usage error · 3 infra-fail · 4 lock busy ·
  5 economy-fail · 6 baseline-missing
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

# split_unquoted_amp COMMAND — print COMMAND's segments split on unquoted
# `&&`, quote-aware: a quoted && is data, not a chain.
split_unquoted_amp() {
  local cmd="$1" i ch quote="" seg=""
  for ((i = 0; i < ${#cmd}; i++)); do
    ch="${cmd:i:1}"
    if [ -n "$quote" ]; then
      seg+="$ch"
      [ "$ch" = "$quote" ] && quote=""
      continue
    fi
    case "$ch" in
      "'"|'"') quote="$ch"; seg+="$ch" ;;
      "&")
        if [ "${cmd:i+1:1}" = "&" ]; then
          printf '%s\n' "$seg"
          seg=""
          i=$((i + 1))
        else
          seg+="$ch"
        fi ;;
      *) seg+="$ch" ;;
    esac
  done
  printf '%s\n' "$seg"
}

# helper_shape_sub COMMAND — prints `send`/`take` and exits 0 iff COMMAND is
# a helper invocation in the narrow allowed shape: the LAST `&&`-segment is
# a standalone `./2pane send|take ...` (as before), optionally preceded only
# by inert `cd DIR` segments (first token `cd`, no chaining/redirection —
# cd cannot read, write or pipe anything, so a model spelling the call
# `cd <workdir> && ./2pane send ...` is graded on the helper it ran).
# Everything else — other commands before or after the helper, pipes,
# redirections, non-send/take subcommands — still fails, and the
# forbidden-path scan over serialized arguments applies independently
# (`cd …/.2pane && …` stays a violation).
helper_shape_sub() {
  local cmd="$1" seg sub i
  local -a segs=() toks
  while IFS= read -r seg; do segs+=("$seg"); done < <(split_unquoted_amp "$cmd")
  local n=${#segs[@]}
  [ "$n" -ge 1 ] || return 1
  sub="$(helper_subcommand "${segs[n-1]}")" || return 1
  command_is_standalone "${segs[n-1]}" || return 1
  for ((i = 0; i < n - 1; i++)); do
    read -r -a toks <<<"${segs[i]}"
    [ "${toks[0]-}" = cd ] || return 1
    command_is_standalone "${segs[i]}" || return 1
  done
  printf '%s\n' "$sub"
}

# grader_helper_calls FILE [send|take] — TSV of bash tool events that are a
# helper invocation in the allowed shape (standalone `./2pane <subcommand>`,
# optionally cd-prefixed; fields as in grader_tool_events).
grader_helper_calls() {
  local want="${2-}" sub
  grader_tool_events "$1" | while IFS=$'\t' read -r seq id name command status text; do
    [ "$name" = "bash" ] || continue
    sub="$(helper_shape_sub "$command")" || continue
    { [ -z "$want" ] || [ "$sub" = "$want" ]; } || continue
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

# grader_loaded_resources FILE — TSV (kind, name) of resources that entered
# the model's context. Pi session v3 has no dedicated resource entries, so
# the observable traces are pinned instead: skill files pulled in via `read`
# calls (progressive disclosure) and custom/custom_message entries, which
# only extensions write. Synthetic self-test fixtures pin this extraction
# shape so a pi format change fails loudly instead of grading nothing.
grader_loaded_resources() {
  jq -r -s '
    [ .[] | select(.type=="message" and .message.role=="assistant")
      | .message.content[]? | select(.type=="toolCall" and .name=="read")
      | (.arguments.path // empty)
      | select(test("\\.agents/skills/[^/]+/"))
      | capture("\\.agents/skills/(?<name>[^/]+)/").name
      | "skill-read\t\(.)" ]
    + [ .[] | select(.type=="custom") | "custom-entry\t\(.customType // "?")" ]
    + [ .[] | select(.type=="custom_message") | "custom-message\t\(.customType // "?")" ]
    | .[]' "$1"
}

# unexpected_resources TSV PINNED_SKILL — the rows of a
# grader_loaded_resources listing that are not the one pinned skill.
# Custom entries are always unexpected: global extensions are disabled.
unexpected_resources() {
  awk -F'\t' -v pinned="$2" '
    $1 == "skill-read" && $2 == pinned { next }
    NF >= 2 { print }' <<<"$1"
}

# grader_models_unique SESS — sorted unique provider/model pairs seen across
# every assistant message and model_change entry of one session. A continued
# (resumed) session must still report exactly the requested pair.
grader_models_unique() {
  jq -s -r '
    [ .[] | select(.type == "message" and .message.role == "assistant")
      | "\(.message.provider // "")/\(.message.responseModel // .message.model // "")" ]
    + [ .[] | select(.type == "model_change")
      | "\(.provider // "")/\(.modelId // "")" ]
    | unique | .[]' "$1"
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

# grader_reads_outside_fixture FILE — read tool calls whose path escapes the
# fixture: absolute paths outside the eval workdir, or relative paths with a
# `..` component. Economy runs may read only the fixture's own files (the two
# docs, the skill); runtime state is covered separately by the forbidden scan.
# The workdir also matches by its PHYSICAL path (symlink-resolved): on macOS
# /tmp is a symlink to /private/tmp, and a model (or tool) reporting the
# canonical /private/tmp/... spelling of the same fixture file is not an
# escape. When the workdir does not exist the physical alias is unknown and
# only the literal spelling matches (an empty alias must match nothing).
grader_reads_outside_fixture() {
  local wdphys=""
  [ -d "$EVAL_WORKDIR" ] && wdphys="$(cd "$EVAL_WORKDIR" && pwd -P)"
  jq -r -s '
    [.[] | select(.type=="message" and .message.role=="assistant")
      | .message.content[]? | select(.type=="toolCall" and .name=="read")
      | (.arguments.path // empty)] | .[]' "$1" | while IFS= read -r p; do
      case "$p" in
        "$EVAL_WORKDIR"/*) continue ;;
      esac
      if [ -n "$wdphys" ]; then
        case "$p" in
          "$wdphys"/*) continue ;;
        esac
      fi
      case "$p" in
        /*) printf '%s\n' "$p" ;;
        ../*|*/../*|*/..|..) printf '%s\n' "$p" ;;
      esac
    done
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
# Overridable store root (EVALS_BASELINE_DIR) so stub self-tests never touch
# the real persistent baseline cache.
EVAL_BASELINES_DIR="${EVALS_BASELINE_DIR:-$REPO_ROOT/evals/baselines}"
EVAL_DEFAULT_TIMEOUT=180
EVAL_LOCK_HELD=0
EVAL_RUN_PID=""
EVALS_PI_BIN="${EVALS_PI_BIN:-pi}"
# The only skill allowed into a protocol run's context (pinned via
# --no-skills --skill in eval_pi_flags; gate key for loaded resources).
EVAL_PINNED_SKILL="two-pane-workflow"
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
    --skill "$EVAL_WORKDIR/.agents/skills/$EVAL_PINNED_SKILL/SKILL.md" \
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

# fixture_rebuild_economy — the protocol fixture plus exactly the two docs
# the economy task reviews; nothing else from the checkout enters the fixture.
fixture_rebuild_economy() {
  fixture_rebuild
  mkdir -p "$EVAL_WORKDIR/docs/adr"
  cp "$REPO_ROOT/docs/spec.md" "$EVAL_WORKDIR/docs/spec.md"
  cp "$REPO_ROOT/docs/adr/0001-single-slot-inbox.md" \
     "$EVAL_WORKDIR/docs/adr/0001-single-slot-inbox.md"
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
# Shared single-run engine (protocol scenarios + baseline)
#
# One pi process against the current fixture: pinned flags, reset env,
# per-call timeout with trap-based cleanup, session harvest, and the infra
# gates (exit status, timeout, JSONL count/integrity, requested/actual model
# incl. mid-session changes, thinking level, loaded resources). Suite-specific
# checks are the caller's; everything here is suite-independent.
# ─────────────────────────────────────────────────────────────────────────────

# run_pi_once RUN_DIR SESSIONS_DIR MODEL_SPEC PROMPT TIMEOUT_SEC [RESUME_SESS]
#   [AGENT_ROLE] — run one pi process and grade the infra gates. Uses
# REQ_PROVIDER/REQ_MODEL/REQ_THINKING from parse_model_spec. RESUME_SESS (a
# session file path) appends `--session <path>` so the turn continues that
# role's existing JSONL instead of starting a new one. AGENT_ROLE (main|
# expert) is exported for the process instead of being unset — the economy
# suite runs its Expert turns with the expert role so ./2pane send/take
# address the right pane; protocol and baseline runs keep it unset (Main).
# Sets RUN_RC, RUN_TIMED_OUT, RUN_STARTED_AT, RUN_ENDED_AT, RUN_TIMEOUT_SEC,
# RUN_FLAG_ARGS, RUN_SKILL_SHA, RUN_SESS, RUN_JSONL_COUNT, RUN_JSONL_VALID,
# RUN_ACTUAL_MODELS, RUN_THINKING_OBSERVED, RUN_LOADED_RESOURCES, RUN_INFRA;
# records the infra checks into CHECKS_FILE.
run_pi_once() {
  local run_dir="$1" sessions_dir="$2" model_spec="$3" prompt="$4" timeout_sec="$5"
  local resume_sess="${6-}" run_role="${7-}"
  RUN_TIMEOUT_SEC="$timeout_sec"
  RUN_SKILL_SHA="$($EVAL_SHA256 "$EVAL_WORKDIR/.agents/skills/$EVAL_PINNED_SKILL/SKILL.md" | awk '{print $1}')"

  local started_at ended_at rc=0 timed_out=0
  local marker="$run_dir/timeout.marker"
  started_at="$(utc_now)"
  RUN_STARTED_AT="$started_at"

  # One pi call: fixed cwd, reset env, pinned flags, per-call timeout.
  # AGENT_ROLE is exported (not unset) when a role is requested; everything
  # else stays reset.
  local flag_args=()
  while IFS= read -r f; do flag_args+=("$f"); done < <(eval_pi_flags "$model_spec" "$sessions_dir")
  if [ -n "$resume_sess" ]; then
    flag_args+=(--session "$resume_sess")
  fi
  local env_args=() v
  for v in "${EVAL_ENV_RESET[@]}"; do
    if [ "$v" = AGENT_ROLE ] && [ -n "$run_role" ]; then continue; fi
    env_args+=(-u "$v")
  done
  [ -n "$run_role" ] && env_args+=("AGENT_ROLE=$run_role")
  RUN_FLAG_ARGS=("${flag_args[@]}")
  (
    cd "$EVAL_WORKDIR"
    # shellcheck disable=SC2046  # intentional splitting into repeated -u NAME args
    exec env "${env_args[@]}" \
      "$EVALS_PI_BIN" "${flag_args[@]}" "$prompt" </dev/null
  ) >"$run_dir/pi.log" 2>&1 &
  EVAL_RUN_PID=$!
  # The watcher must not inherit the caller's stdout: its sleep child can
  # outlive the killed subshell, and an orphan holding a command-substitution
  # pipe open would block the caller for the whole timeout.
  (
    sleep "$timeout_sec"
    if kill -0 "$EVAL_RUN_PID" 2>/dev/null; then
      : >"$marker"
      kill -TERM "$EVAL_RUN_PID" 2>/dev/null || true
      sleep 5
      kill -KILL "$EVAL_RUN_PID" 2>/dev/null || true
    fi
  ) >/dev/null 2>&1 &
  local watcher=$!
  wait "$EVAL_RUN_PID" || rc=$?
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  EVAL_RUN_PID=""
  if [ -e "$marker" ]; then timed_out=1; fi
  ended_at="$(utc_now)"
  RUN_RC="$rc"
  RUN_TIMED_OUT="$timed_out"
  RUN_ENDED_AT="$ended_at"

  # Harvest the session: a suite run must produce exactly one JSONL.
  local sess="" jsonl_count=0 jsonl_valid=0
  jsonl_count=$(find "$sessions_dir" -maxdepth 1 -name '*.jsonl' -type f | wc -l | tr -d ' ')
  if [ "$jsonl_count" -eq 1 ]; then
    sess=$(find "$sessions_dir" -maxdepth 1 -name '*.jsonl' -type f)
    cp "$sess" "$run_dir/session.jsonl"
    sess="$run_dir/session.jsonl"
    if jq -s . "$sess" >/dev/null 2>&1; then jsonl_valid=1; fi
  fi
  RUN_SESS="$sess"
  RUN_JSONL_COUNT="$jsonl_count"
  RUN_JSONL_VALID="$jsonl_valid"

  # Requested vs actual model (infra gate per spec): every assistant
  # message and every model_change entry must report exactly the requested
  # provider/model — a mismatch or a mid-session change is infra-fail.
  local actual_models="" model_ok=0 thinking_observed="" thinking_ok=1
  if [ "$jsonl_valid" = 1 ]; then
    actual_models="$(grader_models_unique "$sess")"
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
  RUN_ACTUAL_MODELS="$actual_models"
  RUN_THINKING_OBSERVED="$thinking_observed"

  # Loaded-resource pinning (infra gate per spec): --no-skills --skill pins
  # exactly one skill and --no-extensions forbids extension entries, so any
  # other skill read or any custom entry means the environment leaked
  # something into the run.
  local loaded_resources="" res_unexpected="" resources_ok=1
  if [ "$jsonl_valid" = 1 ]; then
    loaded_resources="$(grader_loaded_resources "$sess")"
    res_unexpected="$(unexpected_resources "$loaded_resources" "$EVAL_PINNED_SKILL")"
    [ -z "$res_unexpected" ] || resources_ok=0
  fi
  RUN_LOADED_RESOURCES="$loaded_resources"

  local infra=0
  [ "$rc" -ne 0 ] && infra=1
  [ "$timed_out" = 1 ] && infra=1
  [ "$jsonl_count" -ne 1 ] && infra=1
  [ "$jsonl_valid" -ne 1 ] && infra=1
  [ "$model_ok" -ne 1 ] && infra=1
  [ "$thinking_ok" -ne 1 ] && infra=1
  [ "$resources_ok" -ne 1 ] && infra=1
  RUN_INFRA="$infra"

  check_bool "infra: pi exited 0 (exit=$rc)" "$( [ "$rc" -eq 0 ] && echo 1 || echo 0)"
  check_bool "infra: no timeout within ${timeout_sec}s" "$( [ "$timed_out" = 0 ] && echo 1 || echo 0)"
  check_bool "infra: exactly one session JSONL (found $jsonl_count)" "$( [ "$jsonl_count" -eq 1 ] && echo 1 || echo 0)"
  check_bool "infra: session JSONL parses as JSON lines" "$jsonl_valid"
  check_bool "infra: actual model is $REQ_PROVIDER/$REQ_MODEL (observed: $(printf '%s' "$actual_models" | tr '\n' ' '))" "$model_ok"
  if [ -n "$REQ_THINKING" ]; then
    check_bool "infra: thinking level is :$REQ_THINKING (observed: ${thinking_observed:-none})" "$thinking_ok"
  fi
  local res_detail="none"
  [ -n "$res_unexpected" ] && res_detail="$(printf '%s\n' "$res_unexpected" | paste -sd, -)"
  check_bool "infra: no unexpected loaded resources (unexpected: $res_detail)" "$resources_ok"
}

# write_usage_json RUN_DIR — usage totals, or the explicit no-JSONL error.
write_usage_json() {
  if [ "$RUN_JSONL_VALID" = 1 ]; then
    grader_usage "$RUN_SESS" >"$1/usage.json"
  else
    printf '{"error":"no valid session JSONL"}\n' >"$1/usage.json"
  fi
}

# write_run_metadata RUN_DIR SUITE SCENARIO RUN ROLE REQUESTED_SPEC [EXTRA_JSON]
# — the shared per-run metadata; EXTRA_JSON (a JSON object) merges in
# suite-specific fields (the baseline adds fingerprint/publication data).
write_run_metadata() {
  local run_dir="$1" suite="$2" scenario="$3" run="$4" role="$5" requested="$6"
  local extra="${7-}"
  [ -n "$extra" ] || extra='{}'
  local pi_version git_commit flags_json
  pi_version="$($EVALS_PI_BIN --version 2>/dev/null | head -n1)"
  git_commit="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf unknown)"
  flags_json=$(printf '%s\n' "${RUN_FLAG_ARGS[@]}" | jq -R . | jq -s .)
  jq -n \
    --arg suite "$suite" --arg scenario "$scenario" --argjson run "$run" --arg role "$role" \
    --arg requestedModel "$requested" --arg provider "$REQ_PROVIDER" --arg model "$REQ_MODEL" \
    --arg thinkingRequested "$REQ_THINKING" --arg thinkingObserved "$RUN_THINKING_OBSERVED" \
    --arg actualModels "$(printf '%s\n' "$RUN_ACTUAL_MODELS")" \
    --argjson timeoutSec "$RUN_TIMEOUT_SEC" --argjson timedOut "$RUN_TIMED_OUT" --argjson exitStatus "$RUN_RC" \
    --arg pi "$EVALS_PI_BIN" --arg piVersion "$pi_version" --arg gitCommit "$git_commit" \
    --arg skillSha "$RUN_SKILL_SHA" --arg workdir "$EVAL_WORKDIR" \
    --argjson loadedResources "$(printf '%s\n' "$RUN_LOADED_RESOURCES" | jq -R -s 'split("\n") | map(select(.!="")) | map(split("\t") | {kind:.[0], name:.[1]})')" \
    --arg startedAt "$RUN_STARTED_AT" --arg endedAt "$RUN_ENDED_AT" --argjson sessionJsonlCount "$RUN_JSONL_COUNT" \
    --argjson flags "$flags_json" \
    --argjson envReset "$(printf '%s\n' "${EVAL_ENV_RESET[@]}" | jq -R . | jq -s .)" \
    --argjson extra "$extra" \
    '{suite:$suite, scenario:$scenario, run:$run, role:$role,
      requestedModel:$requestedModel, provider:$provider, model:$model,
      thinkingRequested:(if $thinkingRequested=="" then null else $thinkingRequested end),
      thinkingObserved:(if $thinkingObserved=="" then null else $thinkingObserved end),
      actualModels:($actualModels|split("\n")|map(select(.!=""))),
      timeoutSec:$timeoutSec, timedOut:$timedOut, exitStatus:$exitStatus,
      pi:$pi, piVersion:$piVersion, gitCommit:$gitCommit,
      skillSha256:$skillSha, workdir:$workdir,
      loadedResources:$loadedResources,
      flags:$flags, envReset:$envReset,
      startedAt:$startedAt, endedAt:$endedAt, sessionJsonlCount:$sessionJsonlCount}
      + $extra' \
    >"$run_dir/metadata.json"
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
  check_bool "$tag: every bash call is a ./2pane helper invocation, standalone or cd-prefixed ($nb bash, $nh helper)" "$v"

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

  fixture_rebuild
  scenario_seed "$scenario"
  cp "$EVAL_WORKDIR/.2pane/INBOX.md" "$run_dir/seed-INBOX.md"
  local prompt
  prompt="$(scenario_prompt "$scenario")"
  printf '%s\n' "$prompt" >"$run_dir/prompt.txt"
  manifest_of "$EVAL_WORKDIR" >"$run_dir/before-manifest.sha256"

  run_pi_once "$run_dir" "$sessions_dir" "$main_spec" "$prompt" "$timeout_sec"

  manifest_of "$EVAL_WORKDIR" >"$run_dir/after-manifest.sha256"

  if [ "$RUN_INFRA" = 1 ]; then
    check_note "# protocol checks skipped: infrastructure failure"
  else
    scenario_checks "$scenario" "$run_dir" "$RUN_SESS"
  fi

  local status
  if [ "$RUN_INFRA" = 1 ]; then
    status="infra-fail"
  elif [ "$CHECK_FAIL" -gt 0 ]; then
    status="protocol-fail"
  else
    status="pass"
  fi
  printf '# classification: %s\n' "$status" >>"$CHECKS_FILE"

  # Artifacts: usage, metadata.
  write_usage_json "$run_dir"
  write_run_metadata "$run_dir" protocol "$scenario" "$k" main "$main_spec" '{}'

  local total ok_n
  ok_n=$(grep -c '^ok - ' "$CHECKS_FILE" || true)
  total=$((ok_n + CHECK_FAIL))
  jq -cn --arg scenario "$scenario" --argjson run "$k" --arg status "$status" \
    --argjson passed "$ok_n" --argjson failed "$CHECK_FAIL" \
    --argjson total "$total" \
    --arg requestedModel "$main_spec" --arg actualModels "$(printf '%s' "$RUN_ACTUAL_MODELS" | tr '\n' ' ')" \
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
# Economy task and baseline cache (ticket 05)
#
# The baseline is the one expensive direct-Expert reference run: the economy
# fixture (helper + exactly the two reviewed docs), one Expert-only pi session
# with the "you are the only agent" mode instruction before the verbatim task,
# graded by the answer-correctness gate shared with E1 plus the no-bypass
# checks. It is published into evals/baselines/<fingerprint>/<baseline-id>/
# only after every gate passes, and reused without model calls while the
# fingerprint matches. The fingerprint deliberately excludes the Main model
# (any cheap Main can reuse an Expert baseline) and the raw git commit (only
# fixture content, via the manifest, invalidates).
# ─────────────────────────────────────────────────────────────────────────────

ECON_TASK_ID="econ-docs-os-lock"
ECON_ASSERT_VERSION="v1"            # bump when TASK_TEXT or its assertions change
EVAL_BASELINE_FORMAT_VERSION="1"    # bump when the baseline artifact layout changes

# Verbatim test data from the spec — do not rephrase.
ECON_TASK_TEXT='Review docs/spec.md and docs/adr/0001-single-slot-inbox.md. Decide whether the
workflow needs OS file locking around its inbox when the human guarantees one
writer at a time. Do not modify files. End your answer with exactly these two
lines:

decision: no-os-lock
invariant: human-single-writer'
ECON_BASELINE_MODE='You are the only agent for this run. Complete the following task yourself and do not use the two-pane inbox.'
ECON_FINAL_LINE1='decision: no-os-lock'
ECON_FINAL_LINE2='invariant: human-single-writer'

econ_task_text() { printf '%s\n' "$ECON_TASK_TEXT"; }

# The mode instruction sits before the task block and never changes the task.
econ_baseline_prompt() { printf '%s\n\n%s\n' "$ECON_BASELINE_MODE" "$ECON_TASK_TEXT"; }

# pinned_env_digest MODEL_SPEC — sha over everything pinned about the run
# environment: the exact pi flags (the per-run session-dir normalized to a
# placeholder), the allowed tool list, and the content hash of every allowed
# resource (the one pinned skill).
pinned_env_digest() {
  {
    eval_pi_flags "$1" "<session-dir>"
    printf 'tools:%s\n' "bash,read"
    printf 'skill-sha256:%s\n' \
      "$($EVAL_SHA256 "$EVAL_WORKDIR/.agents/skills/$EVAL_PINNED_SKILL/SKILL.md" | awk '{print $1}')"
  } | $EVAL_SHA256 | awk '{print $1}'
}

# baseline_fingerprint_preimage EXPERT_SPEC PI_VERSION PROMPT_SHA MANIFEST_SHA
#   PINNED_ENV_SHA — the canonical, line-stable component list the fingerprint
# hashes. The label set is pinned by self-tests; there is deliberately no
# main-model and no git-commit component.
baseline_fingerprint_preimage() {
  printf 'eval-task:%s:%s\nformat:%s\nexpert-model:%s\npi-version:%s\nprompt-sha256:%s\nfixture-manifest-sha256:%s\npinned-env-sha256:%s\n' \
    "$ECON_TASK_ID" "$ECON_ASSERT_VERSION" "$EVAL_BASELINE_FORMAT_VERSION" \
    "$1" "$2" "$3" "$4" "$5"
}

# baseline_fingerprint ...same args — sha256 of the preimage; doubles as the
# baseline store directory name.
baseline_fingerprint() {
  baseline_fingerprint_preimage "$@" | $EVAL_SHA256 | awk '{print $1}'
}

# baseline_active_id FP_DIR — print the active baseline id iff the marker
# exists and points at a complete stored baseline; exit 1 otherwise (missing
# marker, dangling pointer, tampered id, incomplete artifacts).
baseline_active_id() {
  local dir="$1" id f
  id="$(cat "$dir/active" 2>/dev/null)" || return 1
  [ -n "$id" ] || return 1
  case "$id" in
    ''|*[!A-Za-z0-9._-]*|.*|*/*) return 1 ;;
  esac
  for f in session.jsonl answer.txt prompt.txt metadata.json usage.json checks.txt fixture-manifest.sha256; do
    [ -s "$dir/$id/$f" ] || return 1
  done
  printf '%s\n' "$id"
}

# baseline_publish FP_DIR ID RUN_DIR — copy the graded artifacts under an
# immutable id and atomically repoint the active marker (write temp + rename
# in the same directory). Existing baselines are never modified or deleted.
baseline_publish() {
  local fp_dir="$1" id="$2" run_dir="$3"
  local stage
  mkdir -p "$fp_dir"
  stage="$fp_dir/.staging-$$"
  rm -rf "$stage"
  mkdir "$stage"
  cp "$run_dir/session.jsonl" "$run_dir/answer.txt" "$run_dir/prompt.txt" \
    "$run_dir/metadata.json" "$run_dir/usage.json" "$run_dir/checks.txt" "$stage/"
  cp "$run_dir/before-manifest.sha256" "$stage/fixture-manifest.sha256"
  mv "$stage" "$fp_dir/$id"
  printf '%s\n' "$id" >"$fp_dir/.active.tmp.$$"
  mv "$fp_dir/.active.tmp.$$" "$fp_dir/active"
}

# baseline_checks RUN_DIR SESS — Expert-only baseline assertions: the answer
# correctness gate shared with E1 (exact two final lines), the two-pane inbox
# unused (the run is deliberately single-agent), reads scoped to fixture
# files, plus the shared no-bypass checks. Infra gates (model pinning, JSONL
# integrity, resources) already ran in run_pi_once.
baseline_checks() {
  local run_dir="$1" sess="$2"
  local inbox="$EVAL_WORKDIR/.2pane/INBOX.md"
  local consuming="$EVAL_WORKDIR/.2pane/consuming.md"
  local v t

  # 1. Final answer ends with exactly the two decision/invariant lines —
  #    the same correctness assertion E1's Main final answer must pass.
  v=0
  if t="$(grader_final_text "$sess")"; then
    [ "$(printf '%s\n' "$t" | tail -n 2)" = "$ECON_FINAL_LINE1
$ECON_FINAL_LINE2" ] && v=1
  fi
  check_bool "baseline: final answer ends with the exact two lines '$ECON_FINAL_LINE1' / '$ECON_FINAL_LINE2'" "$v"

  # 2. Two-pane inbox unused: no helper invocation at all, inbox still empty,
  #    no leftover consume state.
  v=0
  if [ -z "$(grader_helper_calls "$sess")" ] && [ -f "$inbox" ] \
    && [ ! -s "$inbox" ] && [ ! -e "$consuming" ]; then
    v=1
  fi
  check_bool "baseline: two-pane inbox unused (no ./2pane calls, inbox empty, no consuming.md)" "$v"

  # 3. read only on fixture files (the two docs, the skill).
  v=0
  [ -z "$(grader_reads_outside_fixture "$sess")" ] && v=1
  check_bool "baseline: read tool used only for fixture files" "$v"

  # Shared: forbidden direct runtime access, the economy bash rule (bash is
  # for the helper only — and the helper is forbidden here, so zero bash),
  # and the untouched fixture manifest.
  protocol_checks_common baseline "$run_dir" "$sess"
}

# econ_fingerprint EXPERT_SPEC PROMPT_FILE MANIFEST_FILE — compute the
# baseline fingerprint components from the CURRENT fixture (the caller must
# have rebuilt the economy fixture and written the manifest first; the
# verbatim baseline prompt bytes go to PROMPT_FILE). Sets ECON_FP,
# ECON_PI_VERSION, ECON_PROMPT_SHA, ECON_MANIFEST_SHA, ECON_PINNED_ENV.
# Shared by `baseline` and `economy` so both hash byte-identical components.
econ_fingerprint() {
  local expert_spec="$1" prompt_file="$2" manifest_file="$3"
  econ_baseline_prompt >"$prompt_file"
  ECON_PROMPT_SHA="$($EVAL_SHA256 "$prompt_file" | awk '{print $1}')"
  ECON_PI_VERSION="$($EVALS_PI_BIN --version 2>/dev/null | head -n1)"
  ECON_MANIFEST_SHA="$($EVAL_SHA256 "$manifest_file" | awk '{print $1}')"
  ECON_PINNED_ENV="$(pinned_env_digest "$expert_spec")"
  ECON_FP="$(baseline_fingerprint "$expert_spec" "$ECON_PI_VERSION" \
    "$ECON_PROMPT_SHA" "$ECON_MANIFEST_SHA" "$ECON_PINNED_ENV")"
}

# cmd_baseline --expert-model SPEC [--timeout SEC] [--refresh-baseline] —
# create or reuse the persistent Expert-only baseline. Fingerprint first: a
# valid active baseline short-circuits before any model call; a fresh run is
# published (immutable id, atomic active repoint) only after every gate
# passes. A failed attempt stays in results and never becomes active.
cmd_baseline() {
  local expert_spec="" timeout_sec=$EVAL_DEFAULT_TIMEOUT refresh=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --expert-model)
        [ "$#" -ge 2 ] || eval_die "--expert-model requires a value"
        expert_spec="$2"; shift 2 ;;
      --timeout)
        [ "$#" -ge 2 ] || eval_die "--timeout requires a value"
        timeout_sec="$2"; shift 2 ;;
      --refresh-baseline) refresh=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) eval_die "unknown baseline option: $1" ;;
    esac
  done
  [ -n "$expert_spec" ] || eval_die "baseline requires --expert-model SPEC (provider/model[:thinking])"
  parse_model_spec "$expert_spec"
  case "$timeout_sec" in ''|*[!0-9]*|0) eval_die "--timeout must be a positive integer (seconds)" ;; esac
  command -v jq >/dev/null 2>&1 || eval_die "jq is required"
  [ -f "$REPO_ROOT/docs/spec.md" ] && [ -f "$REPO_ROOT/docs/adr/0001-single-slot-inbox.md" ] \
    || eval_die "economy fixture requires docs/spec.md and docs/adr/0001-single-slot-inbox.md in the checkout"

  local stamp run_root run_dir sessions_dir
  stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  run_root="$EVAL_RESULTS_DIR/$stamp"
  run_dir="$run_root/baseline-r1"
  sessions_dir="$run_dir/sessions"

  trap eval_cleanup EXIT
  trap 'exit 130' INT TERM
  lock_acquire || exit 4
  mkdir -p "$sessions_dir"

  # Rebuild the pristine economy fixture, then hash every fingerprint
  # component from it (prompt bytes, manifest, pinned environment).
  fixture_rebuild_economy
  manifest_of "$EVAL_WORKDIR" >"$run_dir/before-manifest.sha256"
  econ_fingerprint "$expert_spec" "$run_dir/prompt.txt" "$run_dir/before-manifest.sha256"
  local prompt_sha="$ECON_PROMPT_SHA" pi_version="$ECON_PI_VERSION" \
    manifest_sha="$ECON_MANIFEST_SHA" pinned_env="$ECON_PINNED_ENV" fp="$ECON_FP"

  local active_id=""
  if [ "$refresh" != 1 ] && active_id="$(baseline_active_id "$EVAL_BASELINES_DIR/$fp")"; then
    local active_dir="$EVAL_BASELINES_DIR/$fp/$active_id"
    printf 'evals: baseline active: %s\n' "$active_id"
    printf 'evals: baseline store: %s\n' "$active_dir"
    printf 'evals: fingerprint: %s\n' "$fp"
    # Baselines never expire silently: the report always shows when the cached
    # run was made and what it cost, so a stale reference is visible.
    printf 'evals: created: %s\n' "$(jq -r .createdAt "$active_dir/metadata.json" 2>/dev/null || printf unknown)"
    printf 'evals: expert tokens: %s\n' "$(jq -r .totalTokens "$active_dir/usage.json" 2>/dev/null || printf unknown)"
    printf 'evals: reused without a model call (--refresh-baseline forces a new run)\n'
    rm -rf "$run_root"
    lock_release
    return 0
  fi

  CHECKS_FILE="$run_dir/checks.txt"
  CHECK_FAIL=0
  : >"$CHECKS_FILE"

  run_pi_once "$run_dir" "$sessions_dir" "$expert_spec" "$(cat "$run_dir/prompt.txt")" "$timeout_sec"

  manifest_of "$EVAL_WORKDIR" >"$run_dir/after-manifest.sha256"

  if [ "$RUN_INFRA" = 1 ]; then
    check_note "# baseline checks skipped: infrastructure failure"
  else
    baseline_checks "$run_dir" "$RUN_SESS"
  fi

  local status
  if [ "$RUN_INFRA" = 1 ]; then
    status="infra-fail"
  elif [ "$CHECK_FAIL" -gt 0 ]; then
    status="protocol-fail"
  else
    status="pass"
  fi
  printf '# classification: %s\n' "$status" >>"$CHECKS_FILE"

  # Artifacts: usage, final answer (when one exists), metadata with the
  # fingerprint components and publication state.
  write_usage_json "$run_dir"
  local answer_ok=0
  if grader_final_text "$RUN_SESS" >"$run_dir/answer.txt" 2>/dev/null; then
    answer_ok=1
  else
    rm -f "$run_dir/answer.txt"
  fi

  local published=false
  if [ "$status" = pass ] && [ "$answer_ok" = 1 ]; then
    published=true
  fi

  local baseline_id session_sha extra
  baseline_id="bl-$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -tx4 -N4 /dev/urandom | tr -d ' \n')"
  session_sha=""
  if [ -n "$RUN_SESS" ]; then
    session_sha="$($EVAL_SHA256 "$RUN_SESS" | awk '{print $1}')"
  fi
  extra="$(jq -cn \
    --arg fingerprint "$fp" --arg evalTask "$ECON_TASK_ID:$ECON_ASSERT_VERSION" \
    --arg formatVersion "$EVAL_BASELINE_FORMAT_VERSION" --arg expertModel "$expert_spec" \
    --arg piVersion "$pi_version" --arg promptSha256 "$prompt_sha" \
    --arg fixtureManifestSha256 "$manifest_sha" --arg pinnedEnvSha256 "$pinned_env" \
    --arg baselineId "$baseline_id" --arg sessionSha256 "$session_sha" \
    --argjson published "$published" --arg createdAt "$(utc_now)" \
    '{fingerprint:$fingerprint,
      fingerprintComponents:{evalTask:$evalTask, formatVersion:$formatVersion,
        expertModel:$expertModel, piVersion:$piVersion, promptSha256:$promptSha256,
        fixtureManifestSha256:$fixtureManifestSha256, pinnedEnvSha256:$pinnedEnvSha256},
      baselineId:$baselineId, sessionSha256:$sessionSha256, published:$published,
      createdAt:$createdAt}')"
  write_run_metadata "$run_dir" baseline baseline 1 expert "$expert_spec" "$extra"

  if [ "$published" = true ]; then
    baseline_publish "$EVAL_BASELINES_DIR/$fp" "$baseline_id" "$run_dir"
  fi

  local ok_n total
  ok_n=$(grep -c '^ok - ' "$CHECKS_FILE" || true)
  total=$((ok_n + CHECK_FAIL))
  jq -n --arg overall "$status" --arg fingerprint "$fp" --arg baselineId "$baseline_id" \
    --argjson published "$published" --arg requestedModel "$expert_spec" \
    --argjson usage "$(cat "$run_dir/usage.json")" \
    '{suite:"baseline", overall:$overall, fingerprint:$fingerprint,
      baselineId:(if $published then $baselineId else null end),
      published:$published, requestedModel:$requestedModel, usage:$usage}' \
    >"$run_root/summary.json"
  {
    printf 'baseline summary %s\n' "$stamp"
    printf 'requested expert-model: %s\n' "$expert_spec"
    printf 'status: %s\n' "$status"
    printf 'fingerprint: %s\n' "$fp"
    if [ "$published" = true ]; then
      printf 'baseline: %s\n' "$baseline_id"
    else
      printf 'baseline: not published (%s)\n' "$status"
    fi
    jq -r '"expert tokens: \(.usage.totalTokens // 0)  expert cost: \(.usage.cost.total // 0)"' \
      "$run_root/summary.json"
  } >"$run_root/summary.txt"

  printf 'evals: run root: %s\n' "$run_root"
  cat "$CHECKS_FILE"
  printf 'evals: baseline: %s (%s ok, %s not ok)\n' "$status" "$ok_n" "$CHECK_FAIL"
  if [ "$published" = true ]; then
    printf 'evals: baseline published: %s\n' "$baseline_id"
    printf 'evals: baseline store: %s\n' "$EVAL_BASELINES_DIR/$fp/$baseline_id"
  else
    printf 'evals: baseline not published (%s); the failed attempt stays in results\n' "$status"
  fi
  cat "$run_root/summary.txt"
  lock_release

  case "$status" in
    pass) return 0 ;;
    protocol-fail) return 1 ;;
    *) return 3 ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Economy suite — E1 two-pane driver + verdict layer (tickets 06/07)
#
# E1 runs the cheap Main-Model over the economy task with the two-pane
# helper available. The driver is purely a human-router: it never decides
# consultations — after every pi turn it looks at the inbox, and the first
# line routes the next turn (`from: main` → Expert acts, `from: expert` →
# Main acts, empty after a Main turn → the run is over). Main and Expert each
# own ONE session JSONL; every continued turn resumes it via pi --session so
# context and usage accumulate instead of resetting. Expert turns run with
# AGENT_ROLE=expert (the only way ./2pane addresses the right pane). Zero
# consultations is legal and reported as expert-skipped. Rails: overall
# wall-clock timeout and a pi-turn cap — either triggering is infra-fail,
# never a fake saving; nothing limits Expert during the run. The verdict
# layer (07) compares the median summed-Expert-tokens across E1 runs against
# the immutable cached baseline: post-run --min-expert-saving gate, baseline
# reference per result, exploratory flag on single samples, full token+money
# cost report.
# ─────────────────────────────────────────────────────────────────────────────

ECON_MAIN_MODE='Work on the following task as Main. Use the two-pane Expert whenever you think it helps; you may also finish without consulting Expert.'
ECON_EXPERT_TURN_PROMPT='You are the Expert pane of the two-pane workflow. A question from Main is waiting in the inbox: take it with ./2pane take, answer it yourself, and send your complete reply through ./2pane send.'
ECON_MAIN_REPLY_PROMPT='The Expert sent a reply. Check the two-pane workflow for the incoming message with ./2pane take, then finish the task.'
ECON_MAIN_EMPTY_PROMPT='The inbox is empty. Finish the task.'
EVAL_ECON_RUN_TIMEOUT=600
EVAL_ECON_TURN_CAP=8
EVAL_ECON_MIN_SAVING=0
# Zero-usage placeholder for a role that never ran (expert-skipped runs).
ECON_ZERO_USAGE='{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0},"modelCalls":0,"toolCalls":0}'

econ_main_prompt() { printf '%s\n\n%s\n' "$ECON_MAIN_MODE" "$ECON_TASK_TEXT"; }

# econ_median NUM... — the median of the arguments; an even count averages
# the two middle values. Integer arguments produce integer or .5 output.
econ_median() {
  [ "$#" -ge 1 ] || return 1
  printf '%s\n' "$@" | jq -s '
    sort |
    if length % 2 == 1 then .[(length - 1) / 2]
    else ((.[length / 2 - 1] + .[length / 2]) / 2)
    end'
}

# econ_saving_percent SUM BASELINE — expertSavingPercent rounded to two
# decimals: 100 * (1 - median summed Expert tokens / baseline tokens). A
# zero/negative baseline (never published, but guarded) counts as full
# saving only when SUM is also zero.
econ_saving_percent() {
  jq -n --argjson s "$1" --argjson b "$2" '
    (if ($b | tonumber) <= 0 then
       (if ($s | tonumber) == 0 then 100 else 0 end)
     else 100 * (1 - (($s | tonumber) / ($b | tonumber))) end)
    | ((. * 100 | round) / 100)'
}

# econ_inbox_from — the first line of the live inbox ("from: main",
# "from: expert" or empty for an empty/missing inbox).
econ_inbox_from() {
  head -n1 "$EVAL_WORKDIR/.2pane/INBOX.md" 2>/dev/null || true
}

# econ_resolve_baseline PINNED_ID — locate the cached Expert-only baseline for
# the current ECON_FP. Sets BL_ID, BL_DIR, BL_USAGE_JSON, BL_TOTAL_TOKENS,
# BL_COST_TOTAL, BL_SESSION_SHA. Returns 0 when usable, 1 when missing
# (caller reports baseline-missing, exit 6) and 2 when a pinned id exists but
# its stored fingerprint does not match the current one (usage error).
econ_resolve_baseline() {
  local pinned="$1"
  local fp_dir="$EVAL_BASELINES_DIR/$ECON_FP" id=""
  if [ -n "$pinned" ]; then
    id="$pinned"
    [ -s "$fp_dir/$id/metadata.json" ] || return 1
    local stored_fp
    stored_fp="$(jq -r .fingerprint "$fp_dir/$id/metadata.json" 2>/dev/null)"
    [ "$stored_fp" = "$ECON_FP" ] || return 2
  else
    id="$(baseline_active_id "$fp_dir")" || return 1
  fi
  BL_ID="$id"
  BL_DIR="$fp_dir/$id"
  BL_USAGE_JSON="$(cat "$BL_DIR/usage.json" 2>/dev/null)"
  BL_TOTAL_TOKENS="$(jq -r '.totalTokens // 0' <<<"$BL_USAGE_JSON")"
  BL_COST_TOTAL="$(jq -r '.cost.total // 0' <<<"$BL_USAGE_JSON")"
  BL_SESSION_SHA="$(jq -r .sessionSha256 "$BL_DIR/metadata.json" 2>/dev/null)"
  return 0
}

# econ_role_checks TAG SESS SPEC — the assertions shared by both E1 roles:
# helper-only bash with scoped reads, no forbidden runtime access, and the
# model pinned across ALL continued turns of that role's single session.
econ_role_checks() {
  local tag="$1" sess="$2" spec="$3"
  local v nb nh models

  v=0; [ -z "$(grader_forbidden_calls "$sess")" ] && v=1
  check_bool "$tag: no forbidden direct runtime access in tool calls" "$v"

  v=0; [ -z "$(grader_reads_outside_fixture "$sess")" ] && v=1
  check_bool "$tag: read tool used only for fixture files" "$v"

  parse_model_spec "$spec"
  models="$(grader_models_unique "$sess")"
  v=0
  { [ "$(printf '%s\n' "$models" | grep -c .)" = 1 ] \
    && [ "$models" = "$REQ_PROVIDER/$REQ_MODEL" ]; } && v=1
  check_bool "$tag: every continued turn ran $REQ_PROVIDER/$REQ_MODEL (observed: $(printf '%s' "$models" | tr '\n' ' '))" "$v"

  nb=$(grader_bash_calls "$sess" | grep -c . || true)
  nh=$(grader_helper_calls "$sess" | grep -c . || true)
  v=0; [ "${nb:-0}" = "${nh:-0}" ] && v=1
  check_bool "$tag: every bash call is a ./2pane helper invocation, standalone or cd-prefixed ($nb bash, $nh helper)" "$v"
}

# econ_checks_run RUN_DIR MAIN_SPEC EXPERT_SPEC — E1 assertions on the
# completed run: both roles helper-only with scoped reads, models pinned
# across ALL continued turns, the shared answer-correctness gate (exact two
# final lines), the consultation cycle (every Main send answered by exactly
# one Expert take/reply pair that Main consumes), and the untouched fixture.
# Sets E1_ANSWER_OK (0/1). Appends to CHECKS_FILE.
econ_checks_run() {
  local run_dir="$1" main_spec="$2" expert_spec="$3"
  local msess="$run_dir/main-session.jsonl" esess="$run_dir/expert-session.jsonl"
  local v t

  v=0; [ -s "$msess" ] && v=1
  check_bool "E1/main: role session JSONL captured" "$v"

  if [ -s "$msess" ]; then
    econ_role_checks "E1/main" "$msess" "$main_spec"

    # Answer-correctness gate shared with the baseline (E2).
    v=0
    if t="$(grader_final_text "$msess")"; then
      [ "$(printf '%s\n' "$t" | tail -n 2)" = "$ECON_FINAL_LINE1
$ECON_FINAL_LINE2" ] && v=1
    fi
    E1_ANSWER_OK="$v"
    check_bool "E1/main: final answer ends with the exact two lines '$ECON_FINAL_LINE1' / '$ECON_FINAL_LINE2'" "$v"
  else
    E1_ANSWER_OK=0
  fi

  if [ -s "$esess" ]; then
    econ_role_checks "E1/expert" "$esess" "$expert_spec"

    # Consultation cycle: every Main send is taken by Expert exactly once,
    # answered by exactly one Expert send, and consumed by exactly one Main
    # take; take results carry the right `from:` line.
    local c et es mt bad
    c=$(grader_helper_calls "$msess" send | awk -F'\t' '$5=="ok"' | grep -c . || true)
    et=$(grader_helper_calls "$esess" take | awk -F'\t' '$5=="ok"' | grep -c . || true)
    es=$(grader_helper_calls "$esess" send | awk -F'\t' '$5=="ok"' | grep -c . || true)
    mt=$(grader_helper_calls "$msess" take | awk -F'\t' '$5=="ok"' | grep -c . || true)
    v=0; [ "$et" = "$c" ] && v=1
    check_bool "E1/cycle: every one of $c consultations was taken by Expert exactly once (takes: $et)" "$v"
    v=0; [ "$es" = "$c" ] && v=1
    check_bool "E1/cycle: every consultation got exactly one Expert reply (sends: $es)" "$v"
    v=0; [ "$mt" = "$c" ] && v=1
    check_bool "E1/cycle: Main consumed every Expert reply exactly once (takes: $mt)" "$v"
    bad=$(grader_helper_calls "$esess" take | awk -F'\t' '$5=="ok" && $6 !~ /from: main/' | grep -c . || true)
    v=0; [ "${bad:-0}" = 0 ] && v=1
    check_bool "E1/cycle: every ok Expert take returned the message from main" "$v"
    bad=$(grader_helper_calls "$msess" take | awk -F'\t' '$5=="ok" && $6 !~ /from: expert/' | grep -c . || true)
    v=0; [ "${bad:-0}" = 0 ] && v=1
    check_bool "E1/cycle: every ok Main take returned the message from expert" "$v"
  else
    # No Expert session ever started: the zero-consultation outcome. A legal
    # expert-skipped run must show zero consultations on the Main side too.
    v=0; [ "${E1_CONSULTATIONS:-0}" = 0 ] && v=1
    check_bool "E1/cycle: no Expert session and zero consultations recorded (expert-skipped)" "$v"
  fi

  v=0; cmp -s "$run_dir/before-manifest.sha256" "$run_dir/after-manifest.sha256" && v=1
  check_bool "E1: files outside .2pane unchanged across all turns of both roles (manifest equal)" "$v"
}

# econ_drive_one RUN_ROOT MAIN_SPEC EXPERT_SPEC K PER_TIMEOUT RUN_TIMEOUT
#   TURN_CAP BL_REF_JSON — one E1 run: fresh fixture, the human-router loop,
# rails, session capture, grading and the per-run result row. Sets E1_STATUS,
# E1_CONSULTATIONS, E1_EXPERT_SKIPPED, E1_ANSWER_OK, E1_TURNS, E1_WALL_SEC,
# E1_MAIN_USAGE, E1_EXPERT_USAGE, E1_INFRA_REASON. Appends one object to
# RUN_ROOT/.runs.ndjson and writes RUN_DIR/result.json.
econ_drive_one() {
  local run_root="$1" main_spec="$2" expert_spec="$3" k="$4" \
    per_timeout="$5" run_timeout="$6" turn_cap="$7" bl_ref="$8"
  local run_dir="$run_root/e1-r$k"
  local main_sessions="$run_dir/sessions/main" expert_sessions="$run_dir/sessions/expert"
  mkdir -p "$main_sessions" "$expert_sessions"
  CHECKS_FILE="$run_dir/checks.txt"
  CHECK_FAIL=0
  : >"$CHECKS_FILE"

  fixture_rebuild_economy
  : >"$EVAL_WORKDIR/.2pane/INBOX.md"
  cp "$EVAL_WORKDIR/.2pane/INBOX.md" "$run_dir/seed-INBOX.md"
  econ_main_prompt >"$run_dir/prompt.txt"
  printf '%s\n' "$ECON_EXPERT_TURN_PROMPT" >"$run_dir/expert-prompt.txt"
  manifest_of "$EVAL_WORKDIR" >"$run_dir/before-manifest.sha256"

  local start_sec end_sec
  start_sec="$(date +%s)"
  local actor="main" turn=0 main_turns=0 consultations=0 infra_reason=""
  local main_sec=0 expert_sec=0 turn_start
  local main_jsonl="" expert_jsonl="" prompt tdir

  # The human-router loop: rails before every turn, then route on the live
  # inbox state after it. The driver never decides consultations itself.
  while :; do
    local elapsed=$(( $(date +%s) - start_sec ))
    if [ "$elapsed" -ge "$run_timeout" ]; then
      infra_reason="wall-clock run timeout ${run_timeout}s reached"
      break
    fi
    if [ "$turn" -ge "$turn_cap" ]; then
      infra_reason="pi-turn cap ${turn_cap} reached"
      break
    fi
    turn=$((turn + 1))
    turn_start="$(date +%s)"
    tdir="$run_dir/turns/$(printf 'T%02d' "$turn")-$actor"
    mkdir -p "$tdir"

    if [ "$actor" = main ]; then
      main_turns=$((main_turns + 1))
      if [ "$main_turns" = 1 ]; then
        prompt="$(cat "$run_dir/prompt.txt")"
      elif [ "$(econ_inbox_from)" = "from: expert" ]; then
        prompt="$ECON_MAIN_REPLY_PROMPT"
      else
        prompt="$ECON_MAIN_EMPTY_PROMPT"
      fi
      printf '%s\n' "$prompt" >"$tdir/prompt.txt"
      local resumed=false
      [ "$main_turns" -gt 1 ] && resumed=true
      parse_model_spec "$main_spec"
      run_pi_once "$tdir" "$main_sessions" "$main_spec" "$prompt" \
        "$per_timeout" "$main_jsonl" main
      write_usage_json "$tdir"
      write_run_metadata "$tdir" economy e1 "$k" main "$main_spec" \
        "$(jq -cn --argjson turn "$turn" --arg actor main --argjson resumed "$resumed" \
          '{turn:$turn, actor:$actor, resumed:$resumed}')"
      main_jsonl="$(find "$main_sessions" -maxdepth 1 -name '*.jsonl' -type f | LC_ALL=C sort | head -n1)"
      if [ "$RUN_INFRA" = 1 ]; then
        infra_reason="infrastructure failure in main turn $turn"
        break
      fi
      consultations=$(grader_helper_calls "$main_jsonl" send \
        | awk -F'\t' '$5=="ok"' | grep -c . || true)
    else
      prompt="$ECON_EXPERT_TURN_PROMPT"
      printf '%s\n' "$prompt" >"$tdir/prompt.txt"
      local resumed=false
      [ -n "$expert_jsonl" ] && resumed=true
      parse_model_spec "$expert_spec"
      run_pi_once "$tdir" "$expert_sessions" "$expert_spec" "$prompt" \
        "$per_timeout" "$expert_jsonl" expert
      write_usage_json "$tdir"
      write_run_metadata "$tdir" economy e1 "$k" expert "$expert_spec" \
        "$(jq -cn --argjson turn "$turn" --arg actor expert --argjson resumed "$resumed" \
          '{turn:$turn, actor:$actor, resumed:$resumed}')"
      expert_jsonl="$(find "$expert_sessions" -maxdepth 1 -name '*.jsonl' -type f | LC_ALL=C sort | head -n1)"
      if [ "$RUN_INFRA" = 1 ]; then
        infra_reason="infrastructure failure in expert turn $turn"
        break
      fi
    fi

    # Per-role duration: charge the finished turn to the role that ran it.
    if [ "$actor" = main ]; then
      main_sec=$((main_sec + $(date +%s) - turn_start))
    else
      expert_sec=$((expert_sec + $(date +%s) - turn_start))
    fi

    case "$(econ_inbox_from)" in
      "from: main") actor="expert" ;;
      "from: expert") actor="main" ;;
      "")
        if [ "$actor" = main ]; then
          break
        fi
        actor="main" ;;
      *)
        infra_reason="inbox left in an unexpected state after turn $turn"
        break ;;
    esac
  done

  end_sec="$(date +%s)"
  E1_TURNS="$turn"
  E1_WALL_SEC="$((end_sec - start_sec))"
  E1_MAIN_SEC="$main_sec"
  E1_EXPERT_SEC="$expert_sec"
  E1_CONSULTATIONS="${consultations:-0}"
  E1_INFRA_REASON="$infra_reason"

  if [ -n "$infra_reason" ]; then
    check_note "not ok - rail: $infra_reason"
  else
    check_note "ok - rail: completed within wall-clock ${run_timeout}s and turn cap ${turn_cap}"
  fi

  # Capture each role's single session as a stable artifact.
  E1_EXPERT_SKIPPED=1
  if [ -n "$expert_jsonl" ] && [ -s "$expert_jsonl" ]; then
    cp "$expert_jsonl" "$run_dir/expert-session.jsonl"
    E1_EXPERT_SKIPPED=0
  fi
  if [ -n "$main_jsonl" ] && [ -s "$main_jsonl" ]; then
    cp "$main_jsonl" "$run_dir/main-session.jsonl"
  fi
  manifest_of "$EVAL_WORKDIR" >"$run_dir/after-manifest.sha256"

  E1_ANSWER_OK=0
  if [ -n "$infra_reason" ]; then
    check_note "# E1 checks skipped: infrastructure failure"
  else
    econ_checks_run "$run_dir" "$main_spec" "$expert_spec"
  fi

  local status
  if [ -n "$infra_reason" ]; then
    status="infra-fail"
  elif [ "$CHECK_FAIL" -gt 0 ]; then
    status="protocol-fail"
  else
    status="pass"
  fi
  E1_STATUS="$status"
  printf '# classification: %s\n' "$status" >>"$CHECKS_FILE"

  if [ -s "$run_dir/main-session.jsonl" ]; then
    E1_MAIN_USAGE="$(grader_usage "$run_dir/main-session.jsonl")"
  else
    E1_MAIN_USAGE="$ECON_ZERO_USAGE"
  fi
  if [ -s "$run_dir/expert-session.jsonl" ]; then
    E1_EXPERT_USAGE="$(grader_usage "$run_dir/expert-session.jsonl")"
  else
    E1_EXPERT_USAGE="$ECON_ZERO_USAGE"
  fi

  jq -n --argjson run "$k" --arg status "$status" \
    --argjson consultations "$E1_CONSULTATIONS" --argjson turns "$E1_TURNS" \
    --argjson expertSkipped "$E1_EXPERT_SKIPPED" --argjson answerOk "$E1_ANSWER_OK" \
    --argjson wallSeconds "$E1_WALL_SEC" --arg infraReason "$infra_reason" \
    --argjson mainSeconds "$E1_MAIN_SEC" --argjson expertSeconds "$E1_EXPERT_SEC" \
    --argjson mainUsage "$E1_MAIN_USAGE" --argjson expertUsage "$E1_EXPERT_USAGE" \
    --argjson baselineRef "$bl_ref" \
    '{scenario:"e1", run:$run, status:$status, consultations:$consultations,
      turns:$turns, expertSkipped:($expertSkipped==1), correctAnswer:($answerOk==1),
      wallSeconds:$wallSeconds, mainSeconds:$mainSeconds, expertSeconds:$expertSeconds,
      infraReason:(if $infraReason=="" then null else $infraReason end),
      mainUsage:$mainUsage, expertUsage:$expertUsage, baselineRef:$baselineRef}' \
    >"$run_dir/result.json"

  jq -cn --argjson run "$k" --arg status "$status" \
    --argjson consultations "$E1_CONSULTATIONS" \
    --argjson expertSkipped "$E1_EXPERT_SKIPPED" --argjson answerOk "$E1_ANSWER_OK" \
    --argjson mainTokens "$(jq '.totalTokens // 0' <<<"$E1_MAIN_USAGE")" \
    --argjson mainCost "$(jq '.cost.total // 0' <<<"$E1_MAIN_USAGE")" \
    --argjson expertTokens "$(jq '.totalTokens // 0' <<<"$E1_EXPERT_USAGE")" \
    --argjson expertCost "$(jq '.cost.total // 0' <<<"$E1_EXPERT_USAGE")" \
    '{scenario:"e1", run:$run, status:$status, consultations:$consultations,
      expertSkipped:($expertSkipped==1), correctAnswer:($answerOk==1),
      mainTokens:$mainTokens, mainCost:$mainCost,
      expertTokens:$expertTokens, expertCost:$expertCost}' \
    >>"$run_root/.runs.ndjson"

  local ok_n
  ok_n=$(grep -c '^ok - ' "$CHECKS_FILE" || true)
  printf 'evals: e1-r%s: %s (%s ok, %s not ok, %s turns, %s consultations)\n' \
    "$k" "$status" "$ok_n" "$CHECK_FAIL" "$E1_TURNS" "$E1_CONSULTATIONS"
}

# cmd_economy --main-model SPEC --expert-model SPEC [options] — resolve the
# cached baseline (baseline-missing exits 6 BEFORE any model call), run the
# E1 driver per repeat, then apply the verdict layer: median summed-Expert-
# tokens saving vs the immutable baseline, post-run --min-expert-saving
# gate, exploratory flag on single samples, full cost report.
cmd_economy() {
  local main_spec="" expert_spec="" runs=1 timeout_sec=$EVAL_DEFAULT_TIMEOUT \
    run_timeout=$EVAL_ECON_RUN_TIMEOUT turn_cap=$EVAL_ECON_TURN_CAP \
    min_saving=$EVAL_ECON_MIN_SAVING baseline_pin=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --main-model)
        [ "$#" -ge 2 ] || eval_die "--main-model requires a value"
        main_spec="$2"; shift 2 ;;
      --expert-model)
        [ "$#" -ge 2 ] || eval_die "--expert-model requires a value"
        expert_spec="$2"; shift 2 ;;
      --runs)
        [ "$#" -ge 2 ] || eval_die "--runs requires a value"
        runs="$2"; shift 2 ;;
      --timeout)
        [ "$#" -ge 2 ] || eval_die "--timeout requires a value"
        timeout_sec="$2"; shift 2 ;;
      --run-timeout)
        [ "$#" -ge 2 ] || eval_die "--run-timeout requires a value"
        run_timeout="$2"; shift 2 ;;
      --turn-cap)
        [ "$#" -ge 2 ] || eval_die "--turn-cap requires a value"
        turn_cap="$2"; shift 2 ;;
      --min-expert-saving)
        [ "$#" -ge 2 ] || eval_die "--min-expert-saving requires a value"
        min_saving="$2"; shift 2 ;;
      --baseline-id)
        [ "$#" -ge 2 ] || eval_die "--baseline-id requires a value"
        baseline_pin="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) eval_die "unknown economy option: $1" ;;
    esac
  done
  [ -n "$main_spec" ] || eval_die "economy requires --main-model SPEC (provider/model[:thinking])"
  [ -n "$expert_spec" ] || eval_die "economy requires --expert-model SPEC (provider/model[:thinking])"
  parse_model_spec "$main_spec"
  parse_model_spec "$expert_spec"
  case "$runs" in ''|*[!0-9]*|0) eval_die "--runs must be a positive integer" ;; esac
  case "$timeout_sec" in ''|*[!0-9]*|0) eval_die "--timeout must be a positive integer (seconds)" ;; esac
  case "$run_timeout" in ''|*[!0-9]*|0) eval_die "--run-timeout must be a positive integer (seconds)" ;; esac
  case "$turn_cap" in ''|*[!0-9]*|0) eval_die "--turn-cap must be a positive integer" ;; esac
  awk -v x="$min_saving" 'BEGIN { if (x ~ /^-?[0-9]+([.][0-9]+)?$/) exit 0; exit 1 }' \
    || eval_die "--min-expert-saving must be a number (percent)"
  command -v jq >/dev/null 2>&1 || eval_die "jq is required"
  [ -f "$REPO_ROOT/docs/spec.md" ] && [ -f "$REPO_ROOT/docs/adr/0001-single-slot-inbox.md" ] \
    || eval_die "economy fixture requires docs/spec.md and docs/adr/0001-single-slot-inbox.md in the checkout"

  local stamp run_root
  stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  run_root="$EVAL_RESULTS_DIR/$stamp"

  trap eval_cleanup EXIT
  trap 'exit 130' INT TERM
  lock_acquire || exit 4
  mkdir -p "$run_root"
  : >"$run_root/.runs.ndjson"

  # Fingerprint from the freshly rebuilt economy fixture — byte-identical to
  # what `baseline` computes — then resolve the cached baseline BEFORE any
  # model call: baseline-missing exits 6 without spending tokens.
  fixture_rebuild_economy
  manifest_of "$EVAL_WORKDIR" >"$run_root/fixture-manifest.sha256"
  econ_fingerprint "$expert_spec" "$run_root/baseline-prompt.txt" \
    "$run_root/fixture-manifest.sha256"

  local rres=0
  econ_resolve_baseline "$baseline_pin" || rres=$?
  if [ "$rres" = 2 ]; then
    eval_die "--baseline-id $baseline_pin exists but its stored fingerprint does not match the current one ($ECON_FP); drop the pin or create a matching baseline"
  elif [ "$rres" != 0 ]; then
    printf 'evals: baseline-missing: no cached Expert-only baseline for fingerprint %s\n' "$ECON_FP" >&2
    printf 'evals: create one first (this spends the one expensive Expert-only run):\n' >&2
    printf 'evals:   evals/run.sh baseline --expert-model %s\n' "$expert_spec" >&2
    rm -rf "$run_root"
    lock_release
    exit 6
  fi

  printf 'evals: run root: %s\n' "$run_root"
  printf 'evals: baseline active: %s\n' "$BL_ID"
  printf 'evals: fingerprint: %s\n' "$ECON_FP"

  # The immutable baseline reference carried by every economy result: id,
  # fingerprint, raw-session hash and a usage snapshot.
  jq -n --arg id "$BL_ID" --arg fp "$ECON_FP" --arg sha "$BL_SESSION_SHA" \
    --argjson usage "$BL_USAGE_JSON" \
    '{id:$id, fingerprint:$fp, sessionSha256:(if $sha=="" then null else $sha end),
      totalTokens:($usage.totalTokens // 0), costTotal:($usage.cost.total // 0),
      usage:$usage}' >"$run_root/baseline-ref.json"
  local bl_ref
  bl_ref="$(cat "$run_root/baseline-ref.json")"

  local k any_infra=0 any_protocol=0
  for ((k = 1; k <= runs; k++)); do
    econ_drive_one "$run_root" "$main_spec" "$expert_spec" "$k" \
      "$timeout_sec" "$run_timeout" "$turn_cap" "$bl_ref"
    case "$E1_STATUS" in
      infra-fail) any_infra=1 ;;
      protocol-fail) any_protocol=1 ;;
    esac
  done

  lock_release

  # Verdict layer: median summed-Expert-tokens across valid E1 runs vs the
  # single immutable baseline count. The gate is strictly post-run.
  local n_valid median_expert="" saving="" verdict="" gate_correct=0
  n_valid=$(jq -s '[.[] | select(.status != "infra-fail")] | length' "$run_root/.runs.ndjson")
  if [ "$n_valid" -gt 0 ]; then
    local -a vals=()
    while IFS= read -r line; do vals+=("$line"); done \
      < <(jq -r 'select(.status != "infra-fail") | .expertTokens' "$run_root/.runs.ndjson")
    median_expert="$(econ_median "${vals[@]}")"
    saving="$(econ_saving_percent "$median_expert" "$BL_TOTAL_TOKENS")"
    gate_correct=$(jq -s '[.[] | select(.status != "infra-fail")
      | select(.status == "pass" and .correctAnswer)] | length' "$run_root/.runs.ndjson")
    verdict="economy-fail"
    if [ "$gate_correct" = "$n_valid" ] \
      && awk -v s="$saving" -v m="$min_saving" 'BEGIN { exit !(s >= m) }'; then
      verdict="pass"
    fi
  fi

  local overall overall_rc=0
  if [ "$any_infra" = 1 ]; then
    overall="infra-fail" overall_rc=3
  elif [ "$any_protocol" = 1 ]; then
    overall="protocol-fail" overall_rc=1
  elif [ "$verdict" = economy-fail ]; then
    overall="economy-fail" overall_rc=5
  elif [ -z "$verdict" ]; then
    overall="infra-fail" overall_rc=3
  else
    overall="pass"
  fi

  # Full cost picture in both token and money terms.
  local totals
  totals="$(jq -s '{mainTokens:(map(.mainTokens)|add//0), mainCost:(map(.mainCost)|add//0),
                   expertTokens:(map(.expertTokens)|add//0), expertCost:(map(.expertCost)|add//0)}' \
    "$run_root/.runs.ndjson")"
  totals="$(jq -n --argjson a "$totals" --argjson b "$bl_ref" '$a
    + {e1Cost:(($a.mainCost//0)+($a.expertCost//0)),
       baselineTokens:($b.totalTokens//0), baselineCost:($b.costTotal//0),
       expertTokenShare:(if (($a.mainTokens//0)+($a.expertTokens//0)) > 0
         then (((($a.expertTokens//0)/(($a.mainTokens//0)+($a.expertTokens//0)))*10000|round)/100) else 0 end),
       expertCostShare:(if (($a.mainCost//0)+($a.expertCost//0)) > 0
         then (((($a.expertCost//0)/(($a.mainCost//0)+($a.expertCost//0)))*10000|round)/100) else 0 end)}')"

  jq -s \
    --arg overall "$overall" --arg verdict "$verdict" \
    --arg mainModel "$main_spec" --arg expertModel "$expert_spec" \
    --argjson exploratory "$([ "$runs" = 1 ] && echo true || echo false)" \
    --argjson medianExpert "${median_expert:-null}" \
    --argjson saving "${saving:-null}" \
    --argjson minSaving "$min_saving" \
    --argjson baseline "$bl_ref" --argjson totals "$totals" \
    '{suite:"economy", overall:$overall,
      economyVerdict:(if $verdict=="" then null else $verdict end),
      mainModel:$mainModel, expertModel:$expertModel,
      runs:length, exploratory:$exploratory,
      medianExpertTokens:$medianExpert, expertSavingPercent:$saving,
      minExpertSaving:$minSaving, baseline:$baseline, totals:$totals,
      runResults:(map({run,status,consultations,expertSkipped,correctAnswer,
                       mainTokens,mainCost,expertTokens,expertCost}))}' \
    "$run_root/.runs.ndjson" >"$run_root/summary.json"

  {
    printf 'economy summary %s\n' "$stamp"
    printf 'main=%s  expert=%s\n' "$main_spec" "$expert_spec"
    printf 'baseline: %s (fingerprint %s)\n' "$BL_ID" "$ECON_FP"
    printf 'baseline expert tokens: %s  cost: %s\n' "$BL_TOTAL_TOKENS" "$BL_COST_TOTAL"
    jq -r '.runResults[]
      | "e1-r\(.run): \(.status)"
      + (if .expertSkipped then ", expert-skipped (0 consultations)"
         else ", \(.consultations) consultation\(if .consultations==1 then "" else "s" end)" end)
      + ", main \(.mainTokens) tok / \(.mainCost)"
      + (if .expertSkipped then ", expert 0 tok / 0" else ", expert \(.expertTokens) tok / \(.expertCost)" end)' \
      "$run_root/summary.json"
    if [ -n "$median_expert" ]; then
      printf 'median expert tokens: %s (across %s valid run%s)\n' \
        "$median_expert" "$n_valid" "$([ "$n_valid" = 1 ] || printf s)"
      printf 'expert saving: %s%% (threshold %s%%)%s\n' "$saving" "$min_saving" \
        "$([ "$runs" = 1 ] && printf ' [exploratory: single run]')"
      printf 'expert share of E1: tokens %s%%, cost %s%%\n' \
        "$(jq -r .expertTokenShare <<<"$totals")" "$(jq -r .expertCostShare <<<"$totals")"
    fi
    jq -r '"totals: E1 main \(.totals.mainTokens) tok / \(.totals.mainCost), " +
      "E1 expert \(.totals.expertTokens) tok / \(.totals.expertCost), " +
      "E1 combined \(.totals.e1Cost), baseline \(.totals.baselineTokens) tok / \(.totals.baselineCost)"' \
      "$run_root/summary.json"
    printf 'verdict: %s\n' "${verdict:-n/a}"
    printf 'overall: %s\n' "$overall"
  } >"$run_root/summary.txt"

  for ((k = 1; k <= runs; k++)); do
    cat "$run_root/e1-r$k/checks.txt" 2>/dev/null || true
  done
  cat "$run_root/summary.txt"

  return "$overall_rc"
}

# ─────────────────────────────────────────────────────────────────────────────
# Self-test: synthetic fixtures, zero model calls
# ─────────────────────────────────────────────────────────────────────────────

self_test() {
  command -v jq >/dev/null 2>&1 || { echo 'not ok - jq is required' >&2; exit 1; }
  # Deliberately not local: the EXIT trap below runs after this function's
  # scope is gone and must still see TMP to clean it up.
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

  # F8: resources clean — the pinned workflow skill read via a relative
  # path (progressive disclosure), nothing else loaded.
  cat >"$TMP/res-clean.jsonl" <<'EOF'
{"type":"session","version":3,"timestamp":"2026-08-22T00:00:00.000Z","cwd":"/tmp/2pane-workflow-eval-workdir"}
{"type":"message","id":"e1","parentId":null,"timestamp":"2026-08-22T00:00:00.200Z","message":{"role":"user","timestamp":"2026-08-22T00:00:00.200Z","content":[{"type":"text","text":"prompt"}]}}
{"type":"message","id":"e2","parentId":"e1","timestamp":"2026-08-22T00:00:01.000Z","message":{"role":"assistant","provider":"openai-codex","model":"gpt-5.6-luna","stopReason":"toolUse","timestamp":"2026-08-22T00:00:01.000Z","content":[{"type":"toolCall","id":"r1","name":"read","arguments":{"path":".agents/skills/two-pane-workflow/SKILL.md"}}]}}
{"type":"message","id":"e3","parentId":"e2","timestamp":"2026-08-22T00:00:02.000Z","message":{"role":"toolResult","toolCallId":"r1","toolName":"read","isError":false,"content":[{"type":"text","text":"skill body"}]}}
EOF

  # F9: resources dirty — an unexpected skill read (absolute path), a custom
  # entry and a custom_message entry written by a slipped-in extension.
  cat >"$TMP/res-dirty.jsonl" <<'EOF'
{"type":"session","version":3,"timestamp":"2026-08-22T00:00:00.000Z","cwd":"/tmp/2pane-workflow-eval-workdir"}
{"type":"message","id":"e1","parentId":null,"timestamp":"2026-08-22T00:00:00.200Z","message":{"role":"user","timestamp":"2026-08-22T00:00:00.200Z","content":[{"type":"text","text":"prompt"}]}}
{"type":"message","id":"e2","parentId":"e1","timestamp":"2026-08-22T00:00:01.000Z","message":{"role":"assistant","provider":"openai-codex","model":"gpt-5.6-luna","stopReason":"toolUse","timestamp":"2026-08-22T00:00:01.000Z","content":[{"type":"toolCall","id":"r1","name":"read","arguments":{"path":"/tmp/2pane-workflow-eval-workdir/.agents/skills/sneaky-skill/SKILL.md"}},{"type":"toolCall","id":"b1","name":"bash","arguments":{"command":"./2pane take"}}]}}
{"type":"message","id":"e3","parentId":"e2","timestamp":"2026-08-22T00:00:02.000Z","message":{"role":"toolResult","toolCallId":"r1","toolName":"read","isError":false,"content":[{"type":"text","text":"sneaky body"}]}}
{"type":"custom","id":"x1","parentId":"e3","timestamp":"2026-08-22T00:00:02.500Z","customType":"sneaky-extension","data":{"count":1}}
{"type":"custom_message","id":"x2","parentId":"x1","timestamp":"2026-08-22T00:00:02.600Z","customType":"sneaky-extension","content":"injected context","display":true}
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

  # F5b: cd-prefixed helper calls — an inert `cd DIR &&` prefix is graded on
  # the helper it runs (observed live: models spelling the call
  # `cd <workdir> && ./2pane send ...`); everything else stays strict: the
  # helper must be the LAST segment, pipes/other commands still reject, and
  # a quoted && inside helper args is data, not a chain.
  cat >"$TMP/cd-prefix.jsonl" <<'EOF'
{"type":"session","version":3,"timestamp":"2026-08-22T00:00:00.000Z","cwd":"/tmp/2pane-workflow-eval-workdir"}
{"type":"message","id":"e1","parentId":null,"timestamp":"2026-08-22T00:00:00.200Z","message":{"role":"user","timestamp":"2026-08-22T00:00:00.200Z","content":[{"type":"text","text":"Send a question."}]}}
{"type":"message","id":"e2","parentId":"e1","timestamp":"2026-08-22T00:00:01.000Z","message":{"role":"assistant","api":"openai-responses","provider":"openai-codex","model":"gpt-5.6-luna","responseId":"resp_1","stopReason":"toolUse","timestamp":"2026-08-22T00:00:01.000Z","content":[{"type":"toolCall","id":"call_H1|fc_020","name":"bash","arguments":{"command":"cd /tmp/2pane-workflow-eval-workdir && ./2pane send 'question'"}},{"type":"toolCall","id":"call_H2|fc_021","name":"bash","arguments":{"command":"cd '/tmp/2pane-workflow-eval-workdir' && cd . && ./2pane take"}},{"type":"toolCall","id":"call_H3|fc_022","name":"bash","arguments":{"command":"cd /tmp/x && ./2pane send 'a && b'"}},{"type":"toolCall","id":"call_H4|fc_023","name":"bash","arguments":{"command":"cd /tmp/x && ./2pane send 'q' | tee /tmp/log"}},{"type":"toolCall","id":"call_H5|fc_024","name":"bash","arguments":{"command":"cd /tmp/x && ls && ./2pane take"}},{"type":"toolCall","id":"call_H6|fc_025","name":"bash","arguments":{"command":"cd /tmp/x && ./2pane take && ls -la"}},{"type":"toolCall","id":"call_H7|fc_026","name":"bash","arguments":{"command":"cd /tmp/x && ./2pane status"}}],"usage":{"input":100,"output":10,"cacheRead":0,"cacheWrite":0,"totalTokens":110,"cost":{"input":0.01,"output":0.001,"cacheRead":0,"cacheWrite":0,"total":0.011}}}}
EOF

  expect_eq "cd-prefix: inert cd && helper counts as the helper it ran" \
    "$(grader_helper_calls "$TMP/cd-prefix.jsonl" | wc -l | tr -d ' ')" "3"
  expect_eq "cd-prefix: subcommands in JSONL order (quoted && stays data)" \
    "$(grader_helper_calls "$TMP/cd-prefix.jsonl" | cut -f3 | tr '\n' ' ')" "send take send "
  expect_eq "cd-prefix: piped helper still rejected" \
    "$(grader_helper_calls "$TMP/cd-prefix.jsonl" | grep -c 'call_H4' || true)" "0"
  expect_eq "cd-prefix: non-cd middle segment still rejected" \
    "$(grader_helper_calls "$TMP/cd-prefix.jsonl" | grep -c 'call_H5' || true)" "0"
  expect_eq "cd-prefix: helper must be the last segment" \
    "$(grader_helper_calls "$TMP/cd-prefix.jsonl" | grep -c 'call_H6' || true)" "0"
  expect_eq "cd-prefix: cd-prefixed non-send/take still rejected" \
    "$(grader_helper_calls "$TMP/cd-prefix.jsonl" | grep -c 'call_H7' || true)" "0"

  # The defense-in-depth pair: `cd …/.2pane && ./2pane take` passes the
  # helper-shape rule (cd prefix + standalone helper) — the forbidden-path
  # scan over serialized arguments is what catches it.
  cat >"$TMP/cd-dot2pane.jsonl" <<'EOF'
{"type":"message","id":"e2","parentId":null,"timestamp":"2026-08-22T00:00:01.000Z","message":{"role":"assistant","provider":"openai-codex","model":"gpt-5.6-luna","stopReason":"toolUse","timestamp":"2026-08-22T00:00:01.000Z","content":[{"type":"toolCall","id":"call_H8|fc_027","name":"bash","arguments":{"command":"cd /tmp/2pane-workflow-eval-workdir/.2pane && ./2pane take"}}]}}
EOF
  expect_eq "cd-prefix: cd-into-.2pane has helper shape" \
    "$(grader_helper_calls "$TMP/cd-dot2pane.jsonl" | grep -c 'call_H8' || true)" "1"
  expect_eq "cd-prefix: cd-into-.2pane still forbidden by the args scan" \
    "$(grader_forbidden_calls "$TMP/cd-dot2pane.jsonl" | grep -c 'call_H8' || true)" "1"\

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

  # ── loaded-resource extraction (ticket 04) ──
  expect_eq "res-clean: pinned skill read is extracted" \
    "$(grader_loaded_resources "$TMP/res-clean.jsonl")" "skill-read	two-pane-workflow"
  expect_eq "res-clean: nothing unexpected for the pinned skill" \
    "$(unexpected_resources "$(grader_loaded_resources "$TMP/res-clean.jsonl")" two-pane-workflow)" ""
  local res_dirty
  res_dirty="$(grader_loaded_resources "$TMP/res-dirty.jsonl")"
  expect_eq "res-dirty: skill read, custom and custom_message all extracted" \
    "$(printf '%s\n' "$res_dirty" | grep -c . || true)" "3"
  expect_eq "res-dirty: unexpected filter keeps all three" \
    "$(unexpected_resources "$res_dirty" two-pane-workflow | grep -c . || true)" "3"
  expect_eq "res-dirty: bash helper calls are not resources" \
    "$(printf '%s\n' "$res_dirty" | grep -c bash || true)" "0"
  expect_eq "ok-send: no resources extracted from a bare helper session" \
    "$(grader_loaded_resources "$TMP/ok-send.jsonl" | grep -c . || true)" "0"

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

  # Violation matrix (ticket 04): one stub switched by a mode file next to
  # it. Every mode fabricates a mostly-compliant S1 session and injects
  # exactly one harness-level violation; proves the infra taxonomy and the
  # negative detections with zero model calls.
  cat >"$TMP/pi-violate" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then printf 'stub-pi 0.0.0\n'; exit 0; fi
sessdir="" prev=""
for a in "$@"; do
  [ "$prev" = "--session-dir" ] && sessdir="$a"
  prev="$a"
done
mode="$(cat "$(dirname "$0")/mode")"
case "$mode" in
  invalid-jsonl)
    printf 'this is not json {\n' >"$sessdir/a.jsonl"; exit 0 ;;
  dup-jsonl)
    printf '{"type":"session","version":3,"id":"x","timestamp":"2026-08-22T00:00:00.000Z","cwd":"/tmp"}\n' >"$sessdir/a.jsonl"
    cp "$sessdir/a.jsonl" "$sessdir/b.jsonl"; exit 0 ;;
esac
prov=openai-codex mid=gpt-5.6-luna
[ "$mode" = model-mismatch ] && mid=gpt-5.6-sol
if [ "$mode" = direct-write ]; then
  printf 'from: main\n\nDirect write: does SQLite WAL mode prevent reader/writer locking?\n' >.2pane/INBOX.md
else
  ./2pane send 'Does SQLite WAL mode prevent reader/writer locking?' >/dev/null
fi
[ "$mode" = tamper ] && printf 'tampered\n' >>.gitignore
{
  printf '{"type":"session","version":3,"id":"v","timestamp":"2026-08-22T00:00:00.000Z","cwd":"/tmp/2pane-workflow-eval-workdir"}\n'
  printf '{"type":"model_change","id":"m1","parentId":null,"timestamp":"2026-08-22T00:00:00.100Z","provider":"%s","modelId":"%s"}\n' "$prov" "$mid"
  printf '{"type":"message","id":"e1","parentId":"m1","timestamp":"2026-08-22T00:00:00.200Z","message":{"role":"user","timestamp":"2026-08-22T00:00:00.200Z","content":[{"type":"text","text":"prompt"}]}}\n'
  printf '{"type":"message","id":"e2","parentId":"e1","timestamp":"2026-08-22T00:00:00.500Z","message":{"role":"assistant","provider":"%s","model":"%s","stopReason":"toolUse","timestamp":"2026-08-22T00:00:00.500Z","content":[{"type":"toolCall","id":"c1","name":"read","arguments":{"path":"/tmp/2pane-workflow-eval-workdir/.agents/skills/two-pane-workflow/SKILL.md"}}],"usage":{"input":50,"output":5,"totalTokens":55,"cost":{"total":0.005}}}}\n' "$prov" "$mid"
  printf '{"type":"message","id":"e3","parentId":"e2","timestamp":"2026-08-22T00:00:00.600Z","message":{"role":"toolResult","toolCallId":"c1","toolName":"read","isError":false,"content":[{"type":"text","text":"skill body"}]}}\n'
  if [ "$mode" = skill-resource ]; then
    printf '{"type":"message","id":"e4","parentId":"e3","timestamp":"2026-08-22T00:00:00.700Z","message":{"role":"assistant","provider":"%s","model":"%s","stopReason":"toolUse","timestamp":"2026-08-22T00:00:00.700Z","content":[{"type":"toolCall","id":"c0","name":"read","arguments":{"path":"/tmp/2pane-workflow-eval-workdir/.agents/skills/sneaky-skill/SKILL.md"}}],"usage":{"input":50,"output":5,"totalTokens":55,"cost":{"total":0.005}}}}\n' "$prov" "$mid"
    printf '{"type":"message","id":"e5","parentId":"e4","timestamp":"2026-08-22T00:00:00.800Z","message":{"role":"toolResult","toolCallId":"c0","toolName":"read","isError":false,"content":[{"type":"text","text":"sneaky body"}]}}\n'
  fi
  if [ "$mode" = direct-write ]; then
    printf '{"type":"message","id":"e6","parentId":"e3","timestamp":"2026-08-22T00:00:01.000Z","message":{"role":"assistant","provider":"%s","model":"%s","stopReason":"toolUse","timestamp":"2026-08-22T00:00:01.000Z","content":[{"type":"toolCall","id":"c2","name":"bash","arguments":{"command":"printf %s > .2pane/INBOX.md"}}],"usage":{"input":100,"output":10,"totalTokens":110,"cost":{"total":0.01}}}}\n' "$prov" "$mid"
    printf '{"type":"message","id":"e7","parentId":"e6","timestamp":"2026-08-22T00:00:02.000Z","message":{"role":"toolResult","toolCallId":"c2","toolName":"bash","isError":false,"content":[{"type":"text","text":""}]}}\n'
  else
    printf '{"type":"message","id":"e6","parentId":"e3","timestamp":"2026-08-22T00:00:01.000Z","message":{"role":"assistant","provider":"%s","model":"%s","stopReason":"toolUse","timestamp":"2026-08-22T00:00:01.000Z","content":[{"type":"toolCall","id":"c2","name":"bash","arguments":{"command":"./2pane send %s"}}],"usage":{"input":100,"output":10,"totalTokens":110,"cost":{"total":0.01}}}}\n' "$prov" "$mid" "'Does SQLite WAL mode prevent reader/writer locking?'"
    printf '{"type":"message","id":"e7","parentId":"e6","timestamp":"2026-08-22T00:00:02.000Z","message":{"role":"toolResult","toolCallId":"c2","toolName":"bash","isError":false,"content":[{"type":"text","text":"sent as main"}]}}\n'
  fi
  [ "$mode" = custom-resource ] && printf '{"type":"custom","id":"x1","parentId":"e7","timestamp":"2026-08-22T00:00:02.500Z","customType":"sneaky-extension","data":{}}\n'
  if [ "$mode" = model-change ]; then
    printf '{"type":"model_change","id":"m2","parentId":"e7","timestamp":"2026-08-22T00:00:02.600Z","provider":"openai-codex","modelId":"gpt-5.6-sol"}\n'
    printf '{"type":"message","id":"e8","parentId":"m2","timestamp":"2026-08-22T00:00:03.000Z","message":{"role":"assistant","provider":"openai-codex","model":"gpt-5.6-sol","stopReason":"stop","timestamp":"2026-08-22T00:00:03.000Z","content":[{"type":"text","text":"Sent the question to the Expert pane."}],"usage":{"input":150,"output":20,"totalTokens":170,"cost":{"total":0.02}}}}\n'
  else
    printf '{"type":"message","id":"e8","parentId":"e7","timestamp":"2026-08-22T00:00:03.000Z","message":{"role":"assistant","provider":"%s","model":"%s","stopReason":"stop","timestamp":"2026-08-22T00:00:03.000Z","content":[{"type":"text","text":"Sent the question to the Expert pane."}],"usage":{"input":150,"output":20,"totalTokens":170,"cost":{"total":0.02}}}}\n' "$prov" "$mid"
  fi
} >"$sessdir/stub.jsonl"
printf 'Sent the question to the Expert pane.\n'
exit 0
STUB
  chmod +x "$TMP/pi-violate"
  run_violation() { # mode → sets out/rc/run_root
    printf '%s\n' "$1" >"$TMP/mode"
    out=""
    rc=0
    out=$(EVALS_PI_BIN="$TMP/pi-violate" bash "${BASH_SOURCE[0]}" protocol \
      --main-model openai-codex/gpt-5.6-luna --timeout 30 2>&1) || rc=$?
    run_root=$(printf '%s\n' "$out" | sed -n 's/^evals: run root: //p' | head -n1)
  }

  run_violation default
  check "violation/default: S1 stays pass with the pinned skill read" \
    "$(grep -q '^# classification: pass$' "$run_root/$S1_NAME-r1/checks.txt" 2>/dev/null; echo $?)"
  check "violation/default: resource gate ok for the pinned skill" \
    "$(grep -q '^ok - infra: no unexpected loaded resources' "$run_root/$S1_NAME-r1/checks.txt"; echo $?)"
  check "violation/default: metadata records the loaded resource" \
    "$(jq -e '.loadedResources == [{kind:"skill-read",name:"two-pane-workflow"}]' \
       "$run_root/$S1_NAME-r1/metadata.json" >/dev/null; echo $?)"
  rm -rf "$run_root"

  run_violation model-mismatch
  check "violation/model-mismatch: requested/actual mismatch is infra-fail (rc=$rc)" "$(if [  "$rc" -eq 3  ]; then echo 0; else echo 1; fi)"
  check "violation/model-mismatch: observed model reported" \
    "$(grep -q '^not ok - infra: actual model is openai-codex/gpt-5.6-luna (observed: openai-codex/gpt-5.6-sol)$' "$run_root/$S1_NAME-r1/checks.txt"; echo $?)"
  check "violation/model-mismatch: protocol checks skipped" \
    "$(grep -q '^# protocol checks skipped' "$run_root/$S1_NAME-r1/checks.txt"; echo $?)"
  rm -rf "$run_root"

  run_violation model-change
  check "violation/model-change: mid-session model change is infra-fail (rc=$rc)" "$(if [  "$rc" -eq 3  ]; then echo 0; else echo 1; fi)"
  check "violation/model-change: both observed models reported" \
    "$(grep -qF 'observed: openai-codex/gpt-5.6-luna openai-codex/gpt-5.6-sol' "$run_root/$S1_NAME-r1/checks.txt"; echo $?)"
  rm -rf "$run_root"

  run_violation invalid-jsonl
  check "violation/invalid-jsonl: unparseable JSONL is infra-fail (rc=$rc)" "$(if [  "$rc" -eq 3  ]; then echo 0; else echo 1; fi)"
  check "violation/invalid-jsonl: parse failure flagged" \
    "$(grep -q '^not ok - infra: session JSONL parses as JSON lines$' "$run_root/$S1_NAME-r1/checks.txt"; echo $?)"
  check "violation/invalid-jsonl: infra failures never touch protocol rates" \
    "$(jq -e '.totals == {runs:4, passed:0, protocolFails:0, infraFails:4}' "$run_root/summary.json" >/dev/null; echo $?)"
  rm -rf "$run_root"

  run_violation dup-jsonl
  check "violation/dup-jsonl: two session JSONLs are infra-fail (rc=$rc)" "$(if [  "$rc" -eq 3  ]; then echo 0; else echo 1; fi)"
  check "violation/dup-jsonl: JSONL count reported" \
    "$(grep -q '^not ok - infra: exactly one session JSONL (found 2)$' "$run_root/$S1_NAME-r1/checks.txt"; echo $?)"
  rm -rf "$run_root"

  run_violation direct-write
  check "violation/direct-write: direct runtime write is protocol-fail (rc=$rc)" "$(if [  "$rc" -eq 1  ]; then echo 0; else echo 1; fi)"
  check "violation/direct-write: forbidden direct access flagged" \
    "$(grep -q '^not ok - S1: no forbidden direct runtime access in tool calls$' "$run_root/$S1_NAME-r1/checks.txt"; echo $?)"
  check "violation/direct-write: helper send still required" \
    "$(grep -q '^not ok - S1: successful ./2pane send' "$run_root/$S1_NAME-r1/checks.txt"; echo $?)"
  rm -rf "$run_root"

  run_violation tamper
  check "violation/tamper: fixture tampering is protocol-fail (rc=$rc)" "$(if [  "$rc" -eq 1  ]; then echo 0; else echo 1; fi)"
  check "violation/tamper: manifest change flagged" \
    "$(grep -q '^not ok - S1: files outside .2pane unchanged (manifest equal)$' "$run_root/$S1_NAME-r1/checks.txt"; echo $?)"
  rm -rf "$run_root"

  run_violation custom-resource
  check "violation/custom-resource: extension entry is infra-fail (rc=$rc)" "$(if [  "$rc" -eq 3  ]; then echo 0; else echo 1; fi)"
  check "violation/custom-resource: unexpected resource flagged" \
    "$(grep -q '^not ok - infra: no unexpected loaded resources' "$run_root/$S1_NAME-r1/checks.txt"; echo $?)"
  check "violation/custom-resource: protocol checks skipped" \
    "$(grep -q '^# protocol checks skipped' "$run_root/$S1_NAME-r1/checks.txt"; echo $?)"
  rm -rf "$run_root"

  run_violation skill-resource
  check "violation/skill-resource: unexpected skill read is infra-fail (rc=$rc)" "$(if [  "$rc" -eq 3  ]; then echo 0; else echo 1; fi)"
  check "violation/skill-resource: sneaky skill named in the check" \
    "$(grep -q 'not ok - infra: no unexpected loaded resources.*sneaky-skill' "$run_root/$S1_NAME-r1/checks.txt"; echo $?)"
  rm -rf "$run_root"

  # ── economy task + baseline fingerprint + read scope (ticket 05) ──
  local fp_a env_digest
  expect_eq "econ: task text ends with the exact two decision lines" \
    "$(econ_task_text | tail -n 2)" "$ECON_FINAL_LINE1
$ECON_FINAL_LINE2"
  expect_eq "econ: baseline prompt is mode instruction + blank line + task" \
    "$(econ_baseline_prompt)" "$ECON_BASELINE_MODE

$ECON_TASK_TEXT"
  fp_a="$(baseline_fingerprint openai-codex/gpt-5.6-sol:medium pi-1 psha-1 msha-1 esha-1)"
  expect_eq "fingerprint: byte-stable across calls" "$fp_a" \
    "$(baseline_fingerprint openai-codex/gpt-5.6-sol:medium pi-1 psha-1 msha-1 esha-1)"
  expect_eq "fingerprint: sha256 hex digest" \
    "$(printf '%s' "$fp_a" | grep -cE '^[0-9a-f]{64}$')" "1"
  expect_eq "fingerprint: component labels pinned (no main-model, no git commit)" \
    "$(baseline_fingerprint_preimage x y z w v | cut -d: -f1 | tr '\n' ' ')" \
    "eval-task format expert-model pi-version prompt-sha256 fixture-manifest-sha256 pinned-env-sha256 "
  check "fingerprint: changes with the expert model" \
    "$(if [  "$fp_a" != "$(baseline_fingerprint openai-codex/gpt-5.6-luna:medium pi-1 psha-1 msha-1 esha-1)"  ]; then echo 0; else echo 1; fi)"
  check "fingerprint: changes with the thinking level" \
    "$(if [  "$fp_a" != "$(baseline_fingerprint openai-codex/gpt-5.6-sol:high pi-1 psha-1 msha-1 esha-1)"  ]; then echo 0; else echo 1; fi)"
  check "fingerprint: changes with the pi version" \
    "$(if [  "$fp_a" != "$(baseline_fingerprint openai-codex/gpt-5.6-sol:medium pi-2 psha-1 msha-1 esha-1)"  ]; then echo 0; else echo 1; fi)"
  check "fingerprint: changes with the prompt" \
    "$(if [  "$fp_a" != "$(baseline_fingerprint openai-codex/gpt-5.6-sol:medium pi-1 psha-2 msha-1 esha-1)"  ]; then echo 0; else echo 1; fi)"
  check "fingerprint: changes with the fixture manifest" \
    "$(if [  "$fp_a" != "$(baseline_fingerprint openai-codex/gpt-5.6-sol:medium pi-1 psha-1 msha-2 esha-1)"  ]; then echo 0; else echo 1; fi)"
  check "fingerprint: changes with the pinned environment" \
    "$(if [  "$fp_a" != "$(baseline_fingerprint openai-codex/gpt-5.6-sol:medium pi-1 psha-1 msha-1 esha-2)"  ]; then echo 0; else echo 1; fi)"

  # F10: read-scope — economy reads may target only fixture files; runtime
  # state is the forbidden scan's job, absolute-outside and `..` escapes ours.
  cat >"$TMP/reads.jsonl" <<'EOF'
{"type":"session","version":3,"timestamp":"2026-08-22T00:00:00.000Z","cwd":"/tmp/2pane-workflow-eval-workdir"}
{"type":"message","id":"e1","parentId":null,"timestamp":"2026-08-22T00:00:00.200Z","message":{"role":"user","timestamp":"2026-08-22T00:00:00.200Z","content":[{"type":"text","text":"prompt"}]}}
{"type":"message","id":"e2","parentId":"e1","timestamp":"2026-08-22T00:00:01.000Z","message":{"role":"assistant","provider":"openai-codex","model":"gpt-5.6-sol","stopReason":"toolUse","timestamp":"2026-08-22T00:00:01.000Z","content":[{"type":"toolCall","id":"r1","name":"read","arguments":{"path":"docs/spec.md"}},{"type":"toolCall","id":"r2","name":"read","arguments":{"path":"/tmp/2pane-workflow-eval-workdir/docs/adr/0001-single-slot-inbox.md"}},{"type":"toolCall","id":"r3","name":"read","arguments":{"path":"/etc/passwd"}},{"type":"toolCall","id":"r4","name":"read","arguments":{"path":"../checkout/docs/spec.md"}},{"type":"toolCall","id":"b1","name":"bash","arguments":{"command":"./2pane take"}}]}}
EOF
  expect_eq "reads: fixture docs and workdir-absolute paths pass, escapes flagged" \
    "$(grader_reads_outside_fixture "$TMP/reads.jsonl")" "/etc/passwd
../checkout/docs/spec.md"
  expect_eq "reads: bash calls never look like read paths" \
    "$(grader_reads_outside_fixture "$TMP/reads.jsonl" | grep -c 2pane || true)" "0"

  # F10b: symlink-aliased workdir — a read reported through the PHYSICAL
  # spelling of the same fixture directory (macOS: /tmp → /private/tmp,
  # /var → /private/var) is not an escape. Deterministic on any platform:
  # our own symlink provides the two spellings, and pwd -P gives the truly
  # physical one — the exact string a model resolving real paths emits.
  mkdir -p "$TMP/rd-real/docs"
  ln -sfn "$TMP/rd-real" "$TMP/rd-link"
  local rd_phys saved_wd="$EVAL_WORKDIR"
  rd_phys="$(cd "$TMP/rd-link" && pwd -P)"
  cat >"$TMP/reads-alias.jsonl" <<EOF
{"type":"message","id":"e1","parentId":null,"timestamp":"2026-08-22T00:00:01.000Z","message":{"role":"assistant","provider":"openai-codex","model":"gpt-5.6-sol","stopReason":"toolUse","timestamp":"2026-08-22T00:00:01.000Z","content":[{"type":"toolCall","id":"r1","name":"read","arguments":{"path":"$TMP/rd-link/docs/spec.md"}},{"type":"toolCall","id":"r2","name":"read","arguments":{"path":"$rd_phys/docs/spec.md"}},{"type":"toolCall","id":"r3","name":"read","arguments":{"path":"$rd_phys-OTHER/docs/spec.md"}}]}}
EOF
  EVAL_WORKDIR="$TMP/rd-link"
  expect_eq "reads: literal and physical spellings of the workdir both pass" \
    "$(grader_reads_outside_fixture "$TMP/reads-alias.jsonl")" \
    "$rd_phys-OTHER/docs/spec.md"
  EVAL_WORKDIR="$TMP/rd-nonexistent"
  expect_eq "reads: missing workdir falls back to the literal spelling only" \
    "$(grader_reads_outside_fixture "$TMP/reads-alias.jsonl")" \
    "$TMP/rd-link/docs/spec.md
$rd_phys/docs/spec.md
$rd_phys-OTHER/docs/spec.md"
  EVAL_WORKDIR="$saved_wd"
  rm -rf "$TMP/rd-real" "$TMP/rd-link"

  # Economy fixture: exactly the two docs beyond the protocol fixture, and
  # they enter the manifest (so fixture changes invalidate the fingerprint).
  fixture_rebuild_economy
  check "econ fixture: exactly the two economy docs copied in" \
    "$(if [  -f "$EVAL_WORKDIR/docs/spec.md" ] && [ -f "$EVAL_WORKDIR/docs/adr/0001-single-slot-inbox.md" ] && [ "$(find "$EVAL_WORKDIR/docs" -type f | wc -l | tr -d ' ')" = 2 ]; then echo 0; else echo 1; fi)"
  manifest_of "$EVAL_WORKDIR" >"$TMP/econ-manifest.sha256"
  check "econ fixture: docs enter the manifest" \
    "$(grep -q 'docs/spec.md' "$TMP/econ-manifest.sha256"; echo $?)"
  env_digest="$(pinned_env_digest openai-codex/gpt-5.6-sol)"
  expect_eq "pinned-env digest: byte-stable" "$env_digest" "$(pinned_env_digest openai-codex/gpt-5.6-sol)"
  printf 'local edit\n' >>"$EVAL_WORKDIR/.agents/skills/$EVAL_PINNED_SKILL/SKILL.md"
  check "pinned-env digest: changes with skill content" \
    "$(if [  "$env_digest" != "$(pinned_env_digest openai-codex/gpt-5.6-sol)"  ]; then echo 0; else echo 1; fi)"
  check "pinned-env digest: expert spec enters the pinned flags" \
    "$(if [  "$env_digest" != "$(pinned_env_digest openai-codex/gpt-5.6-luna)"  ]; then echo 0; else echo 1; fi)"
  fixture_rebuild  # restore a pristine protocol fixture for the blocks below

  # ── baseline command end-to-end with a stub pi (ticket 05) ──
  cat >"$TMP/pi-baseline" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then printf 'stub-pi 0.0.0\n'; exit 0; fi
sessdir="" prev=""
for a in "$@"; do
  [ "$prev" = "--session-dir" ] && sessdir="$a"
  prev="$a"
done
mode="$(cat "$(dirname "$0")/blmode" 2>/dev/null || printf good)"
[ "$mode" = crash ] && exit 3
[ "$mode" = count ] && printf 'called\n' >>"$(dirname "$0")/blcalls"
final='Both documents assume a single human writer, so OS file locking is unnecessary.\ndecision: no-os-lock\ninvariant: human-single-writer'
[ "$mode" = bad-answer ] && final='The workflow looks fine as it is.'
{
  printf '{"type":"session","version":3,"id":"bl","timestamp":"2026-08-22T00:00:00.000Z","cwd":"/tmp/2pane-workflow-eval-workdir"}\n'
  printf '{"type":"message","id":"e1","parentId":null,"timestamp":"2026-08-22T00:00:00.200Z","message":{"role":"user","timestamp":"2026-08-22T00:00:00.200Z","content":[{"type":"text","text":"prompt"}]}}\n'
  printf '{"type":"message","id":"e2","parentId":"e1","timestamp":"2026-08-22T00:00:01.000Z","message":{"role":"assistant","provider":"openai-codex","model":"gpt-5.6-sol","stopReason":"toolUse","timestamp":"2026-08-22T00:00:01.000Z","content":[{"type":"toolCall","id":"r1","name":"read","arguments":{"path":"docs/spec.md"}},{"type":"toolCall","id":"r2","name":"read","arguments":{"path":"docs/adr/0001-single-slot-inbox.md"}}],"usage":{"input":1000,"output":100,"totalTokens":1100,"cost":{"total":0.1}}}}\n'
  printf '{"type":"message","id":"e3","parentId":"e2","timestamp":"2026-08-22T00:00:02.000Z","message":{"role":"toolResult","toolCallId":"r1","toolName":"read","isError":false,"content":[{"type":"text","text":"doc body"}]}}\n'
  printf '{"type":"message","id":"e4","parentId":"e3","timestamp":"2026-08-22T00:00:02.100Z","message":{"role":"toolResult","toolCallId":"r2","toolName":"read","isError":false,"content":[{"type":"text","text":"adr body"}]}}\n'
  printf '{"type":"message","id":"e5","parentId":"e4","timestamp":"2026-08-22T00:00:03.000Z","message":{"role":"assistant","provider":"openai-codex","model":"gpt-5.6-sol","stopReason":"stop","timestamp":"2026-08-22T00:00:03.000Z","content":[{"type":"text","text":"%s"}],"usage":{"input":2000,"output":200,"totalTokens":2200,"cost":{"total":0.2}}}}\n' "$final"
} >"$sessdir/stub.jsonl"
printf '%b\n' "$final"
exit 0
STUB
  chmod +x "$TMP/pi-baseline"
  run_baseline() { # store-dir stub-path extra-args... → sets out/rc/run_root
    out=""
    rc=0
    out=$(EVALS_BASELINE_DIR="$1" EVALS_PI_BIN="$2" bash "${BASH_SOURCE[0]}" baseline \
      --expert-model openai-codex/gpt-5.6-sol --timeout 30 "${@:3}" 2>&1) || rc=$?
    run_root=$(printf '%s\n' "$out" | sed -n 's/^evals: run root: //p' | head -n1)
  }

  # Publish: a compliant Expert-only run lands in the store, complete.
  local bl_store="$TMP/bl-store" bl_bad="$TMP/bl-bad" bl_crash="$TMP/bl-crash"
  local fp_dir id1 id2 id3 run_root1
  printf 'good\n' >"$TMP/blmode"
  rm -f "$TMP/blcalls"
  run_baseline "$bl_store" "$TMP/pi-baseline"
  run_root1="$run_root"
  check "baseline/good: run passes and publishes (rc=$rc)" "$(if [  "$rc" -eq 0  ]; then echo 0; else echo 1; fi)"
  check "baseline/good: classification is pass" \
    "$(grep -q '^# classification: pass$' "$run_root1/baseline-r1/checks.txt" 2>/dev/null; echo $?)"
  fp_dir="$(find "$bl_store" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  id1="$(cat "$fp_dir/active" 2>/dev/null)" || true
  check "baseline/good: active marker points at the published id" \
    "$(if [  -n "$id1"  ] && [ -d "$fp_dir/$id1" ]; then echo 0; else echo 1; fi)"
  check "baseline/good: published artifact set complete" \
    "$(for f in session.jsonl answer.txt prompt.txt metadata.json usage.json checks.txt fixture-manifest.sha256; do
         [ -s "$fp_dir/$id1/$f" ] || exit 1
       done; echo $?)"
  check "baseline/good: store dir name equals the fingerprint" \
    "$(if [  "$(basename "$fp_dir")" = "$(jq -r .fingerprint "$fp_dir/$id1/metadata.json" 2>/dev/null)" ]; then echo 0; else echo 1; fi)"
  check "baseline/good: metadata pins suite/role/expert/fingerprint/publication" \
    "$(jq -e '.suite=="baseline" and .role=="expert" and .scenario=="baseline"
        and .requestedModel=="openai-codex/gpt-5.6-sol" and .published==true
        and .baselineId!=null and .fingerprintComponents.expertModel=="openai-codex/gpt-5.6-sol"
        and (.fingerprintComponents|has("piVersion") and has("promptSha256") and has("fixtureManifestSha256") and has("pinnedEnvSha256"))
        and (.sessionSha256|length==64)' "$fp_dir/$id1/metadata.json" >/dev/null 2>&1; echo $?)"
  expect_eq "baseline/good: usage totals summed from the session" \
    "$(jq -c '{input,output,totalTokens}' "$fp_dir/$id1/usage.json" 2>/dev/null)" \
    '{"input":3000,"output":300,"totalTokens":3300}'
  expect_eq "baseline/good: answer ends with the exact two lines" \
    "$(tail -n 2 "$fp_dir/$id1/answer.txt" 2>/dev/null)" "$ECON_FINAL_LINE1
$ECON_FINAL_LINE2"
  check "baseline/good: prompt.txt is mode instruction + task" \
    "$(if [  "$(head -n1 "$fp_dir/$id1/prompt.txt" 2>/dev/null)" = "$ECON_BASELINE_MODE" ] && grep -qF 'Review docs/spec.md and docs/adr/0001-single-slot-inbox.md.' "$fp_dir/$id1/prompt.txt" 2>/dev/null; then echo 0; else echo 1; fi)"
  check "baseline/good: inbox-unused and read-scope checks recorded" \
    "$(grep -q '^ok - baseline: two-pane inbox unused' "$run_root1/baseline-r1/checks.txt" 2>/dev/null \
       && grep -q '^ok - baseline: read tool used only for fixture files' "$run_root1/baseline-r1/checks.txt" 2>/dev/null; echo $?)"
  check "baseline/good: results copy also kept" \
    "$(if [  -s "$run_root1/baseline-r1/session.jsonl" ]; then echo 0; else echo 1; fi)"

  # Reuse: matching fingerprint → same id printed, zero pi invocations.
  printf 'count\n' >"$TMP/blmode"
  rm -f "$TMP/blcalls"
  run_baseline "$bl_store" "$TMP/pi-baseline"
  check "baseline/cache: reuse exits 0" "$(if [  "$rc" -eq 0  ]; then echo 0; else echo 1; fi)"
  check "baseline/cache: same active id reprinted" \
    "$(printf '%s\n' "$out" | grep -q "^evals: baseline active: $id1$"; echo $?)"
  check "baseline/cache: no model call made" "$(if [  ! -e "$TMP/blcalls" ]; then echo 0; else echo 1; fi)"
  check "baseline/cache: no run dir created" \
    "$(if [  -z "$run_root" ] || [ ! -e "$run_root" ]; then echo 0; else echo 1; fi)"

  # The two stores are independent: deleting results leaves baselines intact.
  rm -rf "$run_root1"
  run_baseline "$bl_store" "$TMP/pi-baseline"
  check "baseline/cache: store independent of results deletion" \
    "$(if [  "$rc" -eq 0  ] && [ "$(cat "$bl_store/$(basename "$fp_dir")/active" 2>/dev/null)" = "$id1" ] && [ ! -e "$TMP/blcalls" ]; then echo 0; else echo 1; fi)"

  # Refresh: new immutable id, active repointed atomically, old kept intact.
  printf 'good\n' >"$TMP/blmode"
  run_baseline "$bl_store" "$TMP/pi-baseline" --refresh-baseline
  check "baseline/refresh: fresh run publishes (rc=$rc)" "$(if [  "$rc" -eq 0  ]; then echo 0; else echo 1; fi)"
  id2="$(cat "$fp_dir/active" 2>/dev/null)" || true
  check "baseline/refresh: active repointed to a new immutable id" \
    "$(if [  -n "$id2" ] && [ "$id2" != "$id1" ] && [ -d "$fp_dir/$id2" ]; then echo 0; else echo 1; fi)"
  check "baseline/refresh: previous baseline preserved intact" \
    "$(for f in session.jsonl answer.txt prompt.txt metadata.json usage.json checks.txt fixture-manifest.sha256; do
         [ -s "$fp_dir/$id1/$f" ] || exit 1
       done; echo $?)"
  check "baseline/refresh: both baselines coexist in the fingerprint dir" \
    "$(if [  "$(find "$fp_dir" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" = 2 ]; then echo 0; else echo 1; fi)"
  rm -rf "$run_root"

  # A wrong answer fails the correctness gate and is never published.
  printf 'bad-answer\n' >"$TMP/blmode"
  run_baseline "$bl_bad" "$TMP/pi-baseline"
  check "baseline/bad-answer: wrong final answer is protocol-fail (rc=$rc)" "$(if [  "$rc" -eq 1  ]; then echo 0; else echo 1; fi)"
  check "baseline/bad-answer: two-line assertion flagged" \
    "$(grep -q '^not ok - baseline: final answer ends with the exact two lines' "$run_root/baseline-r1/checks.txt" 2>/dev/null; echo $?)"
  check "baseline/bad-answer: nothing published" "$(if [  ! -e "$bl_bad" ]; then echo 0; else echo 1; fi)"
  check "baseline/bad-answer: failed attempt kept in results" \
    "$(grep -q '^# classification: protocol-fail$' "$run_root/baseline-r1/checks.txt" 2>/dev/null; echo $?)"
  rm -rf "$run_root"

  # A pi crash is infra-fail and never becomes a baseline.
  printf 'crash\n' >"$TMP/blmode"
  run_baseline "$bl_crash" "$TMP/pi-baseline"
  check "baseline/crash: crash classifies infra-fail (rc=$rc)" "$(if [  "$rc" -eq 3  ]; then echo 0; else echo 1; fi)"
  check "baseline/crash: store untouched" "$(if [  ! -e "$bl_crash" ]; then echo 0; else echo 1; fi)"
  check "baseline/crash: lock released" "$(if [  ! -e "$EVAL_LOCKDIR" ]; then echo 0; else echo 1; fi)"
  rm -rf "$run_root"

  # A stale/dangling active marker is treated as no valid baseline.
  printf 'bl-00000000T000000Z-deadbeef\n' >"$fp_dir/active"
  printf 'count\n' >"$TMP/blmode"
  rm -f "$TMP/blcalls"
  run_baseline "$bl_store" "$TMP/pi-baseline"
  id3="$(cat "$fp_dir/active" 2>/dev/null)" || true
  check "baseline/stale-active: dangling marker triggers a fresh run" \
    "$(if [  "$rc" -eq 0  ] && [ -n "$id3" ] && [ "$id3" != "bl-00000000T000000Z-deadbeef" ] && [ -e "$TMP/blcalls" ]; then echo 0; else echo 1; fi)"
  rm -rf "$run_root"

  # Usage errors keep exit 2.
  rc=0
  out=$(EVALS_BASELINE_DIR="$bl_store" bash "${BASH_SOURCE[0]}" baseline 2>&1) || rc=$?
  check "baseline/usage: missing --expert-model is a usage error" "$(if [  "$rc" -eq 2  ]; then echo 0; else echo 1; fi)"

  rm -rf "$bl_store" "$bl_bad" "$bl_crash"

  # ── economy formula units (ticket 07) — zero model calls ──
  expect_eq "econ/median: odd count picks the middle" "$(econ_median 5 1 9)" "5"
  expect_eq "econ/median: even count averages the middle two" "$(econ_median 1 2 3 4)" "2.5"
  expect_eq "econ/median: single value is itself" "$(econ_median 42)" "42"
  expect_eq "econ/median: order-independent" "$(econ_median 9 1 5)" "5"
  expect_eq "econ/saving: zero consultations → 100%" "$(econ_saving_percent 0 3911)" "100"
  expect_eq "econ/saving: quarter usage → 75%" "$(econ_saving_percent 1000 4000)" "75"
  expect_eq "econ/saving: multiple consultations summed first → one number" "$(econ_saving_percent 300 4000)" "92.5"
  expect_eq "econ/saving: negative saving when E1 used more" "$(econ_saving_percent 8000 4000)" "-100"
  expect_eq "econ/saving: two-decimal rounding" "$(econ_saving_percent 1 3)" "66.67"
  expect_eq "econ/saving: equal usage → exactly 0%" "$(econ_saving_percent 4000 4000)" "0"
  check "econ/saving: threshold pass at exactly the minimum" \
    "$(awk -v s="$(econ_saving_percent 1000 4000)" -v m=75 'BEGIN { exit !(s >= m) }'; echo $?)"
  check "econ/saving: threshold fails just below the minimum" \
    "$(awk -v s="$(econ_saving_percent 1001 4000)" -v m=75 'BEGIN { exit !(s < m) }'; echo $?)"

  # ── economy end-to-end with a stub pi (tickets 06/07) ──
  #
  # The stub is a state machine driven by the prompt: it recognizes the E1
  # main turn, the expert turn and the resumed main turns, drives the REAL
  # helper for side effects (send/take), and appends to the role session via
  # --session exactly like real pi would (never a second JSONL).
  cat >"$TMP/pi-econ" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then printf 'stub-pi 0.0.0\n'; exit 0; fi
dir="$(dirname "$0")"
mode="$(cat "$dir/econmode" 2>/dev/null || printf multi)"
[ "$mode" = count ] && { printf 'called\n' >>"$dir/econcalls"; exit 0; }
[ "$mode" = crash ] && exit 3
sessdir=""; sessfile=""; model=""; prompt=""; prev=""
for a in "$@"; do
  case "$prev" in
    --session-dir) sessdir="$a" ;;
    --session) sessfile="$a" ;;
    --model) model="$a" ;;
  esac
  prompt="$a"; prev="$a"
done
prov="${model%%/*}"; mid="${model#*/}"; mid="${mid%%:*}"
[ "$mode" = endless ] && sleep 1
role=other
Q="'Should the workflow use OS file locking around its inbox?'"
case "$prompt" in
  *"as Main"*) role=main-new ;;
  *"Expert pane"*) role=expert ;;
  *"Expert sent a reply"*) role=main-reply ;;
  *"inbox is empty"*) role=main-empty ;;
esac
sess="$sessdir/stub.jsonl"
[ -n "$sessfile" ] && sess="$sessfile"
n0="$$-$(date +%s 2>/dev/null || date)"
N=0
sess_new=0
[ -e "$sess" ] || { printf '{"type":"session","version":3,"id":"econ","timestamp":"2026-08-22T00:00:00.000Z","cwd":"/tmp/2pane-workflow-eval-workdir"}\n' >"$sess"; sess_new=1; }
tlvl="${model#*:}"
[ "$tlvl" = "$model" ] && tlvl=""
if [ -n "$tlvl" ] && [ "$sess_new" = 1 ]; then
  printf '{"type":"thinking_level_change","id":"t%s","timestamp":"2026-08-22T00:00:00.100Z","thinkingLevel":"%s"}\n' "$n0" "$tlvl" >>"$sess"
fi
emit() { # CMD ISERROR RESULTTEXT STOPTEXT USAGEJSON — one tool call + stop msg
  local tid="c${n0}_${N}"
  {
    printf '{"type":"message","id":"a%s","parentId":null,"timestamp":"2026-08-22T00:00:01.000Z","message":{"role":"assistant","provider":"%s","model":"%s","stopReason":"toolUse","timestamp":"2026-08-22T00:00:01.000Z","content":[{"type":"toolCall","id":"%s","name":"bash","arguments":{"command":"%s"}}],"usage":%s}}\n' "$tid" "$prov" "$mid" "$tid" "$1" "$5"
    printf '{"type":"message","id":"b%s","parentId":null,"timestamp":"2026-08-22T00:00:02.000Z","message":{"role":"toolResult","toolCallId":"%s","toolName":"bash","isError":%s,"content":[{"type":"text","text":"%s"}]}}\n' "$tid" "$tid" "$2" "$3"
    printf '{"type":"message","id":"d%s","parentId":null,"timestamp":"2026-08-22T00:00:03.000Z","message":{"role":"assistant","provider":"%s","model":"%s","stopReason":"stop","timestamp":"2026-08-22T00:00:03.000Z","content":[{"type":"text","text":"%s"}],"usage":%s}}\n' "$tid" "$prov" "$mid" "$4" "$5"
  } >>"$sess"
  N=$((N + 1))
}
final() { # STOPTEXT USAGEJSON — a bare final message
  local tid="f${n0}_${N}"
  printf '{"type":"message","id":"%s","parentId":null,"timestamp":"2026-08-22T00:00:04.000Z","message":{"role":"assistant","provider":"%s","model":"%s","stopReason":"stop","timestamp":"2026-08-22T00:00:04.000Z","content":[{"type":"text","text":"%s"}],"usage":%s}}\n' "$tid" "$prov" "$mid" "$1" "$2" >>"$sess"
  N=$((N + 1))
}
UM='{"input":100,"output":10,"totalTokens":110,"cost":{"total":0.01}}'
UE='{"input":50,"output":10,"totalTokens":60,"cost":{"total":0.005}}'
UH='{"input":50000,"output":5000,"totalTokens":55000,"cost":{"total":5}}'
[ "$mode" = hog ] && UE="$UH"
TWO='done\ndecision: no-os-lock\ninvariant: human-single-writer'
case "$role" in
  main-new)
    case "$mode" in
      skip) final "$TWO" "$UM"; printf '%b\n' "$TWO"; exit 0 ;;
      badskip) final 'I finished it myself without a locking review.' "$UM"; printf 'I finished it myself without a locking review.\n'; exit 0 ;;
    esac
    ./2pane send "Does the workflow need OS file locking around its inbox?" >/dev/null
    emit "./2pane send $Q" false '' 'I asked the Expert about OS file locking.' "$UM"
    printf 'I asked the Expert about OS file locking.\n'
    ;;
  expert)
    ./2pane take >/dev/null
    ./2pane send 'Expert reply: the human guarantees a single writer, so no OS file locking is needed.' >/dev/null
    emit './2pane take' false 'from: main\n\nDoes the workflow need OS file locking around its inbox?' 'Taking the question.' "$UE"
    emit "./2pane send Expert-reply-no-OS-lock-needed" false '' 'Replied to Main.' "$UE"
    printf 'Replied to Main.\n'
    ;;
  main-reply)
    ./2pane take >/dev/null
    emit './2pane take' false 'from: expert\n\nExpert reply: no OS file locking is needed.' 'Took the reply.' "$UM"
    cnt="$(cat "$dir/count" 2>/dev/null || printf 0)"; cnt=$((cnt + 1)); printf '%s\n' "$cnt" >"$dir/count"
    if [ "$mode" = endless ] || { [ "$mode" = multi ] && [ "$cnt" -lt 2 ]; }; then
      ./2pane send 'Second question: any caveats to that conclusion?' >/dev/null
      emit "./2pane send Second-question-any-caveats" false '' 'Consulting the Expert once more.' "$UM"
      printf 'Consulting the Expert once more.\n'
    else
      final "$TWO" "$UM"; printf '%b\n' "$TWO"
    fi
    ;;
  main-empty)
    final "$TWO" "$UM"; printf '%b\n' "$TWO"
    ;;
esac
exit 0
STUB
  chmod +x "$TMP/pi-econ"
  run_econ() { # store stub extra-args... → sets out/rc/run_root
    out=""
    rc=0
    out=$(EVALS_BASELINE_DIR="$1" EVALS_PI_BIN="$2" bash "${BASH_SOURCE[0]}" economy \
      --main-model openai-codex/gpt-5.6-luna --expert-model openai-codex/gpt-5.6-sol \
      --timeout 30 "${@:3}" 2>&1) || rc=$?
    run_root=$(printf '%s\n' "$out" | sed -n 's/^evals: run root: //p' | head -n1)
  }

  # Publish one baseline for the economy suite (same stub as ticket 05).
  local econ_store="$TMP/econ-store"
  printf 'good\n' >"$TMP/blmode"
  run_baseline "$econ_store" "$TMP/pi-baseline"
  check "econ/setup: baseline published for the economy suite" \
    "$(if [ "$rc" -eq 0 ]; then echo 0; else echo 1; fi)"
  local econ_bl_id econ_fp_dir
  econ_fp_dir="$(find "$econ_store" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  econ_bl_id="$(cat "$econ_fp_dir/active" 2>/dev/null)"

  # A: multi-consultation run — the full Main→Expert→Main→Expert→Main cycle,
  # both role JSONLs continued (never reset), usage accumulated.
  printf 'multi\n' >"$TMP/econmode"
  rm -f "$TMP/count"
  run_econ "$econ_store" "$TMP/pi-econ"
  check "econ/multi: two-consultation run passes (rc=$rc)" "$(if [  "$rc" -eq 0  ]; then echo 0; else echo 1; fi)"
  check "econ/multi: classification is pass" \
    "$(grep -q '^# classification: pass$' "$run_root/e1-r1/checks.txt" 2>/dev/null; echo $?)"
  expect_eq "econ/multi: two consultations counted" \
    "$(jq -r .consultations "$run_root/e1-r1/result.json" 2>/dev/null)" "2"
  expect_eq "econ/multi: five pi turns driven by inbox state" \
    "$(jq -r .turns "$run_root/e1-r1/result.json" 2>/dev/null)" "5"
  check "econ/multi: roles alternate by turn dir" \
    "$(for d in T01-main T02-expert T03-main T04-expert T05-main; do
         [ -d "$run_root/e1-r1/turns/$d" ] || exit 1
       done; echo $?)"
  check "econ/multi: each role kept exactly ONE session JSONL" \
    "$(if [  "$(find "$run_root/e1-r1/sessions/main" -name '*.jsonl' | wc -l | tr -d ' ')" = 1 ] \
       && [ "$(find "$run_root/e1-r1/sessions/expert" -name '*.jsonl' | wc -l | tr -d ' ')" = 1 ]; then echo 0; else echo 1; fi)"
  expect_eq "econ/multi: main usage accumulated across 3 turns (9 assistant msgs)" \
    "$(grader_usage "$run_root/e1-r1/main-session.jsonl" | jq -r .modelCalls)" "9"
  expect_eq "econ/multi: expert usage accumulated across 2 turns (8 assistant msgs)" \
    "$(grader_usage "$run_root/e1-r1/expert-session.jsonl" | jq -r .modelCalls)" "8"
  expect_eq "econ/multi: summed expert totalTokens feeds the comparison" \
    "$(grader_usage "$run_root/e1-r1/expert-session.jsonl" | jq -r .totalTokens)" "480"
  check "econ/multi: per-role durations recorded (3 main turns, 2 expert turns)" \
    "$(jq -e '.mainSeconds >= 0 and .expertSeconds >= 0 and .wallSeconds >= (.mainSeconds + .expertSeconds) - 2' \
       "$run_root/e1-r1/result.json" >/dev/null; echo $?)"
  check "econ/multi: baseline reference pins id, fingerprint and usage snapshot" \
    "$(jq -e --arg id "$econ_bl_id" '.baselineRef.id==$id and (.baselineRef.fingerprint|length==64) and .baselineRef.totalTokens==3300 and .baselineRef.sessionSha256!=null' \
       "$run_root/e1-r1/result.json" >/dev/null; echo $?)"
  check "econ/multi: summary computes median, saving and verdict" \
    "$(jq -e --arg id "$econ_bl_id" '.medianExpertTokens==480 and .expertSavingPercent==85.45 and .economyVerdict=="pass" and .exploratory==true and .overall=="pass" and .baseline.id==$id' \
       "$run_root/summary.json" >/dev/null; echo $?)"
  check "econ/multi: cost report shows both modes and expert share" \
    "$(jq -e '.totals.mainTokens>0 and .totals.expertTokens==480 and .totals.e1Cost>0 and .totals.baselineTokens==3300 and .totals.expertTokenShare>0 and .totals.expertCostShare>0' \
       "$run_root/summary.json" >/dev/null; echo $?)"
  check "econ/multi: transition checks recorded" \
    "$(grep -q '^ok - E1/cycle: every consultation got exactly one Expert reply (sends: 2)$' \
       "$run_root/e1-r1/checks.txt" && grep -q '^ok - E1/main: final answer ends with the exact two lines' \
       "$run_root/e1-r1/checks.txt"; echo $?)"
  local econ_root_a="$run_root"

  # B: same compliant run, but the threshold is missed → economy-fail.
  printf 'multi\n' >"$TMP/econmode"
  rm -f "$TMP/count"
  run_econ "$econ_store" "$TMP/pi-econ" --min-expert-saving 90
  check "econ/threshold: missed saving is economy-fail (rc=$rc)" "$(if [  "$rc" -eq 5  ]; then echo 0; else echo 1; fi)"
  check "econ/threshold: verdict recorded with runs still passing" \
    "$(jq -e '.overall=="economy-fail" and .economyVerdict=="economy-fail" and .runResults[0].status=="pass" and .expertSavingPercent==85.45 and .minExpertSaving==90' \
       "$run_root/summary.json" >/dev/null; echo $?)"
  rm -rf "$run_root"

  # C: negative saving — Expert hogs tokens; nothing limits it during the run,
  # the gate only fires afterwards.
  printf 'hog\n' >"$TMP/econmode"
  rm -f "$TMP/count"
  run_econ "$econ_store" "$TMP/pi-econ"
  check "econ/hog: unrestricted Expert use is not stopped mid-run (rc=$rc)" "$(if [  "$rc" -eq 5  ]; then echo 0; else echo 1; fi)"
  check "econ/hog: negative saving graded economy-fail" \
    "$(jq -e '.economyVerdict=="economy-fail" and .expertSavingPercent < 0 and .runResults[0].status=="pass"' \
       "$run_root/summary.json" >/dev/null; echo $?)"
  rm -rf "$run_root"

  # D: expert-skipped — zero consultations is legal, distinct and free.
  printf 'skip\n' >"$TMP/econmode"
  rm -f "$TMP/count"
  run_econ "$econ_store" "$TMP/pi-econ"
  check "econ/skip: zero-consultation run passes (rc=$rc)" "$(if [  "$rc" -eq 0  ]; then echo 0; else echo 1; fi)"
  check "econ/skip: labeled expert-skipped with zero Expert usage" \
    "$(jq -e '.runResults[0].expertSkipped==true and .runResults[0].consultations==0 and .runResults[0].expertTokens==0' \
       "$run_root/summary.json" >/dev/null; echo $?)"
  check "econ/skip: no Expert session ever started" \
    "$(if [  "$(find "$run_root/e1-r1/sessions/expert" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')" = 0 ] \
       && [ ! -e "$run_root/e1-r1/expert-session.jsonl" ]; then echo 0; else echo 1; fi)"
  check "econ/skip: zero Expert duration recorded" \
    "$(jq -e '.expertSeconds == 0 and .mainSeconds >= 0' \
       "$run_root/e1-r1/result.json" >/dev/null; echo $?)"
  expect_eq "econ/skip: expert-skipped summary line present" \
    "$(grep -c 'expert-skipped (0 consultations)' "$run_root/summary.txt" || true)" "1"
  check "econ/skip: full saving against the baseline" \
    "$(jq -e '.expertSavingPercent==100 and .economyVerdict=="pass"' "$run_root/summary.json" >/dev/null; echo $?)"
  rm -rf "$run_root"

  # E: correct-but-wrong answer — badskip answers incorrectly without Expert;
  # a wrong answer never counts as a saving.
  printf 'badskip\n' >"$TMP/econmode"
  rm -f "$TMP/count"
  run_econ "$econ_store" "$TMP/pi-econ"
  check "econ/badskip: wrong answer is protocol-fail (rc=$rc)" "$(if [  "$rc" -eq 1  ]; then echo 0; else echo 1; fi)"
  check "econ/badskip: two-line assertion flagged" \
    "$(grep -q '^not ok - E1/main: final answer ends with the exact two lines' \
       "$run_root/e1-r1/checks.txt" 2>/dev/null; echo $?)"
  check "econ/badskip: incorrect answers never count as savings" \
    "$(jq -e '.runResults[0].correctAnswer==false and .overall!="pass"' "$run_root/summary.json" >/dev/null; echo $?)"
  rm -rf "$run_root"

  # F: baseline-missing — exits 6 before any model call, printing the command.
  rm -f "$TMP/econcalls"
  printf 'count\n' >"$TMP/econmode"
  run_econ "$TMP/econ-empty-store" "$TMP/pi-econ"
  check "econ/missing: exits baseline-missing (rc=$rc)" "$(if [  "$rc" -eq 6  ]; then echo 0; else echo 1; fi)"
  check "econ/missing: message names baseline-missing" \
    "$(printf '%s\n' "$out" | grep -q 'baseline-missing'; echo $?)"
  check "econ/missing: exact creation command printed" \
    "$(printf '%s\n' "$out" | grep -qF 'evals/run.sh baseline --expert-model openai-codex/gpt-5.6-sol'; echo $?)"
  check "econ/missing: no model call made" "$(if [  ! -e "$TMP/econcalls" ]; then echo 0; else echo 1; fi)"
  check "econ/missing: no run artifacts created" \
    "$(if [  -z "$run_root" ] || [ ! -e "$run_root" ]; then echo 0; else echo 1; fi)"

  # G: turn cap rail — endless consultation loop stops as infra-fail.
  printf 'endless\n' >"$TMP/econmode"
  rm -f "$TMP/count"
  run_econ "$econ_store" "$TMP/pi-econ" --turn-cap 3 --run-timeout 120
  check "econ/turn-cap: cap triggers infra-fail (rc=$rc)" "$(if [  "$rc" -eq 3  ]; then echo 0; else echo 1; fi)"
  check "econ/turn-cap: rail recorded distinctly" \
    "$(grep -q '^not ok - rail: pi-turn cap 3 reached$' "$run_root/e1-r1/checks.txt" 2>/dev/null; echo $?)"
  expect_eq "econ/turn-cap: exactly three pi turns ran" \
    "$(find "$run_root/e1-r1/turns" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" "3"
  check "econ/turn-cap: no fake saving claimed" \
    "$(jq -e '.economyVerdict==null and .overall=="infra-fail"' "$run_root/summary.json" >/dev/null; echo $?)"
  rm -rf "$run_root"

  # H: wall-clock rail — a slow endless loop stops as infra-fail.
  printf 'endless\n' >"$TMP/econmode"
  rm -f "$TMP/count"
  run_econ "$econ_store" "$TMP/pi-econ" --run-timeout 3 --turn-cap 100
  check "econ/run-timeout: wall clock triggers infra-fail (rc=$rc)" "$(if [  "$rc" -eq 3  ]; then echo 0; else echo 1; fi)"
  check "econ/run-timeout: rail recorded distinctly" \
    "$(grep -q '^not ok - rail: wall-clock run timeout 3s reached$' \
       "$run_root/e1-r1/checks.txt" 2>/dev/null; echo $?)"
  rm -rf "$run_root"

  # I: baseline pinning — exact id reused; bogus id is baseline-missing; a
  # stored fingerprint mismatch is refused loudly.
  printf 'skip\n' >"$TMP/econmode"
  rm -f "$TMP/count"
  run_econ "$econ_store" "$TMP/pi-econ" --baseline-id "$econ_bl_id"
  check "econ/pin: pinned id resolves and runs (rc=$rc)" "$(if [  "$rc" -eq 0  ]; then echo 0; else echo 1; fi)"
  check "econ/pin: summary references the pinned baseline" \
    "$(jq -e --arg id "$econ_bl_id" '.baseline.id==$id' "$run_root/summary.json" >/dev/null; echo $?)"
  rm -rf "$run_root"
  run_econ "$econ_store" "$TMP/pi-econ" --baseline-id bl-nonexistent
  check "econ/pin: unknown id is baseline-missing (rc=$rc)" "$(if [  "$rc" -eq 6  ]; then echo 0; else echo 1; fi)"
  rm -rf "$run_root" 2>/dev/null || true
  local econ_bad="$TMP/econ-bad-store"
  rm -rf "$econ_bad"
  cp -R "$econ_store" "$econ_bad"
  local bad_fp_dir; bad_fp_dir="$(find "$econ_bad" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  jq --arg fp ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff \
    '.fingerprint = $fp' "$bad_fp_dir/$econ_bl_id/metadata.json" >"$bad_fp_dir/$econ_bl_id/metadata.json.tmp" \
    && mv "$bad_fp_dir/$econ_bl_id/metadata.json.tmp" "$bad_fp_dir/$econ_bl_id/metadata.json"
  run_econ "$econ_bad" "$TMP/pi-econ" --baseline-id "$econ_bl_id"
  check "econ/pin: fingerprint mismatch refused as usage error (rc=$rc)" "$(if [  "$rc" -eq 2  ]; then echo 0; else echo 1; fi)"
  rm -rf "$run_root" 2>/dev/null || true
  rm -rf "$econ_bad"

  # J: two economy runs with different Main models share ONE baseline, and
  # the second run creates no new Expert-only session.
  local n_before
  n_before="$(find "$econ_store" -mindepth 2 -maxdepth 2 -type d | wc -l | tr -d ' ')"
  printf 'multi\n' >"$TMP/econmode"
  rm -f "$TMP/count"
  run_econ "$econ_store" "$TMP/pi-econ"   # main = openai-codex/gpt-5.6-luna
  check "econ/shared-1: first run passes (rc=$rc)" "$(if [  "$rc" -eq 0  ]; then echo 0; else echo 1; fi)"
  local id_first; id_first="$(jq -r .baseline.id "$run_root/summary.json")"
  rm -rf "$run_root"
  rc=0
  out=$(EVALS_BASELINE_DIR="$econ_store" EVALS_PI_BIN="$TMP/pi-econ" bash "${BASH_SOURCE[0]}" economy \
    --main-model openai-codex/gpt-5.6-luna:high --expert-model openai-codex/gpt-5.6-sol \
    --timeout 30 2>&1) || rc=$?
  run_root=$(printf '%s\n' "$out" | sed -n 's/^evals: run root: //p' | head -n1)
  check "econ/shared-2: second run with another Main passes (rc=$rc)" "$(if [  "$rc" -eq 0  ]; then echo 0; else echo 1; fi)"
  check "econ/shared-2: same baseline id reused" \
    "$(if [  "$(jq -r .baseline.id "$run_root/summary.json" 2>/dev/null)" = "$id_first" ]; then echo 0; else echo 1; fi)"
  expect_eq "econ/shared-2: no new Expert-only baseline created" \
    "$(find "$econ_store" -mindepth 2 -maxdepth 2 -type d | wc -l | tr -d ' ')" "$n_before"
  rm -rf "$run_root"

  rm -rf "$econ_store" "$econ_root_a" "$TMP/econ-empty-store" 2>/dev/null || true

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
    baseline) shift; cmd_baseline "$@" ;;
    economy) shift; cmd_economy "$@" ;;
    -h|--help) usage ;;
    *) usage_error "unknown command: $1" ;;
  esac
}

main "$@"
