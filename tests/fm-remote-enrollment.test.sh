#!/usr/bin/env bash
# Inactive installed enrollment: real filesystem, kernel locks, process crashes,
# competing reservations and an isolated out-of-tree interpreter. No live tools.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-enrollment)
mkdir -p "$TMP_ROOT"
trap fm_test_cleanup EXIT
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/remote-enrollment.py" "$ROOT" "$TMP_ROOT"
pass "installed enrollment and independent recovery"
