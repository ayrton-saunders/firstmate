#!/usr/bin/env bash
# Inactive 3a typed/installed owner and entry-before-read acceptance fixtures.
# No fleet, launchd, SSH, Herdr, inherited consumer or real adapter is used.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-root-capability)
mkdir -p "$TMP_ROOT"
trap fm_test_cleanup EXIT
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/remote-capability.py" "$ROOT" "$TMP_ROOT"
pass "typed installed admission and entry-before-read owner slice"
