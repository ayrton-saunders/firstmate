#!/usr/bin/env bash
# Shared fake login, transport, code snapshot, and route setup for the remote lifecycle suites.
# shellcheck disable=SC2034
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-secondmate-e2e)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
LOCAL_HOME="$TMP_ROOT/local-home"
REMOTE_ACCOUNT="$TMP_ROOT/remote-account"
REMOTE_TOOLS="$REMOTE_ACCOUNT/.local/bin"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
SSH_COUNT="$TMP_ROOT/ssh.count"
DOCTOR_LOG="$TMP_ROOT/doctor.log"
HERDR_STATE="$TMP_ROOT/remote-herdr.state"
HERDR_LOG="$TMP_ROOT/remote-herdr.log"
REX_FAKE="$TMP_ROOT/remote-rex"
TMUX_LOG="$TMP_ROOT/remote-tmux.log"
TMUX_STATE="$TMP_ROOT/remote-tmux.state"
# One fixture value names the remote route's steering-inbox surface, so the
# charter render assertions and the delivery checks below cannot drift apart.
PARENT_ROUTE_INBOX="$REMOTE_HOME/state/parent-route/ios.inbox"
CLAIMS="$TMP_ROOT/claims"
SID='remote-reply-ios'
NAMING_PARENTS=()
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$REMOTE_ROOT" "$CLAIMS"
cleanup() {
  local status=$? worker_pid='' log
  if [ "$status" -ne 0 ]; then
    for log in "$TMP_ROOT"/remote-jobs/logs/*.log; do
      [ ! -f "$log" ] || tail -n 15 "$log" >&2
    done
  fi
  touch "$TMP_ROOT/provision.release" "$TMP_ROOT/seed.release" "$TMP_ROOT/handoff.release" \
    "$TMP_ROOT/inherit.release" "$TMP_ROOT/launch.release" "$TMP_ROOT/race-clone.release" 2>/dev/null || true
  # A watcher leg cut short by a failed assertion is still polling the root.
  if [ -n "${watch_pid:-}" ]; then
    kill "$watch_pid" 2>/dev/null || true
    wait "$watch_pid" 2>/dev/null || true
  fi
  for parent_cleanup in "$PARENT" "${NAMING_PARENTS[@]+"${NAMING_PARENTS[@]}"}"; do
    FM_HOME="$parent_cleanup" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
      "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  done
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    worker_pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid")
    # The published pid is the serving child; killing it alone lets its
    # detached supervisor restart it while the fixture root is being removed.
    . "$ROOT/bin/fm-remote-job-lib.sh"
    fm_remote_job_stop_worker_tree "$worker_pid" || true
  fi
  if [ -s "$TMP_ROOT/unexpected-tools" ]; then
    printf 'Unexpected fixture tool calls:\n' >&2
    cat "$TMP_ROOT/unexpected-tools" >&2
    fm_test_remove_tree "$TMP_ROOT"
    exit 1
  fi
  fm_test_remove_tree "$TMP_ROOT"
}
trap cleanup EXIT

# The entrypoint deliberately clears HOME before resolving the login home.
# Simulate that lookup in the entrypoint shell only, not in the job payload.
mkdir -p "$REMOTE_TOOLS" "$TMP_ROOT/local-account" || fail 'could not create fixture login homes'
cat > "$TMP_ROOT/fake-login.bash" <<'SH'
unset BASH_ENV
cd() {
  if [ -z "${HOME+x}" ] && [ "$#" -eq 1 ] && [ "$1" = ~ ]; then
    builtin cd -- "${FM_FIXTURE_LOGIN_HOME:?}"
  else
    builtin cd "$@"
  fi
}
SH
cat > "$FAKEBIN/remote-entrypoint" <<SH
#!/usr/bin/env bash
export HOME='$REMOTE_ACCOUNT' FM_FIXTURE_LOGIN_HOME='$REMOTE_ACCOUNT'
BASH_ENV='$TMP_ROOT/fake-login.bash' exec '$BASH' '$REMOTE_ROOT/bin/fm-remote-entrypoint.sh' "\$@"
SH
chmod +x "$FAKEBIN/remote-entrypoint" || fail 'could not install the fake login wrapper'

# The worker rebuilds PATH from the login home and clears its environment.
# Keep Git offline there too, and refuse fallback to any real service tool.
REAL_GIT=$(command -v git) || fail 'git not found'
# Claude trust registration executes Node inside the queued command, including
# when the runner's Node is installed outside the worker's system PATH.
if node_bin=$(command -v node); then
  ln -s "$node_bin" "$REMOTE_TOOLS/node" || fail 'could not expose fixture Node'
fi
cat > "$REMOTE_TOOLS/git" <<SH
#!/usr/bin/env bash
if [ "\${FM_REMOTE_JOB_ACTIVE:-}" = 1 ] && [ "\${HOME:-}" != '$REMOTE_ACCOUNT' ]; then
  printf '%s\n' 'git: remote job escaped its fixture account' >> '$TMP_ROOT/unexpected-tools'
  exit 99
fi
export GIT_ALLOW_PROTOCOL=file GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
exec '$REAL_GIT' "\$@"
SH
cat > "$REMOTE_TOOLS/launchctl" <<SH
#!/usr/bin/env bash
# The migration doctor checks for macOS launch-agent labels even with a Linux
# worker. There are no loaded agents in the fake account.
case "\${1:-}:\${2:-}" in print:gui/"\$(id -u)") exit 1 ;; esac
printf '%s\n' launchctl >> '$TMP_ROOT/unexpected-tools'
exit 99
SH
cat > "$REMOTE_TOOLS/refuse-tool" <<SH
#!/usr/bin/env bash
# Answer bootstrap capability probes offline, without looking up host tools.
case "\${0##*/}:\$*" in
  'treehouse:get --help'|'treehouse:--version'|'no-mistakes:--version'|'gh-axi:--version'|'gh:auth status') exit 1 ;;
esac
printf '%s: %s\n' "\${0##*/}" "\$*" >> '$TMP_ROOT/unexpected-tools'
exit 99
SH
for tool in ssh scp sftp curl wget gh gh-axi herdr tmux rex treehouse no-mistakes; do
  ln -s refuse-tool "$REMOTE_TOOLS/$tool" || fail "could not guard $tool"
done
chmod +x "$REMOTE_TOOLS/git" "$REMOTE_TOOLS/launchctl" "$REMOTE_TOOLS/refuse-tool" \
  || fail 'could not install fixture tool guards'
export HOME="$TMP_ROOT/local-account" PATH="$REMOTE_TOOLS:$PATH" GIT_ALLOW_PROTOCOL=file
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME SSH_AUTH_SOCK

# Materialize the current branch as the remote host's tracked code root. The
# fixture is a real git repository because provisioning and guarded sync exercise
# the same clone and fast-forward path as a second Mac.
# shellcheck source=tests/remote-secondmate-source-copy-helpers.sh
. "$ROOT/tests/remote-secondmate-source-copy-helpers.sh"
fm_fixture_copy_remote_source "$ROOT" "$REMOTE_ROOT" || fail 'could not copy fixture code root'
cat > "$REMOTE_ROOT/bin/tmux" <<SH
#!/usr/bin/env bash
set -u
log='$TMUX_LOG'
state='$TMUX_STATE'
fail_send='$TMP_ROOT/tmux-send-fail'
printf '%s\n' "\$*" >> "\$log"
case "\${1:-}" in
  has-session|new-session|set-window-option) exit 0 ;;
  list-windows)
    [ -f "\$state" ] || exit 0
    name=\$(cut -d'|' -f1 "\$state")
    case "\$*" in *'#{session_name}:#{window_name}'*) printf 'firstmate:%s\n' "\$name" ;; *) printf '%s\n' "\$name" ;; esac
    exit 0
    ;;
  new-window)
    name=; cwd=
    while [ "\$#" -gt 0 ]; do
      case "\$1" in -n) shift; name=\$1 ;; -c) shift; cwd=\$1 ;; esac
      shift
    done
    printf '%s|%s\n' "\$name" "\$cwd" > "\$state"
    printf '@1\n'
    exit 0
    ;;
  display-message)
    case "\$*" in
      *'#{pane_current_path}'*) cut -d'|' -f2- "\$state" ;;
      *'#{pane_current_command}'*) printf 'codex\n' ;;
      *'#{cursor_y}'*) printf '0\n' ;;
      *'#S'*) printf 'firstmate\n' ;;
      *) printf '%%1\n' ;;
    esac
    exit 0
    ;;
  capture-pane) printf '❯\n'; exit 0 ;;
  send-keys) [ ! -f "\$fail_send" ] || exit 1; exit 0 ;;
  kill-window) rm -f -- "\$state"; exit 0 ;;
  list-panes) printf 'codex\n'; exit 0 ;;
esac
exit 0
SH
chmod +x "$REMOTE_ROOT/bin/tmux"
install_remote_herdr_fixture "$REMOTE_ROOT" "$HERDR_STATE" "$HERDR_LOG" \
  "$TMP_ROOT/herdr-send-fail" "$TMP_ROOT/herdr.sock"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add .
git -C "$REMOTE_ROOT" commit -qm 'remote fixture root'
REMOTE_ORIGIN="$TMP_ROOT/firstmate-origin.git"
git init -q --bare "$REMOTE_ORIGIN"
git -C "$REMOTE_ROOT" remote add origin "file://$REMOTE_ORIGIN"
git -C "$REMOTE_ROOT" push -q -u origin main
git --git-dir="$REMOTE_ORIGIN" symbolic-ref HEAD refs/heads/main

create_ios_project() {
# One remote-backed direct-PR project. The remote home clones its origin, never
# the primary working tree.
git init -q --bare "$TMP_ROOT/alpha.git"
git -C "$PARENT/projects" init -q -b main alpha
git -C "$PARENT/projects/alpha" config user.email test@example.com
git -C "$PARENT/projects/alpha" config user.name Test
printf 'alpha\n' > "$PARENT/projects/alpha/README.md"
git -C "$PARENT/projects/alpha" add README.md
git -C "$PARENT/projects/alpha" commit -qm init
git -C "$PARENT/projects/alpha" remote add origin "file://$TMP_ROOT/alpha.git"
git -C "$PARENT/projects/alpha" push -q -u origin main
cat > "$PARENT/data/projects.md" <<EOF
- alpha [direct-PR] - alpha project (added 2026-08-02)
EOF
}
printf 'codex\n' > "$PARENT/config/secondmate-harness"
printf 'tmux\n' > "$PARENT/config/backend"
printf 'primary harness defaults\n' > "$PARENT/config/crew-harness"

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
count=$(cat "$FM_FAKE_SSH_COUNT" 2>/dev/null || echo 0)
printf '%s\n' "$((count + 1))" > "$FM_FAKE_SSH_COUNT"
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
cd "$FM_FAKE_REMOTE_CWD" || exit 93
argv_b64=$4
command_fields=$(perl -MMIME::Base64=decode_base64 -e '
  my $data=decode_base64($ARGV[0]);
  my @args=split(/\0/, $data);
  splice @args, 1, 2 while (($args[1] // "") =~ /^(--herdr-session|--expected-backend|--expected-target|--route-id)$/);
  if ($args[0] eq "fm-remote-secondmate-control.sh" && ($args[1] eq "file" || $args[1] eq "inherit")) {
    my $kind=$args[1];
    splice @args, 0, 3, "fm-remote-$kind.sh";
  }
  print join("\t", map { defined $_ ? $_ : "" } @args[0..2]);
' "$argv_b64")
IFS=$'\t' read -r command_name _command_action command_rel <<EOF
$command_fields
EOF
case "${FM_FAKE_SSH_MODE:-normal}:$command_name:$command_rel" in
  inherit-partial:fm-remote-inherit.sh:config/crew-harness) exit 255 ;;
  inherit-block:fm-remote-inherit.sh:data/captain-shared.md)
    cat > "$FM_FAKE_INHERIT_PAYLOAD"
    touch "$FM_FAKE_INHERIT_ENTERED"
    while [ ! -f "$FM_FAKE_INHERIT_RELEASE" ]; do sleep 0.02; done
    "$FM_FAKE_REMOTE_ENTRYPOINT" "$@" < "$FM_FAKE_INHERIT_PAYLOAD"
    exit $?
    ;;
esac
# The readiness gate is answered here rather than by the real doctor, which
# would inspect and repair the RUNNER's own account. tests/fm-remote-doctor.test.sh
# owns the doctor's real behavior against controlled account fixtures; this
# boundary owns only what the callers do with its verdict.
if [ "$command_name" = fm-remote-doctor.sh ]; then
  printf '%s %s\n' "${FM_FAKE_SSH_MODE:-normal}" "${_command_action:--}" >> "$FM_FAKE_DOCTOR_LOG"
  case "${FM_FAKE_SSH_MODE:-normal}" in
    unreachable) exit 255 ;;
    doctor-route-change)
      perl -pi -e 's/session: fm-fleet-a;/session: fm-other;/' "$FM_FAKE_SESSION_CHANGE_REG"
      printf 'check herdr-server=ok: fixture ready\n'
      exit 0
      ;;
    doctor-fix-unknown)
      if [ "${_command_action:-}" = --fix ]; then
        printf 'fix launchagent=applied: wrote the Aqua-scoped launch agent\n'
        exit 255
      fi
      printf 'check launchagent=fixable: no Firstmate herdr launch agent\n'
      printf 'error: this host is not ready for a remote second mate; unresolved: launchagent\n' >&2
      exit 1
      ;;
    doctor-human)
      printf 'check gui-session=human: no Aqua login session exists for uid 501\n'
      printf 'action: gui-session: log that account in once at the console\n'
      printf 'error: this host is not ready for a remote second mate; unresolved: gui-session\n' >&2
      exit 1
      ;;
    doctor-old)
      # A remote still on the herdr-only doctor exits 2 on the unknown
      # --backend flag; bare calls answer like the normal readiness probe.
      case "${_command_action:-}:${command_rel:-}" in *--backend*) exit 2 ;; esac
      ;;
    doctor-fixable)
      # Red until --fix runs on this host, green on every later read-only run.
      if [ "${_command_action:-}" = --fix ]; then
        touch "$FM_FAKE_DOCTOR_REPAIRED"
        printf 'fix launchagent=applied: wrote the Aqua-scoped launch agent\n'
        printf 'ok: remote second-mate readiness confirmed on this host\n'
        exit 0
      fi
      [ -f "$FM_FAKE_DOCTOR_REPAIRED" ] || {
        printf 'check launchagent=fixable: no Firstmate herdr launch agent\n'
        printf 'error: this host is not ready for a remote second mate; unresolved: launchagent\n' >&2
        exit 1
      }
      ;;
  esac
  printf 'check herdr=ok: /usr/bin/herdr\n'
  printf 'ok: remote second-mate readiness confirmed on this host\n'
  exit 0
fi
if [ "${FM_FAKE_SSH_MODE:-normal}" = doctor-fixable ] \
  && [ "$command_name" = fm-remote-secondmate-control.sh ] \
  && [ "$_command_action" = state ] \
  && [ ! -f "$FM_FAKE_DOCTOR_REPAIRED" ]; then
  printf 'unreadable\n'
  exit 0
fi
case "${FM_FAKE_SSH_MODE:-normal}:$command_name:$command_rel" in
  launch-nonherdr-route:fm-remote-secondmate-control.sh:*)
    [ "$_command_action" = launch ] || exit 93
    printf 'schema=fm-remote-secondmate-control.v1\n'
    printf 'backend=tmux\n'
    printf 'target=firstmate:fm-ios\n'
    printf 'harness=codex\n'
    exit 0
    ;;
  launch-default-session-route:fm-remote-secondmate-control.sh:*)
    [ "$_command_action" = launch ] || exit 93
    printf 'schema=fm-remote-secondmate-control.v1\n'
    printf 'backend=herdr\n'
    printf 'target=default:w1:p2\n'
    printf 'herdr_session=default\n'
    printf 'harness=codex\n'
    exit 0
    ;;
  launch-rex-bad-server-route:fm-remote-secondmate-control.sh:*)
    [ "$_command_action" = launch ] || exit 93
    printf 'schema=fm-remote-secondmate-control.v1\n'
    printf 'backend=rex\n'
    printf 'target=00000001-0000-7000-8000-000000000002:00000002-0000-7000-8000-000000000003\n'
    printf 'rex_session_id=session:00000001-0000-7000-8000-000000000002\n'
    printf 'rex_server=tcp://127.0.0.1:7299\n'
    printf 'harness=codex\n'
    exit 0
    ;;
  launch-rex-mismatched-route:fm-remote-secondmate-control.sh:*)
    [ "$_command_action" = launch ] || exit 93
    printf 'schema=fm-remote-secondmate-control.v1\n'
    printf 'backend=rex\n'
    printf 'target=99999999-0000-7000-8000-000000000009:00000002-0000-7000-8000-000000000003\n'
    printf 'rex_session_id=session:00000001-0000-7000-8000-000000000002\n'
    printf 'rex_server=unix:///tmp/fake-rex.sock\n'
    printf 'harness=codex\n'
    exit 0
    ;;
  provision-block-fail:fm-remote-home-provision.sh:*)
    touch "$FM_FAKE_SEED_ENTERED"
    while [ ! -f "$FM_FAKE_SEED_RELEASE" ]; do sleep 0.02; done
    exit 1
    ;;
  launch-block:fm-remote-secondmate-control.sh:*)
    [ "$_command_action" = launch ] || exit 93
    touch "$FM_FAKE_LAUNCH_ENTERED"
    while [ ! -f "$FM_FAKE_LAUNCH_RELEASE" ]; do sleep 0.02; done
    ;;
esac
case "${FM_FAKE_SSH_MODE:-normal}" in
  unreachable) exit 255 ;;
  ambiguous) "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"; exit 255 ;;
  migration-no-answer)
    if [ "$command_name:$_command_action" = fm-remote-secondmate-control.sh:state ]; then exit 255; fi
    exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@" ;;
  migration-lost-prepare)
    if [ "$command_name:$_command_action" = fm-remote-secondmate-control.sh:migrate-session ]; then
      phase=$(perl -MMIME::Base64=decode_base64 -e 'my @a=split(/\0/,decode_base64($ARGV[0])); print $a[-4]' "$argv_b64")
      if [ "$phase" = prepare ]; then
        output=$("$FM_FAKE_REMOTE_ENTRYPOINT" "$@"); rc=$?
        if [ "$rc" -ne 0 ]; then printf '%s\n' "$output"; exit "$rc"; fi
        exit 255
      fi
    fi
    exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@" ;;

  # The remote retirement really runs, then reports what its forced secondmate
  # teardown reports for a lost child slot: tests/fm-teardown.test.sh owns that
  # remote-side exit 4.
  retire-lost-slot)
    rc=0
    "$FM_FAKE_REMOTE_ENTRYPOINT" "$@" || rc=$?
    if [ "$rc" -eq 0 ] && [ "$command_name:$_command_action" = fm-remote-secondmate-control.sh:retire ]; then
      printf 'warning: treehouse return left pool slot 3 (/remote/slot-3) dirty or unverified; the pool lost this slot. Remaining paths:\n' >&2
      printf '  ?? left-behind-clone/\n' >&2
      printf 'teardown ios finished its cleanup and removed its task record, but a returned pool slot did not come back clean\n' >&2
      exit 4
    fi
    exit "$rc"
    ;;
  *) exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@" ;;
esac
SH
chmod +x "$FAKEBIN/fake-ssh"

publish_healthy_watcher_identity() { # <state> <home> <watch-script>
  local state=$1 home=$2 watch=$3 identity
  identity=$(FM_HOME="$PARENT" FM_STATE_OVERRIDE="$PARENT/state" /bin/bash -c \
    '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$$") \
    || fail "could not derive fixture watcher identity"
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  printf '%s\n' "$home" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$watch" > "$state/.watch.lock/watcher-path"
  touch "$state/.last-watcher-beat"
}

# Every remote leg here runs the real entrypoint and job worker on this
# machine, which on a loaded runner can outlast the production per-mate
# convergence budget; tests/fm-bootstrap-network-parallel.test.sh owns that
# budget's behavior, so this suite gives convergence ample time.
# The inheritance push overlaps its sends to hide real SSH round trips, but
# this fixture's transport has none and its job worker still runs one home's
# commands one at a time, so overlap only adds submission overhead to every
# remote spawn here; the suite sends one item at a time and leaves the
# overlapped scheduler to tests/fm-bootstrap-network-parallel.test.sh.
remote_env() {
  FM_SECONDMATE_CONVERGENCE_TIMEOUT="${FM_SECONDMATE_CONVERGENCE_TIMEOUT:-900}" \
  FM_REMOTE_INHERIT_PUSH_JOBS=1 \
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_SSH_COUNT="$SSH_COUNT" \
  FM_FAKE_REMOTE_ENTRYPOINT="$FAKEBIN/remote-entrypoint" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_FAKE_SSH_MODE="${FM_FAKE_SSH_MODE:-normal}" \
  FM_FAKE_REMOTE_CWD="$TMP_ROOT" \
  FM_FAKE_SEED_ENTERED="$TMP_ROOT/seed.entered" \
  FM_FAKE_SEED_RELEASE="$TMP_ROOT/seed.release" \
  FM_FAKE_DOCTOR_LOG="$DOCTOR_LOG" \
  FM_FAKE_DOCTOR_REPAIRED="$TMP_ROOT/doctor.repaired" \
  FM_FAKE_INHERIT_ENTERED="$TMP_ROOT/inherit.entered" \
  FM_FAKE_INHERIT_RELEASE="$TMP_ROOT/inherit.release" \
  FM_FAKE_INHERIT_PAYLOAD="$TMP_ROOT/inherit.payload" \
  FM_FAKE_LAUNCH_ENTERED="$TMP_ROOT/launch.entered" \
  FM_FAKE_LAUNCH_RELEASE="$TMP_ROOT/launch.release" \
  FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_REMOTE_REPLY_WAIT_SECONDS=10 \
  "$@"
}

reply_owner() {
  remote_env "$ROOT/bin/fm-procevent.sh" list 2>/dev/null \
    | awk -v id="$SID" 'NR > 1 && $1 == id { print $3; exit }'
}

await_reply_result() { # <result-path>
  local result=$1 handled=${1%.result}.handled _
  if [ "$(reply_owner)" != live ]; then
    remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 &
  fi
  for _ in $(seq 1 800); do
    [ -s "$result" ] && [ -f "$handled" ] && return 0
    sleep 0.05
  done
  return 1
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

# The correlation token of the newest record in the remote secondmate's
# steering inbox: a remote steer is delivered as a durable record there, so
# the corr a reply must echo is read from the record body, never from typed
# pane bytes.
newest_remote_inbox_corr() {
  grep -Eoh 'corr=[a-f0-9]{16}' "$PARENT_ROUTE_INBOX"/*.msg 2>/dev/null \
    | tail -1 | cut -d= -f2-
}

seed_env() {
  FM_HOME="$TMP_ROOT/seed-parent" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_SSH_COUNT="$SSH_COUNT" \
  FM_FAKE_REMOTE_ENTRYPOINT="$FAKEBIN/remote-entrypoint" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_FAKE_SSH_MODE="${FM_FAKE_SSH_MODE:-normal}" \
  FM_FAKE_REMOTE_CWD="$TMP_ROOT" \
  FM_FAKE_SEED_ENTERED="$TMP_ROOT/seed.entered" \
  FM_FAKE_SEED_RELEASE="$TMP_ROOT/seed.release" \
  FM_FAKE_DOCTOR_LOG="$DOCTOR_LOG" \
  FM_FAKE_DOCTOR_REPAIRED="$TMP_ROOT/doctor.repaired" \
  "$@"
}

add_local_route() {
  # Add one local route to prove mixed fleets remain parseable and projected.
  mkdir -p "$LOCAL_HOME/data" "$LOCAL_HOME/state" "$LOCAL_HOME/config" "$LOCAL_HOME/projects" "$LOCAL_HOME/bin"
  printf 'local\n' > "$LOCAL_HOME/.fm-secondmate-home"
  printf 'fixture\n' > "$LOCAL_HOME/AGENTS.md"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$LOCAL_HOME/data/backlog.md"
  cat >> "$PARENT/data/secondmates.md" <<EOF
- local - Local delivery (home: $LOCAL_HOME; scope: local work; projects: alpha; added 2026-08-02)
EOF
}

launch_ios_route() {
  create_ios_project
  FM_SECONDMATE_CHARTER='Own iOS delivery on the build Mac.' \
    FM_SECONDMATE_SCOPE='iOS implementation and Xcode validation' \
    remote_env "$ROOT/bin/fm-remote-home-seed.sh" ios remote-mac "$REMOTE_ROOT" "$REMOTE_HOME" alpha >/dev/null \
    || fail 'could not provision the ios fixture route'
  printf 'pi\n' > "$PARENT/config/crew-harness"
  remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate >/dev/null || fail 'could not launch the ios fixture route'
  publish_healthy_watcher_identity "$PARENT/state" "$PARENT" "$ROOT/bin/fm-watch.sh"
  [ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = alive ] \
    || fail 'the ios fixture route did not report alive'
}

resolve_ios_pending() {
  local pending_record pending_corr pending_result pending_seq before_results now_results pending_seen
  for pending_record in "$PARENT/state/pending-replies"/*; do
    [ -f "$pending_record" ] || continue
    [ "$(grep '^task_id=' "$pending_record" | cut -d= -f2-)" = ios ] || continue
    [ "$(grep '^phase=' "$pending_record" | cut -d= -f2-)" != resolved ] || continue
    pending_corr=$(basename "$pending_record")
    before_results=$(find "$PARENT/state/procevent-inbox" -name "$SID.*.result" 2>/dev/null | wc -l | tr -d ' ')
    printf 'done [corr=%s]: concurrent inherited data re-read\n' "$pending_corr" \
      >> "$REMOTE_HOME/state/parent-replies.status"
    if [ "$(reply_owner)" != live ]; then
      remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 &
    fi
    pending_seen=0
    for _ in $(seq 1 800); do
      now_results=$(find "$PARENT/state/procevent-inbox" -name "$SID.*.result" 2>/dev/null | wc -l | tr -d ' ')
      pending_result=$(find "$PARENT/state/procevent-inbox" -name "$SID.*.result" -print 2>/dev/null | sort | tail -1)
      if [ "$now_results" -gt "$before_results" ] && [ -n "$pending_result" ] \
        && [ -f "${pending_result%.result}.handled" ]; then
        pending_seen=1
        break
      fi
      sleep 0.05
    done
    [ "$pending_seen" -eq 1 ] \
      || fail "remote reply source did not capture a concurrent inheritance acknowledgment"
    pending_result=$(find "$PARENT/state/procevent-inbox" -name "$SID.*.result" -print | sort | tail -1)
    pending_seq=${pending_result%.result}
    pending_seq=${pending_seq##*.}
    remote_env "$ROOT/bin/fm-procevent-remote-reply.sh" handle ios "$pending_seq" "$pending_result" >/dev/null \
      || fail "concurrent inheritance acknowledgment was not ingested"
  done
}
