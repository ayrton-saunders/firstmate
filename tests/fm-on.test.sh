#!/usr/bin/env bash
# Behavior tests for the generic SSH transport and fixed remote entrypoint.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-on)
# The helper is called in command substitution, so recreate the registered path
# and physicalize macOS's /var -> /private/var alias before transport validation.
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
cleanup() {
  local pid
  touch "$TMP_ROOT/relaunch.release" 2>/dev/null || true
  if [ -n "${relaunch_pid:-}" ]; then wait "$relaunch_pid" 2>/dev/null || true; fi
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid")
    # Stop the detached Linux supervisor's whole process group and wait for its
    # cleanup before removing the fixture tree.
    # shellcheck source=bin/fm-remote-job-lib.sh
    . "$ROOT/bin/fm-remote-job-lib.sh"
    FM_REMOTE_JOB_STATE="$TMP_ROOT/remote-jobs"
    fm_remote_job_stop_worker_tree "$pid" 2>/dev/null || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT
LOCAL_HOME="$TMP_ROOT/local-home"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
TOOL_PROBE_LOG="$TMP_ROOT/tool-probe.log"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
SSH_LOG="$TMP_ROOT/ssh.log"
SSH_COUNT="$TMP_ROOT/ssh.count"
mkdir -p "$LOCAL_HOME/data" "$REMOTE_ROOT/bin" "$REMOTE_HOME"
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
cp "$ROOT/bin/fm-remote-entrypoint.sh" "$ROOT/bin/fm-remote-job-lib.sh" \
  "$ROOT/bin/fm-remote-job-worker.sh" "$REMOTE_ROOT/bin/"

cat > "$REMOTE_ROOT/bin/fm-probe-one.sh" <<'SH'
#!/usr/bin/env bash
set -u
out=$1
rc=$2
shift 2
printf '%s\0' "$@" > "$out"
printf 'stdout: %s args\n' "$#"
printf 'stderr: separate\n' >&2
while IFS= read -r line || [ -n "$line" ]; do printf 'stdin: %s\n' "$line"; done
exit "$rc"
SH
cat > "$REMOTE_ROOT/bin/fm-probe-two.sh" <<'SH'
#!/usr/bin/env bash
printf 'home=%s\nroot=%s\nworker=%s\n' "$FM_HOME" "$FM_ROOT_OVERRIDE" "${FM_REMOTE_JOB_ACTIVE:-}"
if [ -n "${TOP_SECRET:-}" ]; then printf 'secret=leaked\n'; else printf 'secret=absent\n'; fi
SH
cat > "$REMOTE_ROOT/bin/fm-probe-path.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$PATH"
SH
cat > "$REMOTE_ROOT/bin/tasks-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\${FM_REMOTE_JOB_ACTIVE:-absent}" >> "$TOOL_PROBE_LOG"
case "\${1:-}:\${2:-}" in
  --version:*) printf '0.2.6\n' ;;
  update:--help) printf '%s\n' --archive-body ;;
  mv:--help) printf '%s\n' 'usage: tasks-axi mv <id> [<id>...]' ;;
esac
SH
cp "$ROOT/bin/fm-remote-endpoint-lib.sh" "$ROOT/bin/fm-remote-doctor.sh" "$ROOT/bin/fm-tasks-axi-lib.sh" \
  "$ROOT/bin/fm-remote-herdr-owner-lib.sh" "$ROOT/bin/fm-herdr-session-lib.sh" "$ROOT/bin/fm-backend.sh" "$REMOTE_ROOT/bin/"
mkdir -p "$REMOTE_ROOT/bin/backends"
cp "$ROOT/bin/backends/herdr.sh" "$REMOTE_ROOT/bin/backends/herdr.sh"
cat > "$REMOTE_ROOT/bin/fm-mutate.sh" <<'SH'
#!/usr/bin/env bash
printf 'mutation\n' >> "$1"
SH
cat > "$REMOTE_ROOT/bin/fm-remote-secondmate-control.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@"
SH
chmod +x "$REMOTE_ROOT/bin"/*.sh
chmod +x "$REMOTE_ROOT/bin/tasks-axi"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add AGENTS.md bin
git -C "$REMOTE_ROOT" commit -qm 'tracked remote fixture'

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
count=$(cat "$FM_FAKE_SSH_COUNT" 2>/dev/null || echo 0)
printf '%s\n' "$((count + 1))" > "$FM_FAKE_SSH_COUNT"
printf '%s\n' "$*" >> "$FM_FAKE_SSH_LOG"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
case "${FM_FAKE_SSH_MODE:-normal}" in
  unreachable) exit 255 ;;
  ambiguous)
    "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
    exit 255
    ;;
  *) exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@" ;;
esac
SH
chmod +x "$FAKEBIN/fake-ssh"

write_registry() {
  cat > "$LOCAL_HOME/data/secondmates.md" <<EOF
- ios - iOS delivery (host: remote-mac; root: $REMOTE_ROOT; home: $REMOTE_HOME; scope: iOS work; projects: alpha; added 2026-08-02)
EOF
}
write_registry

fm_on() {
  FM_HOME="$LOCAL_HOME" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_SSH_COUNT="$SSH_COUNT" \
  FM_FAKE_SSH_LOG="$SSH_LOG" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  "$ROOT/bin/fm-on.sh" "$@"
}

# The pre-feature user path had no executable transport at all. The regression
# exercises the adopted public surface end to end through a deterministic SSH
# process boundary rather than checking script source. A payload caller passes
# --stdin explicitly; without it the remote command's stdin is /dev/null.
ARGV_ACTUAL="$REMOTE_HOME/argv.bin"
ARGV_EXPECTED="$TMP_ROOT/argv-expected.bin"
# shellcheck disable=SC2016 # Literal shell-looking argv is the injection probe.
printf '%s\0' 'plain' 'two words' '$(touch /tmp/fm-on-injected)' '' $'line one\nline two' > "$ARGV_EXPECTED"
printf 'payload one\npayload two\n' > "$TMP_ROOT/stdin"
set +e
# shellcheck disable=SC2016 # Literal shell-looking argv is the injection probe.
fm_on --stdin ios fm-probe-one.sh "$ARGV_ACTUAL" 23 \
  'plain' 'two words' '$(touch /tmp/fm-on-injected)' '' $'line one\nline two' \
  < "$TMP_ROOT/stdin" > "$TMP_ROOT/stdout" 2> "$TMP_ROOT/stderr"
rc=$?
set -e
[ "$rc" -eq 23 ] || fail "remote exit status was not preserved (got $rc)"
cmp -s "$ARGV_EXPECTED" "$ARGV_ACTUAL" || fail "remote argv boundaries were not preserved byte-for-byte"
assert_grep 'stdout: 5 args' "$TMP_ROOT/stdout" "remote stdout was not preserved"
assert_grep 'stdin: payload one' "$TMP_ROOT/stdout" "remote stdin was not preserved"
assert_grep 'stdin: payload two' "$TMP_ROOT/stdout" "remote stdin lost its second line"
assert_grep 'stderr: separate' "$TMP_ROOT/stderr" "remote stderr was not preserved separately"
assert_absent /tmp/fm-on-injected "shell-looking argv was interpreted"
pass "fm-on --stdin preserves argv, stdin, stdout, stderr, and exit status without shell interpretation"

# Without --stdin the remote command must see EOF even when the caller's own
# stdin holds bytes: staging captures stdin to EOF, so an open caller stream
# must never reach it by default.
set +e
fm_on ios fm-probe-one.sh "$REMOTE_HOME/argv-default.bin" 0 'default-closed' \
  < "$TMP_ROOT/stdin" > "$TMP_ROOT/stdout-default" 2> "$TMP_ROOT/stderr-default"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "the default-closed invocation did not preserve exit status (got $rc)"
if grep -q 'stdin:' "$TMP_ROOT/stdout-default"; then
  fail "caller stdin crossed the transport without --stdin: $(cat "$TMP_ROOT/stdout-default")"
fi
pass "fm-on defaults the remote command's stdin to /dev/null"

# A vanished remote peer must become a bounded ssh failure instead of an
# indefinite hang on a half-open TCP connection, so the existing no-result ->
# reconcile re-arm recovery can self-heal without manual intervention. Assert
# this on the real ssh argv the FM_SSH_BIN process seam captured, never on
# fm-on.sh source text.
LAST_SSH_ARGV=$(tail -n 1 "$SSH_LOG")
DEFAULT_INTERVAL=$(printf '%s\n' "$LAST_SSH_ARGV" | grep -oE 'ServerAliveInterval=[0-9]+' | cut -d= -f2)
DEFAULT_COUNT=$(printf '%s\n' "$LAST_SSH_ARGV" | grep -oE 'ServerAliveCountMax=[0-9]+' | cut -d= -f2)
[ -n "$DEFAULT_INTERVAL" ] || fail "the ssh transport did not arm ServerAliveInterval dead-peer detection"
[ -n "$DEFAULT_COUNT" ] || fail "the ssh transport did not arm ServerAliveCountMax dead-peer detection"
[ "$DEFAULT_INTERVAL" -gt 0 ] || fail "ServerAliveInterval was not a positive interval (got $DEFAULT_INTERVAL)"
[ "$DEFAULT_COUNT" -gt 0 ] || fail "ServerAliveCountMax was not a positive count (got $DEFAULT_COUNT)"
DEFAULT_WINDOW=$((DEFAULT_INTERVAL * DEFAULT_COUNT))
[ "$DEFAULT_WINDOW" -le 120 ] \
  || fail "the default dead-peer detection window is not bounded to a sane ceiling (got ${DEFAULT_WINDOW}s = ${DEFAULT_INTERVAL}s x $DEFAULT_COUNT)"
pass "fm-on arms a bounded SSH dead-peer detection window by default (${DEFAULT_INTERVAL}s x $DEFAULT_COUNT = ${DEFAULT_WINDOW}s)"

: > "$SSH_LOG"
FM_SSH_ALIVE_INTERVAL=7 FM_SSH_ALIVE_COUNT_MAX=2 fm_on ios fm-probe-two.sh >/dev/null
OVERRIDE_ARGV=$(tail -n 1 "$SSH_LOG")
assert_contains "$OVERRIDE_ARGV" 'ServerAliveInterval=7' "FM_SSH_ALIVE_INTERVAL override was not honored on the ssh transport"
assert_contains "$OVERRIDE_ARGV" 'ServerAliveCountMax=2' "FM_SSH_ALIVE_COUNT_MAX override was not honored on the ssh transport"
pass "fm-on's dead-peer detection window is env-overridable"

SSH_CALLS_BEFORE_INVALID=$(cat "$SSH_COUNT")
set +e
INVALID_INTERVAL_OUT=$(FM_SSH_ALIVE_INTERVAL=0 fm_on ios fm-probe-two.sh 2>&1)
INVALID_INTERVAL_RC=$?
INVALID_COUNT_OUT=$(FM_SSH_ALIVE_COUNT_MAX=not-a-number fm_on ios fm-probe-two.sh 2>&1)
INVALID_COUNT_RC=$?
set -e
[ "$INVALID_INTERVAL_RC" -eq 1 ] || fail "a zero FM_SSH_ALIVE_INTERVAL was accepted (got exit $INVALID_INTERVAL_RC)"
[ "$INVALID_COUNT_RC" -eq 1 ] || fail "a non-integer FM_SSH_ALIVE_COUNT_MAX was accepted (got exit $INVALID_COUNT_RC)"
assert_contains "$INVALID_INTERVAL_OUT" 'FM_SSH_ALIVE_INTERVAL must be a positive integer' "invalid interval did not explain its constraint"
assert_contains "$INVALID_COUNT_OUT" 'FM_SSH_ALIVE_COUNT_MAX must be a positive integer' "invalid count did not explain its constraint"
[ "$(cat "$SSH_COUNT")" -eq "$SSH_CALLS_BEFORE_INVALID" ] || fail "invalid keepalive configuration launched ssh"
pass "fm-on rejects invalid dead-peer settings before launching ssh"

out=$(TOP_SECRET='must-not-cross' fm_on remote-mac fm-probe-two.sh)
assert_contains "$out" "home=$REMOTE_HOME" "remote FM_HOME was not explicit"
assert_contains "$out" "root=$REMOTE_ROOT" "remote root was not explicit"
assert_contains "$out" 'secret=absent' "the primary ambient environment crossed the transport"
assert_contains "$out" 'worker=1' "the fixed entrypoint executed outside the remote job worker"
pass "the fixed entrypoint runs every command in the worker's explicit environment"

# The child PATH is the entrypoint's own composition, so it is asserted on the
# PATH a real child receives rather than on the script that builds it. The
# expectation is rebuilt here from the documented contract - fixed head, the
# package-manager directories that exist on this host, fixed tail - so a host
# with nix, homebrew, or neither exercises both the include and omit directions.
ACCOUNT_HOME=$(unset HOME; CDPATH='' cd ~ && pwd -P)
ACCOUNT_USER=$(id -un)
MANAGER_DIRS=(
  "$ACCOUNT_HOME/.asdf/shims"
  "$ACCOUNT_HOME"/.asdf/installs/*/*/bin
  "$ACCOUNT_HOME/.local/share/mise/shims"
  "$ACCOUNT_HOME/.mise/shims"
  "$ACCOUNT_HOME"/.local/share/mise/installs/*/*/bin
  "$ACCOUNT_HOME"/.mise/installs/*/*/bin
)
RESOLVED_DIRS=(
  "$ACCOUNT_HOME/.nix-profile/bin"
  "/etc/profiles/per-user/$ACCOUNT_USER/bin"
  /run/current-system/sw/bin
)
PREFIX_DIRS=(
  /opt/homebrew/bin
  /usr/local/bin
)
DISCOVERED_DIRS=()
OMITTED_DIRS=()
PRESENT_CHECKED=0
ABSENT_CHECKED=0
# fm_remote_job_path_append_if_dir omits a symlinked directory outright, while
# fm_remote_job_path_append_resolved_dir substitutes its physical target and
# still omits the symlink path itself, so each group carries its own helper's
# rule. The loops run in production's append order, because PATH is ordered.
classify_plain_dir() {
  if [ -d "$1" ] && [ ! -L "$1" ]; then
    DISCOVERED_DIRS+=("$1")
    PRESENT_CHECKED=$((PRESENT_CHECKED + 1))
  else
    OMITTED_DIRS+=("$1")
    ABSENT_CHECKED=$((ABSENT_CHECKED + 1))
  fi
}
classify_resolved_dir() {
  local physical
  if [ -d "$1" ] && [ ! -L "$1" ]; then
    DISCOVERED_DIRS+=("$1")
    PRESENT_CHECKED=$((PRESENT_CHECKED + 1))
    return 0
  fi
  OMITTED_DIRS+=("$1")
  physical=$(CDPATH='' cd -- "$1" 2>/dev/null && pwd -P) || physical=
  if [ -d "$physical" ]; then
    DISCOVERED_DIRS+=("$physical")
    PRESENT_CHECKED=$((PRESENT_CHECKED + 1))
  else
    ABSENT_CHECKED=$((ABSENT_CHECKED + 1))
  fi
}
for candidate in "${MANAGER_DIRS[@]}"; do classify_plain_dir "$candidate"; done
for candidate in "${RESOLVED_DIRS[@]}"; do classify_resolved_dir "$candidate"; done
for candidate in "${PREFIX_DIRS[@]}"; do classify_plain_dir "$candidate"; done
EXPECTED_PATH=
expect_dir() {
  case ":$EXPECTED_PATH:" in *":$1:"*) return 0 ;; esac
  EXPECTED_PATH="${EXPECTED_PATH:+$EXPECTED_PATH:}$1"
}
path_has() { case ":$1:" in *":$2:"*) return 0 ;; esac; return 1; }
CHILD_PATH=$(fm_on ios fm-probe-path.sh)
NVM_CHILD_DIRS=()
while IFS= read -r candidate; do
  [ -z "$candidate" ] || NVM_CHILD_DIRS+=("$candidate")
done < <(printf '%s\n' "$CHILD_PATH" | tr ':' '\n' | sed -n "\|^$ACCOUNT_HOME/.nvm/versions/node/[^/]*/bin$|p")
[ "${#NVM_CHILD_DIRS[@]}" -le 1 ] || fail "the child PATH selected more than one nvm version"
expect_dir "$REMOTE_ROOT/bin"
if [ -d "$ACCOUNT_HOME/.local/bin" ] && [ ! -L "$ACCOUNT_HOME/.local/bin" ]; then
  expect_dir "$ACCOUNT_HOME/.local/bin"
fi
for candidate in "${NVM_CHILD_DIRS[@]}"; do expect_dir "$candidate"; done
for candidate in "${DISCOVERED_DIRS[@]}"; do expect_dir "$candidate"; done
for fixed in /usr/bin /bin /usr/sbin /sbin; do expect_dir "$fixed"; done

[ "$CHILD_PATH" = "$EXPECTED_PATH" ] \
  || fail "composed child PATH did not match the portable contract"$'\n'"expected: $EXPECTED_PATH"$'\n'"actual:   $CHILD_PATH"
[ "${CHILD_PATH%%:*}" = "$REMOTE_ROOT/bin" ] || fail "the remote code root's bin was not first on the child PATH"
if [ -d "$ACCOUNT_HOME/.local/bin" ] && [ ! -L "$ACCOUNT_HOME/.local/bin" ]; then
  [ "$(printf '%s' "$CHILD_PATH" | cut -d: -f2)" = "$ACCOUNT_HOME/.local/bin" ] \
    || fail "the account's discovered ~/.local/bin was not second on the child PATH"
else
  path_has "$CHILD_PATH" "$ACCOUNT_HOME/.local/bin" \
    && fail "the account's absent or symlinked ~/.local/bin was added to the child PATH"
fi
case "$CHILD_PATH" in *:/usr/bin:/bin:/usr/sbin:/sbin) ;; *) fail "the child PATH did not end with the portable system tail" ;; esac
DUPES=$(printf '%s\n' "$CHILD_PATH" | tr ':' '\n' | sort | uniq -d)
[ -z "$DUPES" ] || fail "the child PATH repeated entries: $DUPES"
for candidate in "${DISCOVERED_DIRS[@]}"; do
  path_has "$CHILD_PATH" "$candidate" || fail "an existing discovered PATH directory was dropped: $candidate"
done
for candidate in "${OMITTED_DIRS[@]}"; do
  path_has "$CHILD_PATH" "$candidate" && fail "an absent or unresolved PATH directory was added: $candidate"
done
pass "the entrypoint composes a deduplicated discovered child PATH (kept $PRESENT_CHECKED existing, omitted $ABSENT_CHECKED absent)"

WORKER_PID=$(cat "$TMP_ROOT/remote-jobs/worker.pid")
kill -TERM "$WORKER_PID"
for _ in $(seq 1 100); do
  [ ! -f "$TMP_ROOT/remote-jobs/worker.pid" ] && break
  sleep 0.05
done
assert_absent "$TMP_ROOT/remote-jobs/worker.pid" "the worker did not stop for the doctor bootstrap fixture"
set +e
out=$(fm_on ios fm-remote-doctor.sh 2>&1)
set -e
assert_contains "$out" 'check remote-job-worker=fixable:' "read-only doctor did not report the stopped worker"
assert_absent "$TMP_ROOT/remote-jobs/worker.pid" "read-only doctor repaired the stopped worker"
pass "read-only doctor inspects worker gaps over plain SSH without repair"

# The doctor's readiness verdict depends on the host it runs on, which is this
# developer's or runner's real account here, so this transport test asserts only
# what the transport itself owns: the PATH the entrypoint handed the child.
# tests/fm-remote-doctor.test.sh owns the verdict against controlled fixtures.
set +e
out=$(fm_on ios fm-remote-doctor.sh 2>/dev/null)
set -e
assert_contains "$out" "path=$EXPECTED_PATH" "the remote doctor did not report the entrypoint child PATH"
assert_contains "$out" 'entrypoint=yes' "the remote doctor did not detect its entrypoint launch"
assert_contains "$out" 'required git=' "the remote doctor did not report the required tool"
pass "the remote doctor reports the same PATH the entrypoint hands its children"

fm_on ios fm-probe-two.sh >/dev/null
: > "$TOOL_PROBE_LOG"
set +e
out=$(fm_on ios fm-remote-doctor.sh 2>&1)
set -e
assert_contains "$out" 'check remote-job-probe=ok: the remote job worker completed the required-tool probe' \
  "the doctor did not use a completed worker probe for tool readiness"
assert_grep '1' "$TOOL_PROBE_LOG" "the required-tool probe did not execute inside the worker"
assert_not_contains "$(cat "$TOOL_PROBE_LOG")" absent "the bootstrap process probed required tools locally"
pass "the remote doctor derives tool readiness from the installed worker"

DOCTOR_BIN="$TMP_ROOT/doctor-bin"
DOCTOR_HOME="$TMP_ROOT/doctor-home"
mkdir -p "$DOCTOR_BIN" "$DOCTOR_HOME"
ln -sf "$(command -v bash)" "$DOCTOR_BIN/bash"
# Report a non-darwin host so this file keeps testing tool resolution alone and
# never reads or writes the real account's launch agents.
cat > "$DOCTOR_BIN/uname" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = -s ] && { printf 'Linux\n'; exit 0; }
printf 'Linux\n'
SH
chmod +x "$DOCTOR_BIN/uname"
# These tool-resolution assertions require Herdr specifically; the unqualified
# doctor accepts either remote backend, covered by fm-remote-doctor.test.sh.
set +e
out=$(HOME="$DOCTOR_HOME" PATH="$DOCTOR_BIN:/usr/bin:/bin:/usr/sbin:/sbin" "$ROOT/bin/fm-remote-doctor.sh" --backend herdr 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "the remote doctor passed with a missing required tool"
assert_contains "$out" 'required herdr=MISSING' "the remote doctor did not mark a missing required tool"
assert_contains "$out" 'required tasks-axi=MISSING' "the remote doctor did not mark every missing required tool"
assert_contains "$out" 'required tools do not resolve on the remote runtime PATH: herdr tasks-axi treehouse harness' "the remote doctor did not name the missing tools"
assert_contains "$out" '.local/bin' "the remote doctor did not offer the wrapper escape hatch"
ln -sf "$(command -v git)" "$DOCTOR_BIN/git"
# The direct doctor fixture needs the complete required tool set. These stubs
# exercise resolution only; the dedicated doctor suite owns worker and Herdr
# lifecycle behavior against controlled launchctl fixtures.
printf '#!/usr/bin/env bash\nexit 0\n' > "$DOCTOR_BIN/jq"
printf '#!/usr/bin/env bash\nprintf "{\\\"server\\\":{\\\"running\\\":false}}\\n"\n' > "$DOCTOR_BIN/herdr"
cat > "$DOCTOR_BIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  --version:*) printf '0.2.6\n' ;;
  update:--help) printf '%s\n' --archive-body ;;
  mv:--help) printf '%s\n' 'usage: tasks-axi mv <id> [<id>...]' ;;
esac
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$DOCTOR_BIN/treehouse"
printf '#!/usr/bin/env bash\nexit 0\n' > "$DOCTOR_BIN/claude"
chmod +x "$DOCTOR_BIN/jq" "$DOCTOR_BIN/herdr" "$DOCTOR_BIN/tasks-axi" "$DOCTOR_BIN/treehouse" "$DOCTOR_BIN/claude"
set +e
out=$(HOME="$DOCTOR_HOME" PATH="$DOCTOR_BIN:/usr/bin:/bin:/usr/sbin:/sbin" "$ROOT/bin/fm-remote-doctor.sh" --backend herdr 2>&1)
rc=$?
set -e
assert_contains "$out" "required git=$DOCTOR_BIN/git" "the remote doctor did not report where the required tool resolved"
doctor_tmux=$(PATH="$DOCTOR_BIN:/usr/bin:/bin:/usr/sbin:/sbin" command -v tmux 2>/dev/null || true)
if [ -n "$doctor_tmux" ]; then
  assert_contains "$out" "optional tmux=$doctor_tmux" "the remote doctor did not report the resolved optional tool"
else
  assert_contains "$out" 'optional tmux=absent' "the remote doctor did not report an absent optional tool"
fi
assert_contains "$out" "required herdr=$DOCTOR_BIN/herdr" "the remote doctor did not require herdr"
assert_contains "$out" "required tasks-axi=$DOCTOR_BIN/tasks-axi" "the remote doctor did not require compatible tasks-axi"
assert_contains "$out" "required treehouse=$DOCTOR_BIN/treehouse" "the remote doctor did not require treehouse"
assert_contains "$out" "required harness=claude:$DOCTOR_BIN/claude" "the remote doctor did not require a verified harness"
assert_not_contains "$out" 'required tools do not resolve' "a resolved required tool was still reported missing"
pass "the remote doctor reports its required runtime tool set and optional tools"

out=$(fm_on ios fm-probe-two.sh)
assert_contains "$out" "home=$REMOTE_HOME" "first dynamic command stopped resolving"
ARGV_TWO="$REMOTE_HOME/argv-two.bin"
printf 'second command\0' > "$TMP_ROOT/argv-two-expected.bin"
fm_on ios fm-probe-one.sh "$ARGV_TWO" 0 'second command' >/dev/null 2>/dev/null
cmp -s "$TMP_ROOT/argv-two-expected.bin" "$ARGV_TWO" || fail "second dynamic command did not execute"
pass "multiple fm-*.sh executables work without a command table"

for bad in '../fm-probe-one.sh' 'fm-probe-one.sh/extra' 'sh' 'fm-../../bin/sh'; do
  if fm_on ios "$bad" >/dev/null 2>&1; then
    fail "unsafe command name was accepted: $bad"
  fi
done
ln -s fm-probe-one.sh "$REMOTE_ROOT/bin/fm-symlink.sh"
if fm_on ios fm-symlink.sh >/dev/null 2>&1; then
  fail "a symlinked command was accepted"
fi
cat > "$REMOTE_ROOT/bin/fm-untracked.sh" <<'SH'
#!/usr/bin/env bash
printf 'untracked command ran\n'
SH
chmod +x "$REMOTE_ROOT/bin/fm-untracked.sh"
GIT_SHADOW_LOG="$TMP_ROOT/git-shadow.log"
cat > "$REMOTE_ROOT/bin/git" <<'SH'
#!/usr/bin/env bash
printf 'consulted\n' >> "$FM_GIT_SHADOW_LOG"
exit 0
SH
chmod +x "$REMOTE_ROOT/bin/git"
FM_GIT_SHADOW_LOG="$GIT_SHADOW_LOG" "$REMOTE_ROOT/bin/git" -C "$REMOTE_ROOT" ls-files --error-unmatch bin/fm-untracked.sh \
  || fail "the checkout-local git shim did not demonstrate that it would authorize the untracked command"
untracked_root_b64=$(printf '%s' "$REMOTE_ROOT" | base64 | tr -d '\n')
untracked_home_b64=$(printf '%s' "$REMOTE_HOME" | base64 | tr -d '\n')
untracked_argv_b64=$(printf '%s\0' fm-untracked.sh | base64 | tr -d '\n')
set +e
out=$(FM_GIT_SHADOW_LOG="$GIT_SHADOW_LOG" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" "$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  1 "$untracked_root_b64" "$untracked_home_b64" "$untracked_argv_b64" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  fail "an untracked fm-*.sh executable was accepted"
fi
assert_contains "$out" 'command is not tracked by the configured remote root' "the untracked command did not fail at tracked-command authorization"
[ "$(wc -l < "$GIT_SHADOW_LOG" | tr -d ' ')" -eq 1 ] \
  || fail "the tracked-command authorization consulted checkout-local git"
pass "tracked-command authorization excludes checkout-local git"

set +e
out=$(
  # shellcheck disable=SC2329 # Exported for indirect use by fm_on.
  command() {
    if [ "${1:-}" = -v ] && [ "${2:-}" = git ]; then return 1; fi
    builtin command "$@"
  }
  export -f command
  fm_on ios fm-remote-doctor.sh 2>&1
)
set -e
assert_contains "$out" 'mode=check' "the trusted doctor could not bootstrap while git was unavailable"
printf '\n' >> "$REMOTE_ROOT/bin/fm-remote-doctor.sh"
set +e
out=$(
  # shellcheck disable=SC2329 # Exported for indirect use by fm_on.
  command() {
    if [ "${1:-}" = -v ] && [ "${2:-}" = git ]; then return 1; fi
    builtin command "$@"
  }
  export -f command
  fm_on ios fm-remote-doctor.sh 2>&1
)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "an altered doctor bootstrapped without tracked-command validation"
assert_contains "$out" 'doctor does not match the trusted bootstrap identity' \
  "an altered doctor did not fail closed when git was unavailable"
cp "$ROOT/bin/fm-remote-doctor.sh" "$REMOTE_ROOT/bin/fm-remote-doctor.sh"
chmod +x "$REMOTE_ROOT/bin/fm-remote-doctor.sh"
pass "doctor bootstrap remains authenticated when git is unavailable"

if FM_HOME="$LOCAL_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  "$ROOT/bin/fm-on.sh" '-oProxyCommand=bad' fm-probe-two.sh >/dev/null 2>&1; then
  fail "an option-shaped SSH route was accepted"
fi
ssh_before_bad_path=$(cat "$SSH_COUNT")
cat > "$LOCAL_HOME/data/secondmates.md" <<EOF
- ios - iOS delivery (host: remote-mac; root: $REMOTE_ROOT/../remote-root; home: $REMOTE_HOME; scope: iOS work; projects: alpha; added 2026-08-02)
EOF
if fm_on ios fm-probe-two.sh >/dev/null 2>&1; then
  fail "a configured remote root with traversal was accepted"
fi
[ "$(cat "$SSH_COUNT")" -eq "$ssh_before_bad_path" ] || fail "unsafe configured paths reached SSH"
write_registry
pass "transport rejects shell escape, traversal, symlink, and option-injection surfaces"

root_b64=$(printf '%s' "$REMOTE_ROOT" | base64 | tr -d '\n')
home_b64=$(printf '%s' "$REMOTE_HOME" | base64 | tr -d '\n')
argv_b64=$(printf '%s\0' fm-probe-two.sh | base64 | tr -d '\n')
if "$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" 2 "$root_b64" "$home_b64" "$argv_b64" >/dev/null 2>&1; then
  fail "an incompatible transport protocol was accepted"
fi
traversal_root_b64=$(printf '%s' "$REMOTE_ROOT/../remote-root" | base64 | tr -d '\n')
if "$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" 1 "$traversal_root_b64" "$home_b64" "$argv_b64" >/dev/null 2>&1; then
  fail "the fixed entrypoint accepted traversal in the configured root"
fi
pass "the fixed entrypoint refuses incompatible protocols and unsafe roots"

cat >> "$LOCAL_HOME/data/secondmates.md" <<EOF
- build - build delivery (host: remote-mac; root: $REMOTE_ROOT; home: $TMP_ROOT/other-remote-home; scope: build work; projects: beta; added 2026-08-02)
EOF
if fm_on remote-mac fm-probe-two.sh >/dev/null 2>&1; then
  fail "an ambiguous SSH alias was accepted"
fi
out=$(fm_on ios fm-probe-two.sh)
assert_contains "$out" "home=$REMOTE_HOME" "secondmate-id routing broke after alias ambiguity"
write_registry
pass "ambiguous aliases refuse while exact secondmate ids remain routable"

: > "$SSH_COUNT"
set +e
FM_FAKE_SSH_MODE=unreachable fm_on ios fm-mutate.sh "$REMOTE_HOME/mutations" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 255 ] || fail "unreachable transport did not preserve ssh status 255 (got $rc)"
[ "$(cat "$SSH_COUNT")" -eq 1 ] || fail "unreachable transport was retried"
assert_absent "$REMOTE_HOME/mutations" "unreachable transport ran the mutation"

: > "$SSH_COUNT"
set +e
FM_FAKE_SSH_MODE=ambiguous fm_on ios fm-mutate.sh "$REMOTE_HOME/mutations" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 255 ] || fail "ambiguous completion did not surface status 255 (got $rc)"
[ "$(cat "$SSH_COUNT")" -eq 1 ] || fail "ambiguous completion was retried"
[ "$(grep -c mutation "$REMOTE_HOME/mutations")" -eq 1 ] || fail "ambiguous mutation did not execute exactly once"
pass "unreachable and ambiguous transport failures are surfaced without retry"

# Exercise the public parser and encoded route surface without a live server.
. "$ROOT/bin/fm-secondmate-registry-lib.sh"
legacy='- a - A (host: remote-mac; root: /code; home: /a; scope: work; projects: ; added 2026-11-09)'
secondmate_registry_parse_line "$legacy" || fail "legacy route refused"
[ "$SECONDMATE_REGISTRY_SESSION" = fm-remote ] || fail "legacy default changed"
local_line='- a - A (home: /a; scope: work; projects: ; added 2026-11-09)'
secondmate_registry_parse_line "$local_line" || fail "local route refused"
[ -z "$SECONDMATE_REGISTRY_SESSION" ] || fail "local route acquired a session"
for name in fm-one FM.One_2 "$(printf '%064d' 0)"; do
  secondmate_registry_parse_line "${legacy/; scope:/; session: $name; scope:}" || fail "valid name refused: $name"
  [ "$SECONDMATE_REGISTRY_SESSION" = "$name" ] || fail "session not preserved exactly"
done
for name in '' default . .. -option _hidden .hidden 'bad name' 'bad/name' 'a; session: b' "$(printf '%065d' 0)"; do
  if secondmate_registry_parse_line "${legacy/; scope:/; session: $name; scope:}"; then fail "invalid session accepted: $name"; fi
  [ -z "$SECONDMATE_REGISTRY_ID" ] || fail "failed parse retained prior identity"
done
if secondmate_registry_parse_line "${local_line/; scope:/; session: fm-one; scope:}"; then fail "local session accepted"; fi
pass "registry resolves legacy, local and custom sessions and rejects invalid or duplicate fields"
write_registry
saved_line=$(cat "$LOCAL_HOME/data/secondmates.md")
printf '%s\n' "${saved_line/; scope:/; session: Fleet.A; scope:}" > "$LOCAL_HOME/data/secondmates.md"
out=$(fm_on ios fm-remote-secondmate-control.sh state ios)
[ "$out" = $'--herdr-session\nFleet.A\nstate\nios' ] || fail "custom route argv was not injected before existing args: $out"
out=$(fm_on ios fm-remote-secondmate-control.sh send ios --herdr-session)
[ "$out" = $'--herdr-session\nFleet.A\nsend\nios\n--herdr-session' ] || fail "a literal steer body was interpreted as a session override: $out"
ssh_before=$(cat "$SSH_COUNT")
for override in --herdr-session --herdr-session=other; do
  if fm_on ios fm-remote-secondmate-control.sh "$override" other state ios >/dev/null 2>&1; then fail "caller session override accepted"; fi
done
[ "$(cat "$SSH_COUNT")" = "$ssh_before" ] || fail "caller override reached SSH"
# A custom route never retries as legacy against a version without the option.
cat > "$REMOTE_ROOT/bin/fm-remote-secondmate-control.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in --*) exit 2 ;; esac
printf 'legacy-only\n'
SH
if fm_on ios fm-remote-secondmate-control.sh state ios >/dev/null 2>&1; then fail "old remote accepted custom routing"; fi
[ "$(cat "$SSH_COUNT")" -eq "$((ssh_before + 1))" ] || fail "unsupported custom option retried"
write_registry
mkdir -p "$LOCAL_HOME/state"
cat > "$LOCAL_HOME/state/ios.meta" <<EOF
kind=secondmate
endpoint_task_id=ios
remote_host=remote-mac
remote_root=$REMOTE_ROOT
home=$REMOTE_HOME
worktree=$REMOTE_HOME
backend=herdr
remote_backend=herdr
remote_herdr_session=fm-remote
remote_target=fm-remote:pane-a
EOF
out=$(fm_on ios fm-remote-secondmate-control.sh state ios)
[ "$out" = legacy-only ] || fail "legacy transport changed"
for command in fm-remote-doctor.sh fm-remote-file.sh fm-remote-inherit.sh; do
  cat > "$REMOTE_ROOT/bin/$command" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$FM_HOME/legacy-argv"
SH
  chmod +x "$REMOTE_ROOT/bin/$command"
done
git -C "$REMOTE_ROOT" add bin
git -C "$REMOTE_ROOT" commit -qm 'Install legacy wire probes'
for command in fm-remote-doctor.sh fm-remote-file.sh fm-remote-inherit.sh; do
  printf '%s\0' legacy-probe '' 'two words' > "$TMP_ROOT/legacy-expected"
  fm_on ios "$command" legacy-probe '' 'two words' || fail "legacy $command refused"
  cmp -s "$TMP_ROOT/legacy-expected" "$REMOTE_HOME/legacy-argv" || fail "legacy $command arguments changed with published parent"
done
pass "custom argv is route-owned, override refusal precedes SSH, and old remotes never fall back"

cp "$ROOT/bin/"*.sh "$REMOTE_ROOT/bin/"
cp "$ROOT/bin/backends/"*.sh "$REMOTE_ROOT/bin/backends/"
. "$ROOT/tests/remote-herdr-fixture.sh"
install_remote_herdr_fixture "$REMOTE_ROOT" "$TMP_ROOT/herdr.state" "$TMP_ROOT/herdr.log" "$TMP_ROOT/send-fail" "$TMP_ROOT/herdr.sock"
printf 'fixture\n' > "$REMOTE_HOME/AGENTS.md"
mkdir -p "$LOCAL_HOME/state" "$REMOTE_HOME/state/parent-route" "$REMOTE_HOME/bin" "$REMOTE_HOME/config" "$REMOTE_HOME/data"
printf 'ios\n' > "$REMOTE_HOME/.fm-secondmate-home"
git -C "$REMOTE_ROOT" add bin
git -C "$REMOTE_ROOT" commit -qm 'Install execution-boundary fixture'
saved_line=$(cat "$LOCAL_HOME/data/secondmates.md")
printf '%s\n' "${saved_line/; scope:/; session: Fleet.A; scope:}" > "$LOCAL_HOME/data/secondmates.md"
cat > "$LOCAL_HOME/state/ios.meta" <<EOF
kind=secondmate
endpoint_task_id=ios
remote_host=remote-mac
remote_root=$REMOTE_ROOT
home=$REMOTE_HOME
worktree=$REMOTE_HOME
backend=herdr
remote_backend=herdr
remote_herdr_session=Fleet.A
remote_target=Fleet.A:pane-a
EOF
write_endpoint() {
  [ "$1" != fm-remote ] || set -- Fleet.A "$2"
  cat > "$REMOTE_HOME/state/parent-route/ios.meta" <<EOF
backend=herdr
kind=secondmate
home=$REMOTE_HOME
endpoint_task_id=ios
project=firstmate
worktree=$REMOTE_HOME
window=$1:$2
herdr_session=$1
herdr_workspace_id=workspace-a
herdr_tab_id=tab-a
herdr_pane_id=$2
EOF
}
for mismatch in session target backend marker missing kind home worktree duplicate-kind; do
  write_endpoint fm-remote pane-a
  printf 'ios\n' > "$REMOTE_HOME/.fm-secondmate-home"
  case "$mismatch" in
    session) write_endpoint fm-other pane-a ;;
    target) write_endpoint fm-remote pane-b ;;
    backend)
      cat > "$REMOTE_HOME/state/parent-route/ios.meta" <<EOF
backend=rex
kind=secondmate
home=$REMOTE_HOME
endpoint_task_id=ios
project=firstmate
worktree=$REMOTE_HOME
window=11111111-1111-4111-8111-111111111111:33333333-3333-4333-8333-333333333333
rex_session_id=session:11111111-1111-4111-8111-111111111111
rex_window_id=window:22222222-2222-4222-8222-222222222222
rex_block_id=block:33333333-3333-4333-8333-333333333333
rex_server=unix:///tmp/rex-fixture.sock
EOF
      ;;
    kind|home|worktree)
      case "$mismatch" in kind) wrong_value=ship ;; *) wrong_value=/other-home ;; esac
      sed "s|^$mismatch=.*|$mismatch=$wrong_value|" "$REMOTE_HOME/state/parent-route/ios.meta" > "$TMP_ROOT/wrong-ownership"
      mv "$TMP_ROOT/wrong-ownership" "$REMOTE_HOME/state/parent-route/ios.meta"
      ;;
    duplicate-kind) printf 'kind=secondmate\n' >> "$REMOTE_HOME/state/parent-route/ios.meta" ;;
    marker) printf 'other\n' > "$REMOTE_HOME/.fm-secondmate-home" ;;
    missing) rm "$REMOTE_HOME/state/parent-route/ios.meta" ;;
  esac
  cp "$LOCAL_HOME/state/ios.meta" "$TMP_ROOT/parent-before"
  if [ -f "$REMOTE_HOME/state/parent-route/ios.meta" ]; then cp "$REMOTE_HOME/state/parent-route/ios.meta" "$TMP_ROOT/endpoint-before"; fi
  for verb in route capture observe sync update retire; do
    if fm_on ios fm-remote-secondmate-control.sh "$verb" ios >/dev/null 2>&1; then fail "$mismatch identity disagreement allowed $verb"; fi
  done
  if fm_on ios fm-remote-secondmate-control.sh send ios forbidden >/dev/null 2>&1; then fail "$mismatch identity disagreement allowed send"; fi
  if fm_on ios fm-remote-secondmate-control.sh key ios Enter >/dev/null 2>&1; then fail "$mismatch identity disagreement allowed key"; fi
  assert_absent "$REMOTE_HOME/state/parent-route/ios.inbox" "$mismatch identity disagreement wrote an inbox"
  assert_absent "$TMP_ROOT/herdr.log" "$mismatch identity disagreement accessed Herdr"
  cmp -s "$LOCAL_HOME/state/ios.meta" "$TMP_ROOT/parent-before" || fail "identity refusal changed parent evidence"
  if [ "$mismatch" != missing ]; then cmp -s "$REMOTE_HOME/state/parent-route/ios.meta" "$TMP_ROOT/endpoint-before" || fail "identity refusal changed remote evidence"; fi
done
write_endpoint fm-remote pane-a
printf 'ios\n' > "$REMOTE_HOME/.fm-secondmate-home"
route=$(fm_on ios fm-remote-secondmate-control.sh route ios) || fail "matching route refused"
assert_contains "$route" 'target=Fleet.A:pane-a' "matching route returned the wrong target"
body='inherited fixture'
bytes=${#body}
hash=$(printf '%s' "$body" | shasum -a 256 | awk '{print $1}')
for parent_present in yes no; do
  [ "$parent_present" = yes ] || mv "$LOCAL_HOME/state/ios.meta" "$TMP_ROOT/unpublished-parent"
  write_endpoint fm-other pane-a
  if printf '%s' "$body" | fm_on --stdin ios fm-remote-inherit.sh put config/crew-harness "$bytes" "$hash" 1 >/dev/null 2>&1; then fail "contradictory inheritance accepted with parent=$parent_present"; fi
  assert_absent "$REMOTE_HOME/config/crew-harness" "contradictory inheritance wrote config"
  assert_absent "$REMOTE_HOME/config/.fm-inherit-crew-harness.generation" "contradictory inheritance advanced generation"
  if printf '%s' "$body" | fm_on --stdin ios fm-remote-file.sh put state/handoff/fixture.outbox.md 1024 "$bytes" "$hash" 1 >/dev/null 2>&1; then fail "contradictory file write accepted with parent=$parent_present"; fi
  assert_absent "$REMOTE_HOME/state/handoff" "contradictory file write created handoff state"
  printf 'private endpoint data\n' > "$REMOTE_HOME/state/home-summary.json"
  if fm_on ios fm-remote-file.sh get state/home-summary.json >/dev/null 2>&1; then fail "contradictory file read accepted with parent=$parent_present"; fi
  expected_refusal="expected 'Fleet.A'"
  [ "$parent_present" != yes ] || expected_refusal='remote endpoint disagrees with requested target'
  for command in fm-remote-doctor.sh fm-remote-delta-read.sh fm-backlog-receive.sh fm-public-followup-collect.sh fm-x-followup.sh fm-extension.sh fm-startup-memory-budget.sh; do
    if refusal=$(fm_on ios "$command" 2>&1); then fail "contradictory endpoint accepted $command with parent=$parent_present"; fi
    assert_contains "$refusal" "$expected_refusal" "$command failed for a reason other than identity disagreement"
  done
  printf 'schema=fm-remote-home-provision.v1\nid_b64=aW9z\ncharter_b64=Zml4dHVyZQ==\nproject_count=0\n' > "$TMP_ROOT/provision-manifest"
  if refusal=$(fm_on --stdin ios fm-remote-home-provision.sh < "$TMP_ROOT/provision-manifest" 2>&1); then fail "contradictory provisioning accepted with parent=$parent_present"; fi
  assert_contains "$refusal" "$expected_refusal" "provisioning failed for a reason other than identity disagreement"
  assert_absent "$REMOTE_HOME/data/charter.md" "contradictory provisioning wrote charter"
  [ "$parent_present" = yes ] || mv "$TMP_ROOT/unpublished-parent" "$LOCAL_HOME/state/ios.meta"
done
write_endpoint fm-remote pane-a
printf '%s' "$body" | fm_on --stdin ios fm-remote-inherit.sh put config/crew-harness "$bytes" "$hash" 1 >/dev/null || fail "matching inheritance refused"
[ "$(cat "$REMOTE_HOME/config/crew-harness")" = "$body" ] || fail "matching inheritance lost bytes"
[ "$(fm_on ios fm-remote-file.sh get state/home-summary.json)" = 'private endpoint data' ] || fail "matching file read lost bytes"
printf '%s' "$body" | fm_on --stdin ios fm-remote-file.sh put state/handoff/fixture.outbox.md 1024 "$bytes" "$hash" 1 >/dev/null || fail "matching file write refused"
[ "$(cat "$REMOTE_HOME/state/handoff/fixture.outbox.md")" = "$body" ] || fail "matching file write lost bytes"
pass "execution checks protect inheritance and files even before parent publication"

cat > "$REMOTE_ROOT/bin/fm-control.sh" <<SH
#!/usr/bin/env bash
printf 'started\n' > "$TMP_ROOT/relaunch.started"
while [ ! -f "$TMP_ROOT/relaunch.release" ]; do sleep 0.05; done
sed 's/pane-a/pane-b/g' "$REMOTE_HOME/state/parent-route/ios.meta" > "$TMP_ROOT/new-endpoint"
mv "$TMP_ROOT/new-endpoint" "$REMOTE_HOME/state/parent-route/ios.meta"
SH
fm_on ios fm-remote-secondmate-control.sh relaunch ios codex default default > "$TMP_ROOT/relaunch.out" 2> "$TMP_ROOT/relaunch.err" &
relaunch_pid=$!
for ((i=0; i<400; i++)); do
  [ ! -f "$TMP_ROOT/relaunch.started" ] || break
  sleep 0.05
done
[ -f "$TMP_ROOT/relaunch.started" ] || fail "relaunch did not enter the local control boundary"
. "$ROOT/bin/fm-remote-job-lib.sh"
export FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs"
account_home=$(cd ~ && pwd -P)
fm_remote_job_stage "$account_home" "$REMOTE_ROOT" "$REMOTE_HOME" fm-remote-secondmate-control.sh \
  --herdr-session Fleet.A --expected-backend herdr --expected-target Fleet.A:pane-a send ios 'stale queued steer' </dev/null >/dev/null || fail "could not stage queued send"
send_job=$FM_REMOTE_JOB_ID
[ "$(cat "$FM_REMOTE_JOB_JOBS/$send_job/state")" = queued ] || fail "send did not queue behind relaunch"
touch "$TMP_ROOT/relaunch.release"
wait "$relaunch_pid" || fail "ordinary relaunch failed"
relaunch_pid=
assert_grep 'target=Fleet.A:pane-b' "$TMP_ROOT/relaunch.out" "relaunch did not return its new target"
fm_remote_job_wait "$account_home" "$send_job" || fail "queued send did not complete"
[ "$FM_REMOTE_JOB_EXIT" -ne 0 ] || fail "queued send accepted the replaced endpoint"
assert_absent "$REMOTE_HOME/state/parent-route/ios.inbox" "stale queued send wrote an inbox"
assert_absent "$TMP_ROOT/herdr.log" "stale queued send accessed Herdr"
assert_grep 'window=Fleet.A:pane-b' "$REMOTE_HOME/state/parent-route/ios.meta" "refused send changed the replacement endpoint"
fm_remote_job_reap "$account_home" "$send_job" || fail "could not reap refused send"
pass "a send queued behind relaunch refuses its stale target at execution"

rm -rf -- "$REMOTE_HOME"
fm_on ios fm-remote-secondmate-control.sh retire ios | grep -q 'already-retired: ios' || fail "lost retirement response could not reconcile"
assert_absent "$REMOTE_HOME" "retirement reconciliation recreated the removed home"
pass "same-route retirement reconciles a lost response without endpoint evidence"

echo "ALL TESTS PASSED"
