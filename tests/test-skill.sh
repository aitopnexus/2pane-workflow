#!/usr/bin/env bash
# Contract checks for the two-pane-workflow skill. Run: tests/test-skill.sh
#
# The frontmatter is the interface both harnesses parse; the checks pin the
# name, trigger, role contract, and delegation to the deterministic helper.
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$REPO_ROOT/.agents/skills/two-pane-workflow/SKILL.md"

pass=0
fail=0
check() { # label exit-code
  if [ "$2" -eq 0 ]; then
    pass=$((pass + 1)); echo "ok - $1"
  else
    fail=$((fail + 1)); echo "not ok - $1"
  fi
}

[ -f "$SKILL" ]; check "skill exists at the spec path .agents/skills/two-pane-workflow" $?
head -1 "$SKILL" | grep -q '^---$'; check "frontmatter opens with a YAML delimiter" $?
awk '/^---$/{c++} c==1' "$SKILL" | grep -q '^name: two-pane-workflow$'; check "frontmatter declares the skill name" $?
awk '/^---$/{c++} c==1' "$SKILL" | grep -q '^description: .*\binbox\b'; check "description carries the inbox trigger branch" $?
grep -q 'AGENT_ROLE' "$SKILL"; check "body detects the role via AGENT_ROLE" $?
grep -q '\./two-pane take' "$SKILL"; check "consume delegates to two-pane take" $?
grep -q '\./two-pane send' "$SKILL"; check "writes delegate to two-pane send" $?
grep -q 'slot check replaces another read' "$SKILL"; check "reply avoids a redundant inbox read" $?
grep -q 'Yield after a successful send' "$SKILL"; check "send yields instead of polling" $?
grep -q 'only the requested result fields' "$SKILL"; check "reply stays scoped to requested fields" $?

echo "---"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
