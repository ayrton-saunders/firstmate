#!/usr/bin/env bash
# Behavioral CLI qualification against disposable parents, never live Discord.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-away-notice)
PY314=$(command -v python3.14 || true)
if [ -z "$PY314" ]; then
  printf 'SKIP: private notice fixture requires CPython 3.14\n'
  exit 0
fi
"$PY314" -I "$ROOT/tests/fm-away-notice-fixture.py" "$ROOT" "$TMP_ROOT" "${FM_NOTICE_REAL_SOURCE:-}"
