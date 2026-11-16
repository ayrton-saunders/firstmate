#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=~/.no-mistakes/evidence/01M7JRB8435J5KB0GTBFH3EVVX
D="$E/scratch/live-capture"
mkdir -p "$D"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_ROOT FM_HOME
export FM_PROCEVENT_CLAIM_ROOT="$D/claims"
P="$ROOT/bin/fm-procevent.sh"
HOST="$ROOT/bin/fm-extension.mjs"
pids=()
cleanup() {
  for pid in "${pids[@]}"; do kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
  chmod -R u+w "$D"
  rm -rf "$D"
}
trap cleanup EXIT
cp -R "$ROOT/docs/examples/process-event-extension" "$D/package"
chmod 755 "$D/package" "$D/package/file-signal.mjs"
chmod 644 "$D/package/firstmate-extension.json"
export FM_HOME="$D/home"
mkdir -p "$FM_HOME"
"$HOST" bind "$D/package" --adapter file-signal --trust-same-user-code --consent artifact-references
for id in first second; do
  "$P" register-extension file-signal "live-$id" --config-ref "file:$D/$id.txt"
done
printf '\nBefore concurrent starts: capture directories absent\n'
test ! -e "$FM_HOME/state/procevent-capture-reservations"
test ! -e "$FM_HOME/state/procevent-inbox"
for id in first second; do
  "$P" start "live-$id" > "$D/$id.start.log" 2>&1 &
  pids+=("$!")
done
sleep 1
printf 'first concurrent external result\n' > "$D/first.txt"
printf 'second concurrent external result\n' > "$D/second.txt"
for pid in "${pids[@]}"; do wait "$pid"; done
pids=()
for id in first second; do
  printf '\nRunner %s output:\n' "$id"
  tail -10 "$D/$id.start.log"
  result="$FM_HOME/state/procevent-inbox/live-$id.1.result"
  printf 'Captured evidence: '; tr '\n' ' ' < "$result"; printf '\n'
  grep -q "$id concurrent external result" "$result"
  "$P" classify "$result"
  "$P" handled "live-$id" 1
  test -f "$FM_HOME/state/procevent-inbox/live-$id.1.handled"
  test ! -f "$FM_HOME/state/procevent/live-$id.source"
done
python3 - "$FM_HOME/state" <<'PY'
import os,stat,sys
for name in ['procevent-capture-reservations','procevent-inbox']:
 p=os.path.join(sys.argv[1],name); s=os.lstat(p)
 print(f'{name}: physical_directory={stat.S_ISDIR(s.st_mode)} mode={stat.S_IMODE(s.st_mode):04o} uid={s.st_uid}')
 assert stat.S_ISDIR(s.st_mode) and stat.S_IMODE(s.st_mode)==0o700 and s.st_uid==os.getuid()
PY
# A hostile capture boundary must never be accepted, regardless of why mkdir loses.
for boundary in procevent-capture-reservations procevent-inbox; do
  for shape in symlink file mode755; do
    export FM_HOME="$D/$boundary-$shape"
    mkdir -p "$FM_HOME"
    "$HOST" bind "$D/package" --adapter file-signal --trust-same-user-code --consent artifact-references > /dev/null
    "$P" register-extension file-signal guard-source --config-ref "file:$D/first.txt" > /dev/null
    path="$FM_HOME/state/$boundary"
    case "$shape" in
      symlink) mkdir -m 700 "$D/outside-$boundary"; ln -s "$D/outside-$boundary" "$path" ;;
      file) printf 'sentinel\n' > "$path" ;;
      mode755) mkdir -m 755 "$path" ;;
    esac
    set +e
    "$P" start guard-source > "$D/guard.log" 2>&1
    rc=$?
    set -e
    printf '\nUnsafe %s %s: start exit=%s\n' "$boundary" "$shape" "$rc"
    tail -5 "$D/guard.log"
    test "$rc" -ne 0
    test ! -f "$FM_HOME/state/procevent-inbox/guard-source.1.result"
    python3 - "$path" "$shape" <<'PY'
import os,stat,sys
p,shape=sys.argv[1:];s=os.lstat(p)
if shape=='symlink': assert stat.S_ISLNK(s.st_mode) and not os.listdir(os.readlink(p))
elif shape=='file': assert open(p).read()=='sentinel\n'
else: assert stat.S_ISDIR(s.st_mode) and stat.S_IMODE(s.st_mode)==0o755
print('Unsafe boundary unchanged; no captured result or outside write')
PY
  done
done
printf '\nLive capture and guard checks complete.\n'
