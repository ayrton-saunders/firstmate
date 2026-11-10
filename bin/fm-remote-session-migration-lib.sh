#!/usr/bin/env bash
# Remote half of fm-remote-session-migrate.sh, sourced by remote control.
# migrate-session ID SESSION PHASE SOURCE-TARGET OP REVERSE-OF
# Only explicit relocation calls reach here. Per-operation immutable intent
# snapshots are not control-relaunch journals. Previous sessions survive.

cmd_migrate_session() (
  local id=$1 target=$2 phase=$3 source_target=$4 op=$5 reverse_of=$6
  local base="$CONTROL_STATE/.session-migration-$1" dir meta lock source_session current old_target meta_lock=
  local ws task_ids tab pane tmp harness model effort traceparent out endpoint_lock
  local -a launch_env args
  fm_remote_herdr_session_validate "$target" || die "invalid Herdr session: 1-64 ASCII bytes, alphanumeric first, then letters/digits/./_/-; not default"
  case "$op:$reverse_of" in *[!A-Za-z0-9._:-]*) die "unsafe relocation operation id" ;; esac
  meta=$(meta_path "$id"); dir="$base/$op"
  [ ! -L "$base" ] && [ ! -L "$dir" ] || die "unsafe migration intent directory"
  lock="$CONTROL_STATE/.session-migration-$id.lock"
  fm_lock_try_acquire "$lock" || die "another relocation is running"
  trap '[ -z "$meta_lock" ] || fm_lock_release "$meta_lock"; fm_lock_release "$lock"' EXIT
  check_source_idle() {
    current=$(remote_agent_state herdr "$source_target" "$meta")
    case "$current" in
      alive)
        # shellcheck source=bin/fm-busy-lib.sh
        . "$SCRIPT_DIR/fm-busy-lib.sh"
        case "$(fm_busy_classify_meta "$meta" "$id" "$CONTROL_STATE")" in
          idle\ *) ;;
          *) die "source mate is busy or its idle state cannot be confirmed; quiesce it and re-run" ;;
        esac ;;
      dead) ;;
      *) die "source mate is $current; quiesce it and re-run" ;;
    esac
  }
  reverse_proven() {
    [ "$reverse_of" != - ] && [ -f "$base/$reverse_of/complete" ] \
      && [ "$(<"$base/$reverse_of/source")" = "$target" ]
  }
  if [ "$phase" = inspect ]; then
    remote_endpoint_require "$id"
    if [ "$REMOTE_ENDPOINT_BACKEND" != herdr ] || [ "$REMOTE_ENDPOINT_TARGET" != "$source_target" ]; then die "source endpoint disagrees with parent record"; fi
    fm_backend_source herdr || die "Herdr adapter unavailable"
    if [ "$target" != "$REMOTE_HERDR_SESSION" ] && ! reverse_proven; then
      out=$(fm_backend_herdr_cli "$REMOTE_HERDR_SESSION" session list --json) || die "cannot inventory target names"
      printf '%s' "$out" | jq -e --arg name "$target" '.sessions | type == "array" and all(.[]; .name != $name)' >/dev/null \
        || die "name already used: duplicate target session $target"
    fi
    check_source_idle
    return 0
  fi
  case "$op" in op.?*) ;; *) die "relocation operation id unavailable" ;; esac
  if [ ! -e "$dir" ]; then
    [ "$phase" = prepare ] || die "no relocation intent; prepare first"
    remote_endpoint_require "$id"
    if [ "$REMOTE_ENDPOINT_BACKEND" != herdr ] || [ "$REMOTE_ENDPOINT_TARGET" != "$source_target" ]; then die "source endpoint disagrees with parent record"; fi
    check_source_idle
    mkdir -p "$base"
    tmp=$(mktemp -d "$base/.intent.XXXXXX") || die "cannot record relocation intent"
    cp -p "$meta" "$tmp/before"
    printf '%s\n' "$target" > "$tmp/target"
    printf '%s\n' "$REMOTE_HERDR_SESSION" > "$tmp/source"
    if reverse_proven; then printf 'reversal\n' > "$tmp/reuse-session"; fi
    mv "$tmp" "$dir" || die "cannot publish relocation intent"
    printf '%s\n' "$op" > "$base/.active.$$"; mv -f "$base/.active.$$" "$base/active"
  fi
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ "$(<"$dir/target")" = "$target" ] || die "migration intent disagrees"
  source_session=$(<"$dir/source"); old_target=$(fm_meta_get "$dir/before" window)
  [ "$old_target" = "$source_target" ] || die "source endpoint disagrees with relocation intent"
  case "$REMOTE_HERDR_SESSION" in "$source_session"|"$target") ;; *) die "route session disagrees with relocation intent" ;; esac
  case "$phase" in
    prepare)
      if [ ! -f "$dir/after" ]; then
        cmp -s <(grep -v '^busy_gen=' "$meta") <(grep -v '^busy_gen=' "$dir/before") || die "source endpoint changed; refusing relocation"
        remote_endpoint_require "$id"
        check_source_idle
        if [ "$target" != "$source_session" ] && [ ! -f "$dir/reuse-session" ]; then
          "$SCRIPT_DIR/fm-remote-doctor.sh" --herdr-session "$source_session" --birth-for-migration "$target" "$op" \
            || die "target session could not be created and verified; route remains on $source_session"
        else
          fm_backend_source herdr || die "Herdr adapter unavailable"
          out=$(fm_backend_herdr_cli "$target" status --json) || die "retained target session is unavailable"
          printf '%s' "$out" | jq -e '.server.running == true' >/dev/null || die "retained target session is not running"
        fi
        if [ "$current" = alive ]; then
          env FM_HOME="$FM_ROOT" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$CONTROL_STATE" \
            FM_DATA_OVERRIDE="$CONTROL_DATA" FM_CONFIG_OVERRIDE="$TARGET_HOME/config" \
            "$SCRIPT_DIR/fm-control.sh" "$id" exit --idle-only || die "source mate did not exit gracefully; quiesce it and re-run; route remains on $source_session"
        fi
        remote_endpoint_require "$id"
        [ "$REMOTE_ENDPOINT_TARGET" = "$old_target" ] || die "source endpoint changed during exit"
        cp -p "$meta" "$dir/before"
        [ "$(remote_agent_state herdr "$old_target" "$meta")" = dead ] || die "source mate absence cannot be verified; route remains on $source_session"
        if [ -f "$dir/reuse-session" ]; then
          # Reversal reuses the retained original terminal, never closes a
          # husk tab or adopts an unrelated endpoint in the previous session.
          tmp="$base/$reverse_of/before"
          [ "$(remote_agent_state herdr "$(fm_meta_get "$tmp" window)" "$tmp")" = dead ] || die "retained reversal endpoint is not proven agent-free"
          ws=$(fm_meta_get "$tmp" herdr_workspace_id)
          tab=$(fm_meta_get "$tmp" herdr_tab_id)
          pane=$(fm_meta_get "$tmp" herdr_pane_id)
        else
          fm_backend_source herdr || die "Herdr adapter unavailable"
          FM_HOME="$TARGET_HOME" fm_backend_herdr_workspace_ensure "$target" "$TARGET_HOME" other-home > "$dir/workspace" || die "cannot prepare destination workspace"
          ws=$(<"$dir/workspace")
          task_ids=$(fm_backend_herdr_create_task "$target:$ws" "fm-$id" "$TARGET_HOME" "$FM_BACKEND_HERDR_WS_SEEDED_TAB_ID") || die "cannot prepare destination terminal"
          read -r tab pane <<< "$task_ids"
          [ -n "$tab" ] && [ -n "$pane" ] || die "destination identity unavailable"
        fi
        tmp=$(mktemp "$dir/.after.XXXXXX") || die "cannot stage endpoint"
        awk -F= -v s="$target" -v w="$ws" -v t="$tab" -v p="$pane" '
          $1=="window" {print "window=" s ":" p; next}
          $1=="herdr_session" {print "herdr_session=" s; next}
          $1=="herdr_workspace_id" {print "herdr_workspace_id=" w; next}
          $1=="herdr_tab_id" {print "herdr_tab_id=" t; next}
          $1=="herdr_pane_id" {print "herdr_pane_id=" p; next}
          {print}
        ' "$meta" > "$tmp" || die "cannot write destination endpoint; re-run relocation"
        mv "$tmp" "$dir/after" || die "cannot publish destination preparation; re-run relocation"
      fi
      printf 'herdr_session=%s\ntarget=%s\n' "$target" "$(fm_meta_get "$dir/after" window)" ;;
    commit)
      endpoint_lock=$(fm_meta_lock_path "$meta") || die "invalid endpoint publication lock"
      fm_lock_try_acquire "$endpoint_lock" || die "endpoint record is in use; re-run migration"
      meta_lock=$endpoint_lock
      if [ -f "$dir/committed" ]; then
        remote_endpoint_require "$id"
        [ "$REMOTE_ENDPOINT_TARGET" = "$(fm_meta_get "$dir/after" window)" ] || die "committed endpoint disagrees"
        return 0
      fi
      [ -f "$dir/after" ] || die "destination not prepared"
      if ! cmp -s "$meta" "$dir/after"; then
        cmp -s "$meta" "$dir/before" || die "endpoint disagrees with relocation snapshots"
        [ "$(remote_agent_state herdr "$old_target" "$meta")" = dead ] || die "source mate is no longer absent"
        tmp=$(mktemp "$CONTROL_STATE/.migration-meta.XXXXXX") || die "cannot stage endpoint publication"
        if ! cp -p "$dir/after" "$tmp" || ! mv "$tmp" "$meta"; then die "endpoint publication failed; re-run relocation"; fi
      fi
      printf 'committed\n' > "$dir/committed" ;;
    launch)
      [ "$REMOTE_HERDR_SESSION" = "$target" ] || die "route has not committed destination session"
      remote_endpoint_require "$id"
      [ "$REMOTE_ENDPOINT_TARGET" = "$(fm_meta_get "$dir/after" window)" ] || die "destination endpoint disagrees"
      current=$(remote_agent_state herdr "$REMOTE_ENDPOINT_TARGET" "$meta")
      case "$current" in alive) print_route "$id"; return 0 ;; dead) ;; *) die "destination mate is $current; refusing duplicate launch" ;; esac
      harness=$(fm_meta_get "$dir/before" harness); model=$(fm_meta_get "$dir/before" model); effort=$(fm_meta_get "$dir/before" effort)
      args=("$id" --relaunch --harness "$harness")
      case "$model" in ''|-|default) ;; *) args+=(--model "$model") ;; esac
      case "$effort" in ''|-|default) ;; *) args+=(--effort "$effort") ;; esac
      traceparent=$(fm_meta_get "$dir/after" traceparent)
      [ -z "$traceparent" ] || args+=(--traceparent "$traceparent")
      launch_env=(HERDR_SESSION="$target" FM_HOME="$FM_ROOT" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$CONTROL_STATE"
        FM_DATA_OVERRIDE="$CONTROL_DATA" FM_CONFIG_OVERRIDE="$TARGET_HOME/config" FM_SKIP_SECONDMATE_INHERIT=1 FM_SKIP_SECONDMATE_SYNC=1)
      if ! out=$(env "${launch_env[@]}" "$SCRIPT_DIR/fm-spawn.sh" "${args[@]}" 2>&1); then printf '%s\n' "$out" >&2; die "destination mate did not start; re-run relocation"; fi
      print_route "$id" ;;
    finish)
      remote_endpoint_require "$id"
      [ "$REMOTE_HERDR_SESSION" = "$target" ] && [ "$(remote_agent_state herdr "$REMOTE_ENDPOINT_TARGET" "$meta")" = alive ] || die "destination mate does not answer; re-run relocation"
      printf 'complete\n' > "$dir/complete" ;;
    *) die "unknown relocation phase: $phase" ;;
  esac
)
