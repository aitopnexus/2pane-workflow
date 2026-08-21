#!/usr/bin/env bash
# Contract checks for the two-pane-workflow skill. Run: tests/test-skill.sh
#
# The frontmatter is the interface both harnesses parse; the checks pin the
# name, the trigger-bearing description, and the role-detection contract.
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
awk '
  /^## Consume a message$/ { in_consume=1; next }
  /^## / && in_consume { in_consume=0 }
  in_consume && /Archive first:/ { archived=NR }
  in_consume && /Empty `.agents\/INBOX.md`/ { cleared=NR }
  in_consume && /Do the work/ { executed=NR }
  END { exit !(archived && cleared && executed && archived < cleared && cleared < executed) }
' "$SKILL"; check "consume archives and clears the message before executing it" $?

echo "---"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
