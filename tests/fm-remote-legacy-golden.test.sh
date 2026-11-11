#!/usr/bin/env bash
# Frozen no-enrollment route/readiness/sync observations through public libraries.
# FM_CHARACTERIZATION_ROOT is a test-only baseline selection; no remote tools run.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
SUBJECT=${FM_CHARACTERIZATION_ROOT:-$ROOT}
TMP_ROOT=$(fm_test_tmproot fm-remote-legacy-golden)
mkdir -p "$TMP_ROOT/home" "$TMP_ROOT/fakebin"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap fm_test_cleanup EXIT
export HOME="$TMP_ROOT/home"
. "$SUBJECT/bin/fm-secondmate-registry-lib.sh"
{
  secondmate_registry_parse_line '- ios - legacy (host: remote-mac; root: /remote/code; home: /remote/home; scope: delivery; projects: alpha; added 2026-08-02)'
  printf 'route=%s host=%s root=%s home=%s session=%s remote=%s\n' \
    "$SECONDMATE_REGISTRY_ID" "$SECONDMATE_REGISTRY_HOST" "$SECONDMATE_REGISTRY_ROOT" \
    "$SECONDMATE_REGISTRY_HOME" "$SECONDMATE_REGISTRY_SESSION" "$SECONDMATE_REGISTRY_REMOTE"
  secondmate_registry_parse_line '- local - prose (host: not-placement) (home: /local/home; scope: delivery; projects: alpha; added 2026-08-02)'
  printf 'route=%s host=%s root=%s home=%s session=%s remote=%s\n' \
    "$SECONDMATE_REGISTRY_ID" "$SECONDMATE_REGISTRY_HOST" "$SECONDMATE_REGISTRY_ROOT" \
    "$SECONDMATE_REGISTRY_HOME" "$SECONDMATE_REGISTRY_SESSION" "$SECONDMATE_REGISTRY_REMOTE"
} > "$TMP_ROOT/route"
cat > "$TMP_ROOT/route.expected" <<'TXT'
route=ios host=remote-mac root=/remote/code home=/remote/home session=fm-remote remote=1
route=local host= root= home=/local/home session= remote=0
TXT
diff -u "$TMP_ROOT/route.expected" "$TMP_ROOT/route" || fail "legacy route defaults changed"
[ -z "$(find "$HOME" -mindepth 1 -print)" ] || fail "route parsing wrote account state"
pass "no-enrollment route parsing retains its default session and writes no state"

# This stub is the SSH boundary of the real readiness sequencer, not a stub of
# readiness policy: it models the observed remote repair effect and logs argv.
cat > "$TMP_ROOT/fakebin/fm-on.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$READINESS_CALLS"
if [ "$READINESS_MODE" = unreachable ]; then exit 255; fi
case " $* " in
  *' --fix '*) printf 'ready\n' > "$READINESS_EFFECT"; printf 'repair applied\n'; exit 0 ;;
esac
if [ -f "$READINESS_EFFECT" ]; then printf 'checked ready\n'; exit 0; fi
printf 'needs repair\n'
exit 1
SH
chmod +x "$TMP_ROOT/fakebin/fm-on.sh"
export READINESS_CALLS="$TMP_ROOT/calls" READINESS_EFFECT="$HOME/ready" READINESS_MODE=normal
. "$SUBJECT/bin/fm-remote-readiness-lib.sh"
# The function deliberately captures nonzero probe exits; it is a conditional
# command just as in its real callers, so errexit must not interrupt the probe.
if fm_remote_readiness_ensure "$TMP_ROOT/fakebin" ios herdr; then rc=0; else rc=$?; fi
[ "$rc" = 0 ] || fail "readiness repair failed"
printf '%s\n' 'ios fm-remote-doctor.sh --backend herdr' \
  'ios fm-remote-doctor.sh --fix --backend herdr' \
  'ios fm-remote-doctor.sh --backend herdr' > "$TMP_ROOT/calls.expected"
diff -u "$TMP_ROOT/calls.expected" "$READINESS_CALLS" || fail "check/fix/check argv or order changed"
[ "$FM_REMOTE_READINESS_OUT" = 'checked ready' ] || fail "readiness returned a repair assertion instead of read-back"
[ "$(find "$HOME" -mindepth 1 -type f -print)" = "$READINESS_EFFECT" ] || fail "readiness write footprint changed"
[ "$(cat "$READINESS_EFFECT")" = ready ] || fail "readiness repair effect changed"
rm "$READINESS_EFFECT"
: > "$READINESS_CALLS"
READINESS_MODE=unreachable
if fm_remote_readiness_ensure "$TMP_ROOT/fakebin" ios herdr; then rc=0; else rc=$?; fi
[ "$rc" = 255 ] || fail "ambiguous transport failure lost exit 255"
printf '%s\n' 'ios fm-remote-doctor.sh --backend herdr' > "$TMP_ROOT/calls.expected"
diff -u "$TMP_ROOT/calls.expected" "$READINESS_CALLS" || fail "exit 255 was retried or repaired"
[ -z "$(find "$HOME" -mindepth 1 -print)" ] || fail "unreachable readiness wrote state"
pass "no-enrollment readiness preserves check/fix/check effects and never retries exit 255"

# Real standalone fixture repositories, exact-current and clean fast-forward.
fm_git_init_commit "$TMP_ROOT/source"
git -C "$TMP_ROOT/source" config user.name 'Firstmate Tests'
git -C "$TMP_ROOT/source" config user.email tests@example.invalid
printf 'A\n' > "$TMP_ROOT/source/payload"
git -C "$TMP_ROOT/source" add payload
git -C "$TMP_ROOT/source" commit -qm A
git clone -q --no-local "$TMP_ROOT/source" "$TMP_ROOT/destination"
A=$(git -C "$TMP_ROOT/source" rev-parse HEAD)
printf 'B\n' > "$TMP_ROOT/source/payload"
git -C "$TMP_ROOT/source" commit -qam B
B=$(git -C "$TMP_ROOT/source" rev-parse HEAD)
. "$SUBJECT/bin/fm-ff-lib.sh"
FF_IMPORT_FROM="$TMP_ROOT/source"
ff_target "$TMP_ROOT/destination" home "$B" > "$TMP_ROOT/sync"
[ "$FF_STATUS" = updated ] || fail "legacy home did not fast-forward"
[ "$(git -C "$TMP_ROOT/destination" rev-parse HEAD)" = "$B" ] || fail "sync did not select B"
[ "$(cat "$TMP_ROOT/destination/payload")" = B ] || fail "sync ref moved without tree bytes"
before=$(git -C "$TMP_ROOT/destination" rev-parse --short "$A")
after=$(git -C "$TMP_ROOT/destination" rev-parse --short "$B")
printf 'home: updated %s..%s\n' "$before" "$after" > "$TMP_ROOT/sync.expected"
diff -u "$TMP_ROOT/sync.expected" "$TMP_ROOT/sync" || fail "legacy sync output changed"
ff_target "$TMP_ROOT/destination" home "$B" > "$TMP_ROOT/sync"
[ "$FF_STATUS" = current ] || fail "exact-current status changed"
printf 'home: already current\n' > "$TMP_ROOT/sync.expected"
diff -u "$TMP_ROOT/sync.expected" "$TMP_ROOT/sync" || fail "exact-current output changed"
[ -z "$(git -C "$TMP_ROOT/destination" status --porcelain)" ] || fail "sync created extra home state"
[ -z "$(find "$HOME" -mindepth 1 -print)" ] || fail "sync created account configuration"
pass "no-enrollment sync preserves fast-forward/current output, selected bytes and clean home"

# Exercise the actual default queue creation and service path owner without
# overriding the queue, rendering/loading a service, or installing anything.
unset FM_REMOTE_JOB_STATE_ROOT
. "$SUBJECT/bin/fm-remote-job-lib.sh"
fm_remote_job_prepare_state "$HOME"
fm_remote_job_launchagent_paths "$HOME"
printf '%s\n' "state=${FM_REMOTE_JOB_STATE#"$HOME"}" \
  "jobs=${FM_REMOTE_JOB_JOBS#"$HOME"}" "claims=${FM_REMOTE_JOB_SEQ_CLAIMS#"$HOME"}" \
  "label=$FM_REMOTE_JOB_LABEL" "plist=${FM_REMOTE_JOB_LAUNCH_AGENT_PLIST#"$HOME"}" \
  "log=${FM_REMOTE_JOB_LAUNCH_AGENT_LOG#"$HOME"}" > "$TMP_ROOT/queue"
cat > "$TMP_ROOT/queue.expected" <<'TXT'
state=/.firstmate/remote-job
jobs=/.firstmate/remote-job/jobs
claims=/.firstmate/remote-job/.seq-claims
label=dev.firstmate.remote-job
plist=/Library/LaunchAgents/dev.firstmate.remote-job.plist
log=/Library/Logs/dev.firstmate.remote-job.log
TXT
diff -u "$TMP_ROOT/queue.expected" "$TMP_ROOT/queue" || fail "legacy queue default projection changed"
queue_footprint() {
  python3 - "$HOME" <<'PY'
import pathlib
import stat
import sys
home = pathlib.Path(sys.argv[1])
for path in sorted(home.rglob('*')):
    print(str(path.relative_to(home)), 'directory' if path.is_dir() else 'file',
          oct(stat.S_IMODE(path.stat().st_mode)))
PY
}
queue_footprint > "$TMP_ROOT/footprint"
cat > "$TMP_ROOT/footprint.expected" <<'TXT'
.firstmate directory 0o700
.firstmate/remote-job directory 0o700
.firstmate/remote-job/.seq-claims directory 0o700
.firstmate/remote-job/jobs directory 0o700
.firstmate/remote-job/logs directory 0o700
TXT
diff -u "$TMP_ROOT/footprint.expected" "$TMP_ROOT/footprint" || fail "legacy queue write footprint changed"
fm_remote_job_prepare_state "$HOME"
queue_footprint > "$TMP_ROOT/footprint"
diff -u "$TMP_ROOT/footprint.expected" "$TMP_ROOT/footprint" || fail "repeat queue preparation changed its footprint"
pass "no-enrollment queue paths, label, private modes and idempotent write footprint remain unchanged"
