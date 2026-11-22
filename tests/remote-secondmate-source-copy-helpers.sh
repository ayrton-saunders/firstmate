#!/usr/bin/env bash
# Materialize the remote fixture's tracked source from current working-tree
# bytes; untracked files (including checkout-local scratch) do not belong in it.
fm_fixture_copy_remote_source() (  # <source checkout> <destination>
  set -o pipefail
  git -C "$1" ls-files -z | tar -C "$1" -cf - --null -T - | tar -C "$2" -xf -
)
