#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=~/.no-mistakes/evidence/01M7EJ8EGP7SGKBS62QMSTEMFE
D="$ROOT/.test-disposable/live-routing"
mkdir -p "$D" "$D/tmp" "$D/local/data" "$D/account"
export TMPDIR="$D/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM
. "$ROOT/bin/fm-remote-job-lib.sh"
export FM_REMOTE_JOB_STATE_ROOT="$D/queue" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
cleanup() {
  if [ -f "$D/queue/worker.pid" ]; then
    FM_REMOTE_JOB_STATE="$D/queue"
    fm_remote_job_stop_worker_tree "$(<"$D/queue/worker.pid")"
  fi
}
trap cleanup EXIT
for source in fork-source firstmate-source; do
  mkdir -p "$D/$source"
  cp -R "$ROOT/bin" "$D/$source/bin"
  printf 'Disposable Firstmate code root\n' > "$D/$source/AGENTS.md"
  git -C "$D/$source" init -q -b main
  git -C "$D/$source" add bin AGENTS.md
  git -C "$D/$source" -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit -qm fixture
 done
for route in personal fpl; do
  mkdir -p "$D/$route-home/config" "$D/$route-home/data" "$D/$route-home/state"
  printf '%s\n' "$D/$route-export" > "$D/$route-home/config/record-export-root"
  printf '# Disposable %s backlog\n\n- synthetic preserved work item\n' "$route" > "$D/$route-home/data/backlog.md"
done
printf -- '- personal - fixture (host: synthetic-harbour; root: %s/fork-source; home: %s/personal-home; session: fm-remote-personal; scope: personal; projects: alpha; added 2026-08-02)\n' "$D" "$D" > "$D/local/data/secondmates.md"
printf -- '- fpl - fixture (host: synthetic-harbour; root: %s/firstmate-source; home: %s/fpl-home; scope: fpl; projects: beta; added 2026-08-02)\n' "$D" "$D" >> "$D/local/data/secondmates.md"
cat > "$D/local-transport" <<'SH'
#!/usr/bin/env bash
set -eu
while [ "$1" != -- ]; do [ "$1" = -o ]; shift 2; done
shift
[ "$1" = synthetic-harbour ]; shift
[ "$1" = fm-remote-entrypoint.sh ]; shift
printf 'Local process transport (not SSH): root=%s home=%s\n' "$(printf %s "$2" | base64 --decode)" "$(printf %s "$3" | base64 --decode)" >&2
exec "$LOCAL_REAL_ENTRYPOINT" "$@"
SH
chmod +x "$D/local-transport"
export FM_HOME="$D/local" FM_SSH_BIN="$D/local-transport" LOCAL_REAL_ENTRYPOINT="$ROOT/bin/fm-remote-entrypoint.sh"
printf 'Surface: real fm-on -> real entrypoint -> real worker -> real record export, synthetic local process transport. No Harbour access.\n'
. "$ROOT/bin/fm-secondmate-registry-lib.sh"
while IFS= read -r line; do
  secondmate_registry_parse_line "$line"
  printf 'Parsed route=%s source=%s home=%s session=%s\n' "$SECONDMATE_REGISTRY_ID" "$SECONDMATE_REGISTRY_ROOT" "$SECONDMATE_REGISTRY_HOME" "$SECONDMATE_REGISTRY_SESSION"
done < "$D/local/data/secondmates.md"
for route in personal fpl personal; do
  printf '\n$ bin/fm-on.sh %s fm-record-export.sh sync\n' "$route"
  "$ROOT/bin/fm-on.sh" "$route" fm-record-export.sh sync
  printf 'exit=0; persisted %s-export/live/data/backlog.md:\n' "$route"
  python3 - "$D/$route-export/live/data/backlog.md" "$D/$route-home/data/backlog.md" <<'PY'
import pathlib, sys
actual, expected = map(pathlib.Path, sys.argv[1:])
assert actual.read_bytes() == expected.read_bytes(), 'export selected the wrong remote home'
print(actual.read_text(), end='')
PY
done
printf '\n$ bin/fm-on.sh synthetic-harbour fm-record-export.sh sync\n'
set +e
"$ROOT/bin/fm-on.sh" synthetic-harbour fm-record-export.sh sync
rc=$?
set -e
printf 'exit=%s\n' "$rc"
[ "$rc" = 1 ]
printf '\n$ bin/fm-remote-entrypoint.sh 2 invalid-root invalid-home invalid-payload\n'
mkdir "$D/reject-home" "$D/reject-staging"
set +e
HOME="$D/reject-home" TMPDIR="$D/reject-staging" "$ROOT/bin/fm-remote-entrypoint.sh" 2 invalid-root invalid-home invalid-payload
rc=$?
set -e
printf 'exit=%s\n' "$rc"
[ "$rc" = 64 ]
python3 - "$D/reject-home" "$D/reject-staging" <<'PY'
import pathlib, sys
for p in map(pathlib.Path, sys.argv[1:]):
    assert not list(p.iterdir()), 'rejected protocol created state'
print('Protocol 2 rejected before payload decoding; no account or staging state created.')
PY
cleanup
trap - EXIT
printf '\nDisposable queue worker stopped.\n'
