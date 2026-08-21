#!/usr/bin/env bash
# Integration test for the bootstrap installer.
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
TARGET="$TEST_ROOT/project"
mkdir "$TARGET"

if TWOPANE_REPOSITORY="$REPO_ROOT" "$REPO_ROOT/install-2pane.sh" "$TARGET" >/dev/null &&
   [ -x "$TARGET/2pane" ] &&
   [ -f "$TARGET/.agents/skills/two-pane-workflow/SKILL.md" ] &&
   [ -f "$TARGET/.2pane/INBOX.md" ] &&
   grep -Fqx '.2pane/' "$TARGET/.gitignore"; then
  printf 'ok - installer downloads and initializes the workflow\n'
else
  printf 'not ok - installer downloads and initializes the workflow\n'
  exit 1
fi

before="$(cat "$TARGET/.agents/skills/two-pane-workflow/SKILL.md")"
TWOPANE_REPOSITORY="$REPO_ROOT" "$REPO_ROOT/install-2pane.sh" "$TARGET" >/dev/null
after="$(cat "$TARGET/.agents/skills/two-pane-workflow/SKILL.md")"
if [ "$before" = "$after" ] && [ "$(grep -Fxc '.2pane/' "$TARGET/.gitignore")" -eq 1 ]; then
  printf 'ok - reinstall is idempotent\n'
else
  printf 'not ok - reinstall is idempotent\n'
  exit 1
fi
