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
(
  cd "$TMP/usage"
  for opt in --help -h --unknown; do
    code=0
    out=$(FM_HC_EFFECTS="$TMP/effects" RUNNER_TEMP="$TMP/usage" \
      PATH="$TMP/no-effects:$PATH" bash "$HC_INSTALLER" "$opt" 2>&1) || code=$?
    case "$opt" in
      --unknown) [ "$code" -ne 0 ] || fail "unknown option unexpectedly succeeded" ;;
      *) [ "$code" -eq 0 ] || fail "$opt failed: $out" ;;
    esac
    assert_contains "$out" 'Usage: fm-install-hc.sh' "$opt reports usage"
  done
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
while [ "$#" -gt 1 ]; do shift; done
cp "$FM_HC_FIXTURE" "$1"
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
# Emulate BSD mkdir's rejection of -- even on hosts with GNU mkdir.
for arg do
  [ "$arg" != -- ] || exit 64
done
exec "$FM_REAL_MKDIR" "$@"
SH
chmod +x "$FAKEBIN/uname" "$FAKEBIN/sha256sum" "$FAKEBIN/mkdir"
(
  cd "$TMP"
  FM_REAL_MKDIR=$(command -v mkdir) FM_HC_FIXTURE="$TMP/asset.tar.gz" \
    PATH="$FAKEBIN:$PATH" RUNNER_TEMP="$TMP" bash "$HC_INSTALLER" './-hc prefix/bin'
)
[ -x "$TMP/-hc prefix/bin/herdr-core" ] || fail 'hc installer did not create the nested prefix and binary'
pass 'hc installs into a nested relative prefix with BSD mkdir semantics'
