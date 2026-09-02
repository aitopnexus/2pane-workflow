#!/usr/bin/env bash
# Behavior tests for the `2pane dev` herdr workspace launcher. Run: tests/test-dev.sh
#
# A fake herdr on PATH records every call and answers with canned JSON, so
# the tests exercise only the script's observable behavior: which panes are
# created, what runs in them, and how failures degrade. Failure modes are
# switched on with FAKE_HERDR_* environment variables per test.
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state"
export FAKE_STATE="$TMP/state"
cp "$REPO_ROOT/2pane" "$TMP/2pane"
chmod +x "$TMP/2pane"
LAUNCHER="$TMP/2pane"

pass=0
fail=0
assert_contains() { # label needle file
  if grep -qF -- "$2" "$3"; then
    pass=$((pass + 1)); echo "ok - $1"
  else
    fail=$((fail + 1)); echo "not ok - $1"
  fi
}
assert_not_contains() { # label needle file
  if grep -qF -- "$2" "$3"; then
    fail=$((fail + 1)); echo "not ok - $1"
  else
    pass=$((pass + 1)); echo "ok - $1"
  fi
}
assert_equals() { # label expected actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); echo "ok - $1"
  else
    fail=$((fail + 1)); echo "not ok - $1 (expected: $2, got: $3)"
  fi
}

# Fake herdr: records every call, hands out w1:p2, w1:p3, ... for splits.
export HERDR_CALLS="$TMP/herdr-calls"
cat > "$TMP/bin/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HERDR_CALLS"
case "$1 $2" in
  "workspace create")
    [ "${FAKE_HERDR_FAIL_CREATE:-}" = 1 ] && exit 1
    echo '{"id":"cli:workspace:create","result":{"root_pane":{"pane_id":"w1:p1"}}}'
    ;;
  "pane split")
    [ "${FAKE_HERDR_FAIL_SPLIT:-}" = 1 ] && exit 1
    n="$(cat "$FAKE_STATE/splits" 2>/dev/null || echo 0)"
    n=$((n + 1))
    echo "$n" > "$FAKE_STATE/splits"
    if [ "${FAKE_HERDR_NOJSON:-}" = 1 ]; then
      echo '{"id":"cli:pane:split","result":{}}'
    else
      # w1:p1 is the workspace root pane; splits hand out p2, p3, ...
      echo "{\"id\":\"cli:pane:split\",\"result\":{\"pane\":{\"pane_id\":\"w1:p$((n + 1))\"}}}"
    fi
    ;;
  "agent start")
    [ "${FAKE_HERDR_FAIL_AGENT:-}" = 1 ] && exit 1
    ;;
  "pane list")
    n="$(cat "$FAKE_STATE/splits" 2>/dev/null || echo 0)"
    i=1
    out='{"id":"cli:pane:list","result":{"panes":['
    while [ "$i" -le $((n + 1)) ]; do
      [ "$i" -gt 1 ] && out="$out,"
      out="$out{\"pane_id\":\"w1:p$i\"}"
      i=$((i + 1))
    done
    printf '%s]}}\n' "$out"
    ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/herdr"

# The fake bin shadows herdr; /bin:/usr/bin lets the shebang's `env bash`
# resolve. herdr lives outside these dirs, so removing the fake makes it absent.
FAKE_PATH="$TMP/bin:/bin:/usr/bin"

reset_fakes() {
  : > "$HERDR_CALLS"
  rm -f "$FAKE_STATE/splits"
}

# Test 1: the happy path creates the workspace, the 2/3-1/3 layout, and the
# three agents, marking the expert column with AGENT_ROLE=expert.
reset_fakes
PATH="$FAKE_PATH" "$LAUNCHER" dev > "$TMP/out" 2> "$TMP/err"
assert_equals "happy path exits zero" "0" "$?"
assert_contains "workspace created in the repository" \
  "workspace create --cwd $TMP" "$HERDR_CALLS"
assert_contains "right column split carries AGENT_ROLE=expert" \
  "pane split --pane w1:p1 --direction right --ratio 0.5 --cwd $TMP --env AGENT_ROLE=expert" "$HERDR_CALLS"
assert_contains "left column split keeps two thirds on top" \
  "pane split --pane w1:p1 --direction down --ratio 0.6667" "$HERDR_CALLS"
assert_contains "right column split keeps two thirds on top" \
  "pane split --pane w1:p2 --direction down --ratio 0.6667" "$HERDR_CALLS"
assert_contains "main pane renamed" "pane rename w1:p1 main" "$HERDR_CALLS"
assert_contains "expert pane renamed" "pane rename w1:p2 expert" "$HERDR_CALLS"
assert_contains "shell pane renamed" "pane rename w1:p3 shell" "$HERDR_CALLS"
assert_contains "pfast pane renamed" "pane rename w1:p4 pfast" "$HERDR_CALLS"
assert_contains "pi starts in the main pane" \
  "agent start main --kind pi --pane w1:p1" "$HERDR_CALLS"
assert_contains "codex starts in the expert pane with the shared lean defaults" \
  'agent start expert --kind codex --pane w1:p2 -- --disable apps --disable browser_use --disable computer_use --disable goals --disable image_generation --disable in_app_browser --disable multi_agent --disable plugins --disable remote_plugin --disable tool_suggest -c agents.enabled=false -c personality="none" -c tool_output_token_limit=4000 -c tools.view_image=false' "$HERDR_CALLS"
assert_contains "fast pi starts in the pfast pane" \
  "agent start pfast --kind pi --pane w1:p4 -- --no-context-files --no-skills --no-extensions --model zai/glm-5.3-flash --thinking low" "$HERDR_CALLS"
assert_contains "summary lists every pane" "w1:p4" "$TMP/out"
assert_not_contains "happy path emits no warnings" "could not start" "$TMP/err"

# Test 2: a herdr response without pane ids falls back to diffing pane list.
reset_fakes
PATH="$FAKE_PATH" FAKE_HERDR_NOJSON=1 "$LAUNCHER" dev > "$TMP/out" 2> "$TMP/err"
assert_equals "fallback parsing exits zero" "0" "$?"
assert_contains "fallback recovers the split pane ids" "w1:p4" "$TMP/out"

# Test 3: without herdr on PATH the command fails with a clear message.
mv "$TMP/bin/herdr" "$TMP/herdr.stash"
PATH="$FAKE_PATH" "$LAUNCHER" dev > "$TMP/out" 2> "$TMP/err"
status=$?
assert_equals "missing herdr exits two" "2" "$status"
assert_contains "missing herdr message" "requires the herdr CLI" "$TMP/err"
mv "$TMP/herdr.stash" "$TMP/bin/herdr"

# Test 4: a failed split aborts with exit two.
reset_fakes
PATH="$FAKE_PATH" FAKE_HERDR_FAIL_SPLIT=1 "$LAUNCHER" dev > "$TMP/out" 2> "$TMP/err"
status=$?
assert_equals "failed split exits two" "2" "$status"
assert_contains "failed split message" "pane split right failed" "$TMP/err"

# Test 5: a failed agent start only warns; the layout still completes and
# the panes are still renamed.
reset_fakes
PATH="$FAKE_PATH" FAKE_HERDR_FAIL_AGENT=1 "$LAUNCHER" dev > "$TMP/out" 2> "$TMP/err"
status=$?
assert_equals "failed agent start exits zero" "0" "$status"
assert_contains "pi start failure warns" "could not start pi" "$TMP/err"
assert_contains "codex start failure warns" "could not start codex" "$TMP/err"
assert_contains "fast pi start failure warns" "could not start fast pi" "$TMP/err"
assert_contains "renames still happen after agent failures" \
  "pane rename w1:p4 pfast" "$HERDR_CALLS"
assert_contains "layout summary still printed" "Dev environment ready" "$TMP/out"

# Test 6: TWOPANE_DEV_PFAST_FLAGS overrides the fast pi flags.
reset_fakes
PATH="$FAKE_PATH" TWOPANE_DEV_PFAST_FLAGS="--model test-fast" \
  "$LAUNCHER" dev > "$TMP/out" 2> "$TMP/err"
assert_contains "pfast flags override reaches the agent start" \
  "agent start pfast --kind pi --pane w1:p4 -- --model test-fast" "$HERDR_CALLS"

# Test 7: EXPERT_FULL bypasses the lean defaults in the dev workspace too.
reset_fakes
PATH="$FAKE_PATH" EXPERT_FULL=1 "$LAUNCHER" dev > "$TMP/out" 2> "$TMP/err"
assert_contains "full mode expert start still targets the expert pane" \
  "agent start expert --kind codex --pane w1:p2" "$HERDR_CALLS"
assert_not_contains "full mode expert start omits lean flags" \
  "--disable apps" "$HERDR_CALLS"

# Test 8: extra arguments are rejected like the other no-argument commands.
PATH="$FAKE_PATH" "$LAUNCHER" dev extra > "$TMP/out" 2> "$TMP/err"
status=$?
assert_equals "extra arguments exit two" "2" "$status"
assert_contains "extra arguments message" "dev accepts no arguments" "$TMP/err"

echo "---"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
