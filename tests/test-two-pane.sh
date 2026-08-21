#!/usr/bin/env bash
# Behavior tests for the deterministic two-pane state helper.
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$REPO_ROOT/two-pane" "$TMP/two-pane"
chmod +x "$TMP/two-pane"

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

"$TMP/two-pane" init
if [ -f "$TMP/.agents/INBOX.md" ] && [ -d "$TMP/.agents/archive" ]; then
  init_status=0
else
  init_status=1
fi
check "init creates runtime state" "$init_status"

AGENT_ROLE=expert "$TMP/two-pane" send $'Build the thing.\nReturn the result.'
expected=$'from: expert\n\nBuild the thing.\nReturn the result.'
assert_equals "send publishes the complete message" "$expected" "$(cat "$TMP/.agents/INBOX.md")"

"$TMP/two-pane" init
assert_equals "init preserves an existing message" "$expected" "$(cat "$TMP/.agents/INBOX.md")"

if AGENT_ROLE=expert "$TMP/two-pane" send "overwrite" 2>/dev/null; then
  overwrite_status=1
else
  overwrite_status=0
fi
check "send rejects a busy inbox" "$overwrite_status"
assert_equals "rejected send preserves the message" "$expected" "$(cat "$TMP/.agents/INBOX.md")"

taken="$(AGENT_ROLE=main "$TMP/two-pane" take)"
assert_equals "take returns the complete message" "$expected" "$taken"
if [ ! -s "$TMP/.agents/INBOX.md" ] && [ "$(find "$TMP/.agents/archive" -type f | wc -l | tr -d ' ')" = 1 ]; then
  take_status=0
else
  take_status=1
fi
check "take archives before clearing" "$take_status"

empty="$(AGENT_ROLE=main "$TMP/two-pane" take)"
assert_equals "take is quiet for an empty inbox" "" "$empty"

printf 'Reply through standard input.\n' | AGENT_ROLE=main "$TMP/two-pane" send
if AGENT_ROLE=main "$TMP/two-pane" take >/dev/null 2>&1; then
  own_status=1
else
  own_status=0
fi
check "take rejects a message from the same role" "$own_status"
if [ -s "$TMP/.agents/INBOX.md" ]; then
  preserve_status=0
else
  preserve_status=1
fi
check "rejected take preserves the message" "$preserve_status"

reply="$(AGENT_ROLE=expert "$TMP/two-pane" take)"
assert_equals "send accepts standard input" $'from: main\n\nReply through standard input.' "$reply"

if AGENT_ROLE=invalid "$TMP/two-pane" send "bad role" >/dev/null 2>&1; then
  role_status=1
else
  role_status=0
fi
check "invalid roles are rejected" "$role_status"

echo "---"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
