#!/usr/bin/env bash
# fm-install-herdr.test.sh - exercise the pinned Herdr and Herdr Core
# installers without fetching or installing real release binaries.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-install-herdr)
FAKEBIN=$(fm_fakebin "$TMP")
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in https://*) printf '%s\n' "$arg" > "$FM_CURL_URL_LOG" ;; esac
done
exit 22
SH
chmod +x "$FAKEBIN/curl"

code=0
FM_CURL_URL_LOG="$TMP/url" PATH="$FAKEBIN:$PATH" RUNNER_TEMP="$TMP" \
  bash "$ROOT/bin/fm-install-herdr.sh" "$TMP/dest" 2>"$TMP/err" || code=$?
[ "$code" -ne 0 ] || fail "installer succeeded although the download was refused"
[ -s "$TMP/url" ] || fail "installer requested no release URL: $(cat "$TMP/err")"
case "$(cat "$TMP/url")" in
  https://github.com/herdrdev/herdr/releases/download/v*/herdr-*) ;;
  *) fail "installer requested $(cat "$TMP/url"), not a herdrdev/herdr release asset" ;;
esac
[ ! -e "$TMP/dest/herdr" ] || fail "installer installed a binary after a refused download"
pass "installer downloads the pinned asset from herdrdev/herdr"

HC_INSTALLER="$ROOT/bin/fm-install-hc.sh"
mkdir -p "$TMP/usage" "$TMP/no-effects"
for tool in curl mktemp mkdir; do
  cat > "$TMP/no-effects/$tool" <<'SH'
#!/bin/sh
printf '%s\n' "$0" >> "$FM_HC_EFFECTS"
exit 99
SH
  chmod +x "$TMP/no-effects/$tool"
done
check_hc_usage() {
  local expected=$1 code=0 out
  shift
  out=$(FM_HC_EFFECTS="$TMP/effects" RUNNER_TEMP="$TMP/usage" \
    PATH="$TMP/no-effects:$PATH" bash "$HC_INSTALLER" "$@" 2>&1) || code=$?
  [ "$code" -eq "$expected" ] || fail "hc arguments ($*): expected exit $expected, got $code: $out"
  assert_contains "$out" 'Usage: fm-install-hc.sh' "hc arguments ($*) report usage"
}
(
  cd "$TMP/usage"
  check_hc_usage 0 --help
  check_hc_usage 0 -h
  check_hc_usage 0 --help extra
  check_hc_usage 0 -h extra
  check_hc_usage 1 --unknown
  check_hc_usage 1
  check_hc_usage 1 '' extra
)
[ ! -e "$TMP/effects" ] || fail "usage invoked a side-effecting tool: $(cat "$TMP/effects")"
[ -z "$(find "$TMP/usage" -mindepth 1 -print)" ] || fail 'usage created files'
pass 'hc help and unknown options report usage without download or filesystem effects'

# Stub the release payload and its digest to test the install path offline.
# Real release bytes and checksums are exercised by the tests-hc CI job.
mkdir -p "$TMP/payload"
printf '#!/bin/sh\nprintf "hc 0.1.21\\n"\n' > "$TMP/payload/herdr-core"
tar -czf "$TMP/asset.tar.gz" -C "$TMP/payload" herdr-core
cat > "$FAKEBIN/curl" <<'SH'
#!/bin/sh
while [ "$#" -gt 3 ]; do shift; done
[ "$#" -eq 3 ] &&
  [ "$1" = 'https://releases.herdr.dev/core/0.1.21/herdr-core-macos-aarch64.tar.gz' ] &&
  [ "$2" = -o ] || exit 22
cp "$FM_HC_FIXTURE" "$3"
SH
cat > "$FAKEBIN/uname" <<'SH'
#!/bin/sh
case "$1" in
  -s) echo Darwin ;;
  -m) echo arm64 ;;
  *) exit 1 ;;
esac
SH
cat > "$FAKEBIN/sha256sum" <<'SH'
#!/bin/sh
printf '1ab38dd9270f63a8f794d6d60e8702eb0d1c85a72bda85d735e5eea43f05ffed  %s\n' "$1"
SH
cat > "$FAKEBIN/mkdir" <<'SH'
#!/bin/sh
for arg do
  case "$arg" in
    --*|-*Z*) exit 64 ;;
  esac
done
exec "$FM_REAL_MKDIR" "$@"
SH
chmod +x "$FAKEBIN/uname" "$FAKEBIN/sha256sum" "$FAKEBIN/mkdir"
(
  cd "$TMP"
  FM_REAL_MKDIR=$(command -v mkdir) FM_HC_FIXTURE="$TMP/asset.tar.gz" \
    PATH="$FAKEBIN:$PATH" RUNNER_TEMP="$TMP" bash "$HC_INSTALLER" './-hc prefix/bin' extra
)
[ -x "$TMP/-hc prefix/bin/herdr-core" ] || fail 'hc installer did not create the nested prefix and binary'
pass 'hc installs into a nested relative prefix with BSD mkdir semantics'
