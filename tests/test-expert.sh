#!/usr/bin/env bash
# Behavior tests for the ./expert launcher script. Run: tests/test-expert.sh
#
# Fakes replace codex and herdr on PATH, so the tests exercise only the
# script's observable behavior: what the launched harness receives, and
# what happens to the herdr pane.
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/cap"
export CAPTURE_DIR="$TMP/cap"

pass=0
fail=0
assert_contains() { # label needle file
  if grep -qF -- "$2" "$3"; then
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

# Fake harness: records its arguments and AGENT_ROLE, then exits.
cat > "$TMP/bin/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$CAPTURE_DIR/argv"
printf '%s\n' "${AGENT_ROLE:-unset}" > "$CAPTURE_DIR/role"
EOF
chmod +x "$TMP/bin/codex"

# The fake bin shadows codex and herdr; /bin:/usr/bin lets the shebang's
# `env bash` resolve. herdr lives outside these dirs, so it stays absent.
FAKE_PATH="$TMP/bin:/bin:/usr/bin"

# Test 1: with no herdr on PATH, the harness still launches with the role
# announcement prompt and the expert environment.
PATH="$FAKE_PATH" "$REPO_ROOT/expert"
assert_contains "harness receives the role announcement prompt" \
  "Expert session in the two-pane workflow" "$CAPTURE_DIR/argv"
assert_equals "harness environment carries AGENT_ROLE=expert" \
  "expert" "$(cat "$CAPTURE_DIR/role" 2>/dev/null)"

# Fake herdr: records every call, succeeds for `pane current`.
export HERDR_CALLS="$TMP/herdr-calls"
cat > "$TMP/bin/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HERDR_CALLS"
exit 0
EOF
chmod +x "$TMP/bin/herdr"

# Test 2: under herdr, the pane is renamed to expert and the harness still
# launches.
: > "$HERDR_CALLS"
rm -f "$CAPTURE_DIR/argv" "$CAPTURE_DIR/role"
PATH="$FAKE_PATH" "$REPO_ROOT/expert"
assert_contains "pane renamed to expert under herdr" \
  "pane rename expert" "$HERDR_CALLS"
assert_equals "harness still launches under herdr" \
  "expert" "$(cat "$CAPTURE_DIR/role" 2>/dev/null)"

# Test 3: extra arguments pass through to the harness.
rm -f "$CAPTURE_DIR/argv" "$CAPTURE_DIR/role"
PATH="$FAKE_PATH" "$REPO_ROOT/expert" --model test-model
assert_contains "extra arguments pass through to the harness" \
  "--model test-model" "$CAPTURE_DIR/argv"

echo "---"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
