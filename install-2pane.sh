#!/usr/bin/env bash
# Install 2pane into the current repository.
set -eu

if [ "$#" -gt 1 ]; then
  printf 'Usage: install-2pane.sh [target-directory]\n' >&2
  exit 2
fi

target_dir="$(cd "${1:-.}" && pwd)"
repository="${TWOPANE_REPOSITORY:-https://github.com/aitopnexus/2pane-workflow.git}"
install_dir="$(mktemp -d "${TMPDIR:-/tmp}/2pane-install.XXXXXX")"
staged="$target_dir/.2pane.install.$$"

cleanup() {
  rm -f "$staged"
  rm -rf "$install_dir"
}
trap cleanup EXIT HUP INT TERM

[ ! -e "$target_dir/2pane" ] || [ -f "$target_dir/2pane" ] || {
  printf 'install-2pane: %s/2pane is not a regular file\n' "$target_dir" >&2
  exit 2
}

git clone --quiet --depth 1 "$repository" "$install_dir/source"
install -m 0755 "$install_dir/source/2pane" "$staged"
"$staged" init
mv "$staged" "$target_dir/2pane"
staged=""

printf 'Installed 2pane in %s\n' "$target_dir"
