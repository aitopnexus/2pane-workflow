#!/usr/bin/env bash
# Behavior tests for the deterministic 2pane state helper.
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$REPO_ROOT/2pane" "$TMP/2pane"
chmod +x "$TMP/2pane"

pass=0
fail=0
check() { # label exit-code
  if [ "$2" -eq 0 ]; then
    pass=$((pass + 1)); echo "ok - $1"
  else
    fail=$((fail + 1)); echo "not ok - $1"
  fi
}
assert_equals() { # label expected actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); echo "ok - $1"
  else
    fail=$((fail + 1)); echo "not ok - $1 (expected: $2, got: $3)"
  fi
}

if help="$("$TMP/2pane" 2>/dev/null)" && printf '%s\n' "$help" | grep -q '^Usage: 2pane'; then
  check "no arguments show help" 0
else
  check "no arguments show help" 1
fi

if help="$("$TMP/2pane" --help 2>/dev/null)" && printf '%s\n' "$help" | grep -q '^Usage: 2pane'; then
  check "--help shows help" 0
else
  check "--help shows help" 1
fi

"$TMP/2pane" init
if [ -f "$TMP/.2pane/INBOX.md" ] && [ ! -e "$TMP/.2pane/archive" ]; then
  init_status=0
else
  init_status=1
fi
check "init creates runtime state" "$init_status"
if [ ! -e "$TMP/.agents/INBOX.md" ] && [ ! -e "$TMP/.agents/archive" ]; then
  protected_status=0
else
  protected_status=1
fi
check "runtime state stays outside the agent instruction directory" "$protected_status"

AGENT_ROLE=expert "$TMP/2pane" send $'Build the thing.\nReturn the result.'
expected=$'from: expert\n\nBuild the thing.\nReturn the result.'
assert_equals "send publishes the complete message" "$expected" "$(cat "$TMP/.2pane/INBOX.md")"

"$TMP/2pane" init
assert_equals "init preserves an existing message" "$expected" "$(cat "$TMP/.2pane/INBOX.md")"

if AGENT_ROLE=expert "$TMP/2pane" send "overwrite" 2>/dev/null; then
  overwrite_status=1
else
  overwrite_status=0
fi
check "send rejects a busy inbox" "$overwrite_status"
assert_equals "rejected send preserves the message" "$expected" "$(cat "$TMP/.2pane/INBOX.md")"

taken="$(AGENT_ROLE=main "$TMP/2pane" take)"
assert_equals "take returns the complete message" "$expected" "$taken"
if [ ! -s "$TMP/.2pane/INBOX.md" ] && [ ! -e "$TMP/.2pane/consuming.md" ]; then
  take_status=0
else
  take_status=1
fi
check "take leaves no persistent communication history" "$take_status"

AGENT_ROLE=expert "$TMP/2pane" send "Recover this message."
mv "$TMP/.2pane/INBOX.md" "$TMP/.2pane/consuming.md"
: > "$TMP/.2pane/INBOX.md"
recovered="$(AGENT_ROLE=main "$TMP/2pane" take)"
assert_equals "take resumes an interrupted consume" \
  $'from: expert\n\nRecover this message.' "$recovered"
if [ ! -e "$TMP/.2pane/consuming.md" ]; then
  recovery_status=0
else
  recovery_status=1
fi
check "successful recovery removes transient state" "$recovery_status"

AGENT_ROLE=expert "$TMP/2pane" send "Still consuming."
mv "$TMP/.2pane/INBOX.md" "$TMP/.2pane/consuming.md"
: > "$TMP/.2pane/INBOX.md"
if AGENT_ROLE=main "$TMP/2pane" send "too early" >/dev/null 2>&1; then
  consuming_status=1
else
  consuming_status=0
fi
check "send rejects an unfinished consume" "$consuming_status"
AGENT_ROLE=main "$TMP/2pane" take >/dev/null

empty="$(AGENT_ROLE=main "$TMP/2pane" take)"
assert_equals "take is quiet for an empty inbox" "" "$empty"

printf 'Reply through standard input.\n' | AGENT_ROLE=main "$TMP/2pane" send
if AGENT_ROLE=main "$TMP/2pane" take >/dev/null 2>&1; then
  own_status=1
else
  own_status=0
fi
check "take rejects a message from the same role" "$own_status"
if [ -s "$TMP/.2pane/INBOX.md" ]; then
  preserve_status=0
else
  preserve_status=1
fi
check "rejected take preserves the message" "$preserve_status"

reply="$(AGENT_ROLE=expert "$TMP/2pane" take)"
assert_equals "send accepts standard input" $'from: main\n\nReply through standard input.' "$reply"

if AGENT_ROLE=invalid "$TMP/2pane" send "bad role" >/dev/null 2>&1; then
  role_status=1
else
  role_status=0
fi
check "invalid roles are rejected" "$role_status"

echo "---"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
