#!/usr/bin/env bash
# Materialize the remote fixture's tracked source from current working-tree
# bytes; untracked files (including checkout-local scratch) do not belong in it.
fm_fixture_copy_remote_source() (  # <source checkout> <destination>
  set -o pipefail
  local path parent
  . "${BASH_SOURCE[0]%/*}/../bin/fm-test-scratch-lib.sh" || return 1
  git -C "$1" ls-files -z -- "$fm_test_scratch_exclusion" | while IFS= read -r -d '' path; do
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
