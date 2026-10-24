#!/usr/bin/env bash
set -eu
ROOT=$PWD
HOME_FIXTURE="$ROOT/.validation-tmp/live-home"
mkdir -p "$HOME_FIXTURE/config" "$HOME_FIXTURE/state"
trap 'chmod 700 "$HOME_FIXTURE/config" 2>/dev/null || true; chmod 600 "$HOME_FIXTURE/config/secondmate-harness" 2>/dev/null || true; rm -rf "$HOME_FIXTURE"' EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME="$HOME_FIXTURE"
printf 'codex\n' > "$FM_HOME/config/crew-harness"
printf 'codex default-model high\nmate demo: claude pinned-model medium\n' > "$FM_HOME/config/secondmate-harness"
check() { local expected=$1; shift; local actual; actual=$("$@"); printf '$ %s\n%s\n' "$*" "$actual"; [ "$actual" = "$expected" ]; }
refuse() { local out rc; set +e; out=$("$@" 2>&1); rc=$?; set -e; printf '$ %s\n%s\nexit=%s\n' "$*" "$out" "$rc"; [ "$rc" -ne 0 ]; }
printf '\n== Per-mate profile preserves all three axes ==\n'
check claude bin/fm-harness.sh secondmate demo
check pinned-model bin/fm-harness.sh secondmate-model demo
check medium bin/fm-harness.sh secondmate-effort demo
check codex bin/fm-harness.sh secondmate other
check default-model bin/fm-harness.sh secondmate-model other
printf '\n== Invalid duplicate override refuses even an unrelated mate ==\n'
printf 'mate demo: pi other-model high\n' >> "$FM_HOME/config/secondmate-harness"
for verb in secondmate secondmate-model secondmate-effort; do refuse bin/fm-harness.sh "$verb" other; done
printf 'mate demo: claude pinned-model medium\n' > "$FM_HOME/config/secondmate-harness"
printf '\n== Unreadable pin refuses every read ==\n'
chmod 000 "$FM_HOME/config/secondmate-harness"
for verb in secondmate secondmate-model secondmate-effort; do refuse bin/fm-harness.sh "$verb" demo; done
chmod 600 "$FM_HOME/config/secondmate-harness"
printf '\n== Inaccessible parent refuses rather than using crew fallback ==\n'
chmod 000 "$FM_HOME/config"
for verb in secondmate secondmate-model secondmate-effort; do refuse bin/fm-harness.sh "$verb" demo; done
chmod 700 "$FM_HOME/config"
printf '\n== Genuine missing pin retains crew fallback and empty optional axes ==\n'
rm "$FM_HOME/config/secondmate-harness"
check codex bin/fm-harness.sh secondmate demo
check '' bin/fm-harness.sh secondmate-model demo
check '' bin/fm-harness.sh secondmate-effort demo
printf '\n== Read-only capacity counts work separately from secondmates ==\n'
printf 'kind=ship\n' > "$FM_HOME/state/work.meta"
printf 'kind=scout\n' > "$FM_HOME/state/scout.meta"
printf 'kind=secondmate\n' > "$FM_HOME/state/mate.meta"
before=$(find "$FM_HOME" -type f -exec cksum {} \; | sort)
out=$(bin/fm-capacity.sh); printf '$ bin/fm-capacity.sh\n%s\n' "$out"
[[ "$out" == *'reason=no-target lanes=2 target=none secondmates=1 '* ]]
printf '4\n' > "$FM_HOME/config/lane-capacity"
out=$(bin/fm-capacity.sh); printf '$ bin/fm-capacity.sh (target=4)\n%s\n' "$out"
[[ "$out" == *'lanes=2 target=4 secondmates=1 '* ]]
rm "$FM_HOME/config/lane-capacity"
after=$(find "$FM_HOME" -type f -exec cksum {} \; | sort)
[ "$before" = "$after" ]
printf '\n== Invalid capacity is refused, never guessed ==\n'
printf 'oops\n' > "$FM_HOME/config/lane-capacity"
refuse bin/fm-capacity.sh
printf '\nAll direct CLI assertions satisfied; disposable home removed on exit.\n'
