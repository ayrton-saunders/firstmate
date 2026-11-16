#!/usr/bin/env bash
# Explicit remote session migration, with durable per-operation intent records.
# Usage: fm-remote-session-migrate.sh ID SESSION
#        fm-remote-session-migrate.sh ID --reverse
# --reverse repoints to the previous session in the latest completed intent.
# The code root and mate home never move. Old sessions and terminals stay intact.
# A source agent must have positive semantic idle evidence before plain exit;
# busy/unresponsive/unknown sources refuse without interrupting or forcing.
# Preparation precedes publication. During cross-host publication ordinary route
# access refuses; replaying the same operation completes immutable snapshots.
# No journal, custody record, pin, instructions or project data is migrated.
set -eu
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}
FM_HOME=${FM_HOME:-$FM_ROOT}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
[ "$#" -eq 2 ] || die 'usage: fm-remote-session-migrate.sh ID SESSION | ID --reverse'
ID=$1; TARGET=$2; shift 2
REVERSE=0
if [ "$TARGET" = --reverse ]; then
  [ "$#" = 0 ] || die '--reverse takes no target overrides'
  REVERSE=1
else
  fm_remote_herdr_session_validate "$TARGET" || die 'invalid Herdr session: 1-64 ASCII bytes, alphanumeric first, then letters/digits/./_/-; not default'
fi
case "$ID" in ''|*[!A-Za-z0-9._-]*) die 'invalid secondmate id' ;; esac
# Load stateful helpers only after the explicit name and id pass validation.
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
REG="$DATA/secondmates.md"; META="$STATE/$ID.meta"
BASE="$STATE/.remote-session-migration-$ID"; ACTIVE="$BASE/active"; INTENT="$BASE/.none"
REG_LOCK=$(secondmate_registry_lock_path "$DATA")
META_LOCK=$(fm_meta_lock_path "$META") || die 'invalid parent endpoint path'
fm_lock_try_acquire "$REG_LOCK" || die 'secondmate registry is in use; retry later'
META_HELD=0
cleanup() { [ "$META_HELD" = 0 ] || fm_lock_release "$META_LOCK"; fm_lock_release "$REG_LOCK"; }
trap cleanup EXIT
fm_lock_try_acquire "$META_LOCK" || die 'parent endpoint is in use; retry later'
META_HELD=1
publish() {
  local tmp
  tmp=$(mktemp "${2%/*}/.session-migration.XXXXXX") || return 1
  cp -p "$1" "$tmp" && mv -f "$tmp" "$2"
}
if [ -e "$BASE" ] || [ -L "$BASE" ]; then [ -d "$BASE" ] && [ ! -L "$BASE" ] || die 'unsafe relocation intent directory'; fi
if [ -e "$ACTIVE" ] || [ -L "$ACTIVE" ]; then
  [ -f "$ACTIVE" ] && [ ! -L "$ACTIVE" ] || die 'unsafe relocation intent pointer'
  OP=$(<"$ACTIVE")
  case "$OP" in op.*) ;; *) die 'invalid relocation operation id' ;; esac
  case "$OP" in *[!A-Za-z0-9._-]*) die 'unsafe relocation operation id' ;; esac
  INTENT="$BASE/$OP"
fi
[ ! -L "$INTENT" ] || die 'unsafe relocation intent record'
RESUMING=0
if [ -e "$INTENT" ] && [ ! -f "$INTENT/complete" ]; then
  RESUMING=1
  [ "$(<"$INTENT/reverse")" = "$REVERSE" ] || die 'another relocation is incomplete; re-run its original command'
  if [ "$REVERSE" = 0 ]; then
    [ "$(<"$INTENT/target")" = "$TARGET" ] || die 'incomplete migration has a different target; re-run its original command'
  fi
  TARGET=$(<"$INTENT/target")
fi
if [ "$RESUMING" = 0 ]; then
  secondmate_registry_line_for_id "$REG" "$ID" || die 'unregistered or duplicated route, or malformed registry entry'
  [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ] || die 'relocation requires a registered remote route'
  OLD=$SECONDMATE_REGISTRY_SESSION; OLD_ROOT=$SECONDMATE_REGISTRY_ROOT
  HOST=$SECONDMATE_REGISTRY_HOST; HOME_PATH=$SECONDMATE_REGISTRY_HOME; OLD_LINE=$SECONDMATE_REGISTRY_LINE
  secondmate_registry_parent_matches "$META" "$ID" "$HOST" "$OLD_ROOT" "$HOME_PATH" "$OLD" || die "$SECONDMATE_REGISTRY_ERROR"
  [ "$(secondmate_registry_meta_field "$META" remote_backend || printf herdr)" = herdr ] || die 'route is not a Herdr endpoint'
  REVERSE_OF=-
  if [ "$REVERSE" = 1 ]; then
    [ -f "$INTENT/complete" ] || die 'no completed relocation to reverse'
    TARGET=$(<"$INTENT/source")
    REVERSE_OF=$(<"$INTENT/op")
  fi
  if [ "$TARGET" = "$OLD" ]; then
    if [ -f "$INTENT/complete" ] && [ "$(<"$INTENT/target")" = "$TARGET" ]; then
      printf 'already relocated: %s; normal binding unchanged\n' "$ID"; exit 0
    fi
    die 'duplicate target: route already uses this session'
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || die 'malformed registry entry'
    if [ "$SECONDMATE_REGISTRY_ID" != "$ID" ] && [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ] \
      && [ "$SECONDMATE_REGISTRY_SESSION" = "$TARGET" ] && [ "$TARGET" != "$OLD" ] && [ "$REVERSE" = 0 ]; then
      die "registered-route collision: $SECONDMATE_REGISTRY_ID already uses $TARGET"
    fi
  done < "$REG"
  SOURCE_TARGET=$(secondmate_registry_meta_field "$META" remote_target) || die 'source target unavailable'
  "$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh migrate-session "$ID" "$TARGET" inspect "$SOURCE_TARGET" - "$REVERSE_OF" \
    || die 'migration preflight refused; route and endpoint unchanged'
  mkdir -p "$BASE"
  tmp=$(mktemp -d "$BASE/op.XXXXXX") || die 'cannot record relocation intent'
  OP=${tmp##*/}
  cp -p "$REG" "$tmp/registry.before"; cp -p "$META" "$tmp/parent.before"
  printf '%s\n' "$TARGET" > "$tmp/target"
  printf '%s\n' "$OLD" > "$tmp/source"
  printf '%s\n' "$REVERSE" > "$tmp/reverse"
  printf '%s\n' "$REVERSE_OF" > "$tmp/reverse-of"
  printf '%s\n' "$OP" > "$tmp/op"; printf '%s\n' "$OLD_LINE" > "$tmp/route.before"
  printf '%s\n' "$OP" > "$BASE/.active.$$"
  mv -f "$BASE/.active.$$" "$ACTIVE" || die 'cannot publish relocation intent'
  INTENT="$BASE/$OP"
fi
TARGET=$(<"$INTENT/target")
OLD=$(<"$INTENT/source"); OP=$(<"$INTENT/op"); REVERSE_OF=$(<"$INTENT/reverse-of")
SOURCE_TARGET=$(secondmate_registry_meta_field "$INTENT/parent.before" remote_target) || die 'source target unavailable'
export FM_REMOTE_MIGRATION_INTENT="$INTENT"
remote_phase() {
  "$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh migrate-session "$ID" "$TARGET" "$1" "$SOURCE_TARGET" "$OP" "$REVERSE_OF"
}
current_route_matches() {
  secondmate_registry_line_for_id "$REG" "$ID" || return 1
  [ "$SECONDMATE_REGISTRY_LINE" = "$(<"$INTENT/route.before")" ] || {
    [ -f "$INTENT/route.after" ] && [ "$SECONDMATE_REGISTRY_LINE" = "$(<"$INTENT/route.after")" ]
  }
}
if [ ! -f "$INTENT/publishing" ]; then
  if ! current_route_matches || ! cmp -s "$META" "$INTENT/parent.before"; then die 'route or parent endpoint changed since intent; preserving all records'; fi
  if prepared=$(remote_phase prepare); then
    :
  else
    # Doctor's structured diagnostics are stdout, retained even when prepare
    # fails. Do not discard the reason behind the higher-level refusal.
    [ -z "$prepared" ] || printf '%s\n' "$prepared" >&2
    die "preparation failed; route remains on session $OLD; re-run after resolving the reason"
  fi
  NEW_TARGET=$(secondmate_registry_output_field "$prepared" target)
  [ "$(secondmate_registry_output_field "$prepared" herdr_session)" = "$TARGET" ] || die 'destination session disagrees'
  case "$NEW_TARGET" in "$TARGET":?*) ;; *) die 'destination endpoint is missing or disagrees' ;; esac
  old_line=$(<"$INTENT/route.before")
  secondmate_registry_parse_line "$old_line" || die 'source route snapshot invalid'
  new_line="- $ID - $SECONDMATE_REGISTRY_SUMMARY (host: $SECONDMATE_REGISTRY_HOST; root: $SECONDMATE_REGISTRY_ROOT; home: $SECONDMATE_REGISTRY_HOME; session: $TARGET; scope: $SECONDMATE_REGISTRY_SCOPE; projects: $SECONDMATE_REGISTRY_PROJECTS; added $SECONDMATE_REGISTRY_ADDED)"
  printf '%s\n' "$new_line" > "$INTENT/route.after"
  awk -F= -v s="$TARGET" -v t="$NEW_TARGET" '
    $1=="remote_herdr_session" {print "remote_herdr_session=" s; next}
    $1=="remote_target" {print "remote_target=" t; next}
    {print}
  ' "$META" > "$INTENT/parent.after"
  printf 'publish prepared binding\n' > "$INTENT/publishing"
fi
current_route_matches || die 'route disagrees with migration snapshots'
cmp -s "$META" "$INTENT/parent.before" || cmp -s "$META" "$INTENT/parent.after" || die 'parent endpoint disagrees with migration snapshots'
# Only this route is replaced. An unrelated registry change after a failed
# attempt must neither prevent safe replay nor be overwritten by old snapshots.
current_line=$SECONDMATE_REGISTRY_LINE
new_line=$(<"$INTENT/route.after")
if [ "$REVERSE_OF" = - ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || die 'malformed registry entry during migration'
    if [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ] && [ "$SECONDMATE_REGISTRY_ID" != "$ID" ] && [ "$SECONDMATE_REGISTRY_SESSION" = "$TARGET" ]; then
      die "registered-route collision during migration: $SECONDMATE_REGISTRY_ID already uses $TARGET"
    fi
  done < "$REG"
fi
while IFS= read -r line || [ -n "$line" ]; do
  if [ "$line" = "$current_line" ]; then printf '%s\n' "$new_line"; else printf '%s\n' "$line"; fi
done < "$REG" > "$INTENT/registry.after"
# Replay both local files before transport. An interrupted pair is inaccessible
# through the ordinary route until this command finishes the logical commit.
if ! publish "$INTENT/parent.after" "$META" || ! publish "$INTENT/registry.after" "$REG"; then die 'binding publication interrupted; re-run the same relocation'; fi
remote_phase commit || die 'remote endpoint publication unconfirmed; re-run the same relocation'
remote_phase launch || die 'destination mate did not answer; binding and intent retained; re-run the same relocation'
remote_phase finish || die 'destination mate did not answer; intent retained; re-run the same relocation'
answer=$("$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh state "$ID") || die 'normal remote route did not answer; re-run the same relocation'
[ "$answer" = alive ] || die "destination mate answered $answer rather than alive; re-run the same relocation"
printf 'complete\n' > "$INTENT/complete"
printf 'migrated: %s to session %s; normal route answers; previous session left alone\n' "$ID" "$TARGET"
