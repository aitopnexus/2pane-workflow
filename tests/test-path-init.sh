#!/usr/bin/env bash
# Integration test for PATH-invoked init (local checkout bootstrap).
set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
BIN="$TEST_ROOT/bin"
TARGET="$TEST_ROOT/project"
mkdir "$BIN" "$TARGET"
ln -s "$REPO_ROOT/2pane" "$BIN/2pane"

run() { # run <target-dir> <command...>
  (cd "$1" && PATH="$BIN:$PATH" 2pane "${@:2}")
}

if run "$TARGET" init >/dev/null &&
   [ -x "$TARGET/2pane" ] &&
   cmp -s "$REPO_ROOT/2pane" "$TARGET/2pane" &&
   [ -f "$TARGET/.agents/skills/two-pane-workflow/SKILL.md" ] &&
   [ -f "$TARGET/.2pane/INBOX.md" ] &&
   grep -Fqx '.2pane/' "$TARGET/.gitignore" &&
   [ ! -e "$TARGET/.2pane.install."* ]; then
  printf 'ok - PATH init installs and initializes the workflow\n'
else
  printf 'not ok - PATH init installs and initializes the workflow\n'
  exit 1
fi

before="$(cat "$TARGET/.agents/skills/two-pane-workflow/SKILL.md")"
if run "$TARGET" init >/dev/null &&
   [ "$(cat "$TARGET/.agents/skills/two-pane-workflow/SKILL.md")" = "$before" ] &&
   [ "$(grep -Fxc '.2pane/' "$TARGET/.gitignore")" -eq 1 ]; then
  printf 'ok - PATH init is idempotent\n'
else
  printf 'not ok - PATH init is idempotent\n'
  exit 1
fi

if (cd "$TARGET" && PATH="$BIN:$PATH" AGENT_ROLE=main 2pane send 'hello') &&
   [ "$(cd "$TARGET" && PATH="$BIN:$PATH" AGENT_ROLE=expert 2pane take)" = "$(printf 'from: main\n\nhello')" ]; then
  printf 'ok - PATH send/take target the current directory\n'
else
  printf 'not ok - PATH send/take target the current directory\n'
  exit 1
fi

# The PATH command is the installed release; a project only receives it when
# init runs. Existing transient state must survive that replacement.
AGENT_ROLE=main run "$TARGET" send 'keep this message'
printf '#!/usr/bin/env bash\nprintf "old executable\\n"\n' > "$TARGET/2pane"
chmod +x "$TARGET/2pane"
if run "$TARGET" init >/dev/null &&
   [ "$("$TARGET/2pane" --version)" = "$(PATH="$BIN:$PATH" 2pane --version)" ] &&
   [ "$(cat "$TARGET/.2pane/INBOX.md")" = "$(printf 'from: main\n\nkeep this message')" ]; then
  printf 'ok - PATH init updates the project executable without changing the inbox\n'
else
  printf 'not ok - PATH init updates the project executable without changing the inbox\n'
  exit 1
fi

printf '#!/usr/bin/env bash\nprintf "previous executable\\n"\n' > "$TARGET/2pane"
chmod +x "$TARGET/2pane"
printf 'custom skill\n' > "$TARGET/.agents/skills/two-pane-workflow/SKILL.md"
if run "$TARGET" init >/dev/null 2>&1; then
  printf 'not ok - failed PATH init preserves the working executable\n'
  exit 1
elif [ "$("$TARGET/2pane")" = 'previous executable' ]; then
  printf 'ok - failed PATH init preserves the working executable\n'
else
  printf 'not ok - failed PATH init preserves the working executable\n'
  exit 1
fi
