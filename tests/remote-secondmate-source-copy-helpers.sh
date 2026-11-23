#!/usr/bin/env bash
# Import in the caller's shell, not inside the copy subshell: ShellCheck
# otherwise attributes the scratch library's background launches to that subshell.
# shellcheck source=bin/fm-test-scratch-lib.sh
. "${BASH_SOURCE[0]%/*}/../bin/fm-test-scratch-lib.sh" || return 1

# Use tracked working-tree bytes, not index contents, to test local edits.
# Never copy untracked files or declared scratch, even if scratch was staged.
fm_fixture_copy_remote_source() (  # <source checkout> <destination>
  set -o pipefail
  local path parent
  git -C "$1" ls-files -z | while IFS= read -r -d '' path; do
    fm_test_is_declared_scratch "$1" "$path" && continue
    parent=$path
    while [[ "$parent" == */* ]]; do
      parent=${parent%/*}
      if [ -L "$1/$parent" ]; then
        printf 'fixture source has a symlinked ancestor: %s\n' "$parent" >&2
        exit 1
      fi
    done
    printf '%s\0' "$path"
  done | tar -C "$1" --no-recursion -cf - --null -T - | tar -C "$2" -xf -
)
