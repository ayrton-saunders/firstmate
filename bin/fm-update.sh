#!/usr/bin/env bash
# Prepare/prove isolated upstream integration or consume origin for the fleet.
#
# Mechanical half of the /updatefirstmate skill. Consumption fast-forwards the
# firstmate repo's default branch from origin, then fast-forwards every
# registered secondmate home. Local homes are treehouse worktrees or standalone
# clones; remote routes update their configured code root on that host and then
# fast-forward the persistent home to that root. Consumption is FAST-FORWARD
# ONLY, exactly like fm-fleet-sync.sh: never force, merge or stash.
# Isolated upstream preparation may create a merge commit, as described below.
# A secondmate divergence whose complete local tree result is already present at
# the target is reconciled with reset --keep; every other unsafe target is
# skipped and reported, with divergence recorded durably by fm-ff-lib.sh.
# A tracked-files update never touches the gitignored operational
# dirs (data/, state/, config/, projects/, .no-mistakes/), so a secondmate's
# in-flight work is never disrupted. Worktrees of this repo share one object
# store, so a single fetch refreshes them all; standalone-clone homes are
# fetched on their own. Secondmate homes are leased at a detached HEAD on the
# default branch, so a fast-forward there advances HEAD only and never touches
# any other worktree's checkout or the shared `main` branch.
#
# The fast-forward mechanics live in bin/fm-ff-lib.sh (base_mode "origin" here);
# the same library drives local and remote parent-targeted secondmate sync, so
# there is one ff implementation, not several.
#
# It does NOT re-read AGENTS.md or nudge secondmates itself - those are LLM /
# tmux actions the skill performs. The script's job is the safe git mechanics
# plus a parseable summary telling the caller what to do next:
#   - one status line per target (updated/already current/skipped)
#   - reread-firstmate: yes|no    (did the running firstmate's instructions change)
#   - restart-secondmates: fm-<id>...|none (every live secondmate this pass left
#     on origin's tip - advanced OR already there - whose recorded runtime can
#     prove a restart)
#   - nudge-secondmates: fm-<id>...|none   (the residual: live secondmates on
#     that same tip whose runtime CANNOT prove a restart, so the older re-read
#     steer is all that is honest for them)
#
# The two sets are disjoint, and restart is UNCONDITIONAL on a successful update
# of that home. It is deliberately not gated on the git diff: replacing the agent
# is the only thing that re-resolves the launch-time wiring - turn-end hooks,
# harness flags, per-harness feature switches - which a running agent froze when
# it started and which no changed_instr list describes. An unchanged tracked
# surface therefore is NOT evidence that the running agent is already on the
# current behavior, so an ALREADY-CURRENT home restarts too.
#
# Only two things keep a live mate out of the restart set, and neither is papered
# over as a reload:
#   - its home was SKIPPED (dirty, uniquely diverged, offline, unsafe). It is not
#     on the new bytes, nothing here forces, stashes, or discards it, and it gets
#     no action at all. A divergence remains in the durable reconciliation record
#     that this or a later bootstrap/update pass surfaces.
#   - its runtime cannot prove the old agent stopped and a replacement came up
#     (bin/fm-secondmate-restart-lib.sh owns that test), so it falls to the
#     honest re-read steer and is reported as a nudge, never as a reload.
# A positively dead or missing endpoint has no agent to replace and is left to
# the ordinary startup recovery.
#
# A fast-forward that lands changes bytes under bin/ in place, which desyncs
# the trust binding of any locally armed fm-procevent-when watch whose action
# executable lives in the updated repo; left alone, the watch's next fire
# would be wrongly refused. After each home's own update (primary and every
# local secondmate), this script best-effort runs that home's own
# fm-procevent-when.sh rebind-all to republish those bindings against the new
# bytes; a failure there is swallowed rather than failing the update.
#
# Usage: fm-update.sh [--help | --consume-origin <full-sha>]
#        fm-update.sh --prepare-upstream <fork-url> <fork-default> <O> <canonical-url> <canonical-default> <U> <task-record-dir>
#        fm-update.sh --qualify-upstream <task-record-dir> <H> <review-head> <test-head> <base> <tested-merge> <pipeline-history> <evidence-file>
#        fm-update.sh --verify-landed <task-record-dir> <M>
# No arguments retain the origin-only, best-effort fleet update contract.
# Pinned consumption refuses before secondmates/actions on any primary skip.
# Preparation requires an already-dispatched linked worktree on a task branch,
# matching origin/canonical URLs and advertised defaults/heads, full history and
# clean state. It only fetches objects and merges in that isolated copy: no pool,
# publication, validation, active-home movement or restart actions. The caller
# supplies a new private task-record directory outside that copy; repeated calls
# reuse its exact identity and retain unknown/ever-conflicted provenance.
# Qualification is a local proof check, not a pipeline attestation: the caller
# must obtain actual Review/Test heads from supported normal pipeline evidence.
# Only exact final-tree evidence is supported here: base must be in H and the
# tested merge must have H's tree (Test may cover H or that tested merge).
# Missing repair-delta coverage/custody or empty-diff publication support stops;
# this helper never repairs a dependency, fabricates evidence or grants authority.
# Qualification checks the published task head, current fork base and canonical
# target. tested-merge must have exactly base,H parents. Landing verification
# proves actual fork M has those parents/tree and contains H/U before permitting
# pinned consumption. Neither check freezes the remote base; disagreement after
# publication is a partial outcome and never permission to rewind history.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SECONDMATES_MD="$FM_HOME/data/secondmates.md"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-secondmate-restart-lib.sh
. "$SCRIPT_DIR/fm-secondmate-restart-lib.sh"

usage() {
  printf '%s\n' \
    'usage: fm-update.sh [--consume-origin <full-sha>]' \
    '       fm-update.sh --prepare-upstream <fork-url> <fork-default> <O> <canonical-url> <canonical-default> <U> <task-record-dir>' \
    '       fm-update.sh --qualify-upstream <task-record-dir> <H> <review-head> <test-head> <base> <tested-merge> <pipeline-history> <evidence-file>' \
    '       fm-update.sh --verify-landed <task-record-dir> <M>' >&2
}

update_refuse() { printf 'update refused: %s\n' "$*" >&2; exit 1; }
update_sha() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }
update_full_history() {
  [ "$(git -C "$FM_ROOT" rev-parse --is-shallow-repository)" = false ] || update_refuse 'shallow or unknown ancestry'
}
update_no_operation() {
  local operation
  for operation in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply sequencer BISECT_LOG; do
    [ ! -e "$(git -C "$FM_ROOT" rev-parse --path-format=absolute --git-path "$operation")" ] || update_refuse 'active Git operation; preserve and inspect it'
  done
}
update_clean() {
  [ -z "$(git -C "$FM_ROOT" status --porcelain --untracked-files=all)" ] || update_refuse 'dirty working tree; preserve it'
  update_no_operation
  update_full_history
}
update_source_url() {
  # Explicit HTTPS identities only; absolute local bare repositories are useful
  # for offline operation/tests. Never accept credentials, query strings or SSH
  # configuration aliases whose actual identity cannot be compared here.
  case "$1" in
    https://github.com/*)
      [[ "$1" =~ ^https://github.com/[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+(\.git)?$ ]] || return 1 ;;
    /*) [ -d "$1" ] && [ "$(git -C "$1" rev-parse --is-bare-repository 2>/dev/null)" = true ] || return 1 ;;
    *) return 1 ;;
  esac
}
update_observed() { # <url> <default> <expected>
  local listing
  listing=$(git ls-remote --symref "$1" HEAD "refs/heads/$2" 2>/dev/null) || update_refuse 'source observation unavailable'
  printf '%s\n' "$listing" | grep -Fx "$(printf 'ref: refs/heads/%s\tHEAD' "$2")" >/dev/null || update_refuse 'unexpected advertised default branch'
  printf '%s\n' "$listing" | grep -Fx "$(printf '%s\trefs/heads/%s' "$3" "$2")" >/dev/null || update_refuse 'source moved; reclassify in a new authorized attempt'
}
update_fetch() {
  git -C "$FM_ROOT" fetch --quiet --no-tags --no-write-fetch-head "$1" "$2" 2>/dev/null || update_refuse 'cannot acquire exact source object'
}
update_field() {
  local value
  value=$(grep "^$1=" "$RECORD/identity" | cut -d= -f2-) || return 1
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}
update_record() { # <existing task record>
  RECORD=$(resolved_existing_dir "$1") || update_refuse 'missing task record'
  [ ! -L "$1" ] && [ -f "$RECORD/identity" ] && [ ! -L "$RECORD/identity" ] \
    && [ -f "$RECORD/events" ] && [ ! -L "$RECORD/events" ] || update_refuse 'unknown task provenance'
  [ "$(update_field schema)" = fm-upstream.v1 ] || update_refuse 'unknown task record schema'
  [ "$(update_field root)" = "$(resolved_existing_dir "$FM_ROOT")" ] || update_refuse 'record belongs to a different isolated copy'
  case "$RECORD/" in "$(resolved_existing_dir "$FM_ROOT")/"*) update_refuse 'task evidence must remain outside the isolated copy' ;; esac
  if ! { O=$(update_field fork_head) && U=$(update_field upstream_head) \
    && FORK_URL=$(update_field fork_url) && UPSTREAM_URL=$(update_field upstream_url) \
    && FORK_DEFAULT=$(update_field fork_default) && UPSTREAM_DEFAULT=$(update_field upstream_default) \
    && TASK_BRANCH=$(update_field branch); }; then update_refuse 'incomplete task identity'; fi
  if ! { update_sha "$O" && update_sha "$U" && update_source_url "$FORK_URL" && update_source_url "$UPSTREAM_URL"; }; then
    update_refuse 'malformed task identity'
  fi
  HISTORY=$(tail -1 "$RECORD/events")
  case "$HISTORY" in clean|unknown|conflicted) ;; *) update_refuse 'unknown conflict provenance' ;; esac
  if tail -n +2 "$RECORD/events" | grep -qx unknown; then HISTORY=unknown; fi
  if [ "$HISTORY" != unknown ] && grep -qx conflicted "$RECORD/events"; then HISTORY=conflicted; fi
}
update_candidate() {
  local h=$1
  update_sha "$h" || update_refuse 'candidate must be a full commit SHA'
  [ "$(git -C "$FM_ROOT" rev-parse HEAD)" = "$h" ] || update_refuse 'candidate is not the retained local head'
  if ! { git -C "$FM_ROOT" merge-base --is-ancestor "$O" "$h" \
    && git -C "$FM_ROOT" merge-base --is-ancestor "$U" "$h"; }; then
    update_refuse 'final candidate lost fork or canonical ancestry; supported custody/append-only recovery and normal revalidation required'
  fi
  [ "$(git -C "$FM_ROOT" symbolic-ref --short HEAD)" = "$TASK_BRANCH" ] || update_refuse 'task branch changed'
}
prepare_upstream() {
  [ "$#" -eq 7 ] || { usage; exit 2; }
  local fork_url=$1 fork_default=$2 o=$3 upstream_url=$4 upstream_default=$5 u=$6 record=$7
  local root branch common gitdir identity classification before history
  if ! { update_source_url "$fork_url" && update_source_url "$upstream_url"; }; then update_refuse 'unsupported or malformed source identity'; fi
  [ "$fork_url" != "$upstream_url" ] || update_refuse 'fork and canonical sources must be distinct'
  if ! { update_sha "$o" && update_sha "$u"; }; then update_refuse 'source heads must be full commit SHAs'; fi
  if ! { git check-ref-format "refs/heads/$fork_default" && git check-ref-format "refs/heads/$upstream_default"; }; then update_refuse 'invalid default branch'; fi
  root=$(resolved_existing_dir "$FM_ROOT") || update_refuse 'missing isolated copy'
  gitdir=$(git -C "$root" rev-parse --absolute-git-dir)
  common=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)
  [ "$gitdir" != "$common" ] || update_refuse 'preparation requires the dispatched linked isolated copy, never the primary'
  branch=$(git -C "$root" symbolic-ref --short HEAD) || update_refuse 'detached preparation branch'
  [ "$branch" != "$fork_default" ] && [ "$branch" != "$upstream_default" ] || update_refuse 'preparation requires a task branch'
  [ "$(git -C "$root" remote get-url origin)" = "$fork_url" ] \
    && [ "$(git -C "$root" remote get-url canonical)" = "$upstream_url" ] || update_refuse 'configured source identities differ from expected'
  update_clean
  update_observed "$fork_url" "$fork_default" "$o"
  update_observed "$upstream_url" "$upstream_default" "$u"
  identity=$(printf '%s\n' 'schema=fm-upstream.v1' "root=$root" "branch=$branch" \
    "fork_url=$fork_url" "fork_default=$fork_default" "fork_head=$o" \
    "upstream_url=$upstream_url" "upstream_default=$upstream_default" "upstream_head=$u")
  if [ -e "$record" ] || [ -L "$record" ]; then
    update_record "$record"
    [ "$(< "$RECORD/identity")" = "$identity" ] || update_refuse 'attempt identity changed; retain existing evidence'
    update_candidate "$(git -C "$root" rev-parse HEAD)"
    history=$HISTORY
  else
    [ "$(git -C "$root" rev-parse HEAD)" = "$o" ] || update_refuse 'new attempt must start at exact fork head'
    RECORD="$(resolved_existing_dir "$(dirname "$record")")/$(basename "$record")"
    case "$RECORD/" in "$root/"*) update_refuse 'task record must be outside the isolated copy' ;; esac
    mkdir -m 700 "$record" || update_refuse 'cannot create task record'
    RECORD=$(resolved_existing_dir "$record")
    (umask 077; printf '%s\n' "$identity" > "$RECORD/identity"; printf 'unknown\n' > "$RECORD/events")
    update_fetch "$fork_url" "$o"
    update_fetch "$upstream_url" "$u"
    git -C "$root" merge-base "$o" "$u" >/dev/null || update_refuse 'unrelated or unknown histories'
    before=$(git -C "$root" rev-parse HEAD)
    if git -C "$root" merge-base --is-ancestor "$u" "$o"; then
      classification=contained
    elif git -C "$root" merge-base --is-ancestor "$o" "$u"; then
      classification=fast-forward
      git -C "$root" merge --ff-only "$u" >/dev/null || update_refuse 'preparation failed; provenance remains unknown'
    else
      classification=divergent
      if ! git -C "$root" -c rerere.enabled=false merge --no-ff --no-edit "$u" >/dev/null 2>&1; then
        if git -C "$root" ls-files -u | grep -q .; then
          printf 'conflicted\n' >> "$RECORD/events"
          git -C "$root" diff --name-only --diff-filter=U > "$RECORD/conflicted-paths"
        fi
        update_refuse 'integration failed; preserve index, paths and task evidence for resolution/approval'
      fi
    fi
    printf 'clean\n' >> "$RECORD/events"
    history=clean
    printf 'preparation: %s %s..%s\n' "$classification" "$before" "$(git -C "$root" rev-parse HEAD)"
  fi
  printf 'fork-head: %s\nupstream-head: %s\ncandidate: %s\ntree: %s\nconflict-history: %s\n' \
    "$o" "$u" "$(git -C "$root" rev-parse HEAD)" "$(git -C "$root" rev-parse 'HEAD^{tree}')" "$history"
}

qualify_upstream() {
  [ "$#" -eq 8 ] || { usage; exit 2; }
  update_record "$1"
  local h=$2 review=$3 tested=$4 base=$5 merge=$6 pipeline_history=$7 evidence=$8 evidence_hash published
  case "$pipeline_history" in
    clean) ;;
    conflicted)
      printf 'conflicted\n' >> "$RECORD/events"
      if [ "$HISTORY" != unknown ]; then HISTORY=conflicted; fi
      ;;
    *) printf 'unknown\n' >> "$RECORD/events"; update_refuse 'pipeline conflict provenance unknown; preserve evidence and stop' ;;
  esac
  # Evidence is retained verbatim as task material by the caller, not synthesized
  # by this proof checker. It must name the actual normal Review/Test results.
  [ -f "$evidence" ] && [ -s "$evidence" ] || update_refuse 'missing actual pipeline evidence artifact'
  evidence="$(resolved_existing_dir "$(dirname "$evidence")")/$(basename "$evidence")"
  evidence_hash=$(git -C "$FM_ROOT" hash-object "$evidence") || update_refuse 'cannot fingerprint actual evidence'
  update_clean
  update_candidate "$h"
  [ "$HISTORY" != unknown ] || update_refuse 'unknown conflict history is ineligible for automatic landing'
  if ! { update_sha "$review" && update_sha "$tested" && update_sha "$base" && update_sha "$merge"; }; then update_refuse 'qualification requires full evidence SHAs'; fi
  if ! { [ "$review" = "$h" ] && { [ "$tested" = "$h" ] || [ "$tested" = "$merge" ]; }; }; then
    update_refuse 'final-head Review/Test coverage unavailable; use supported narrow normal revalidation or stop'
  fi
  update_observed "$FORK_URL" "$FORK_DEFAULT" "$base"
  update_observed "$UPSTREAM_URL" "$UPSTREAM_DEFAULT" "$U"
  published=$(git ls-remote "$FORK_URL" "refs/heads/$TASK_BRANCH" 2>/dev/null) || update_refuse 'published head unavailable'
  [ "$published" = "$(printf '%s\trefs/heads/%s' "$h" "$TASK_BRANCH")" ] || update_refuse 'published head moved or no genuine PR branch was published'
  update_fetch "$FORK_URL" "$base"
  [ "$(git -C "$FM_ROOT" show -s --format=%P "$merge")" = "$base $h" ] || update_refuse 'tested merge provenance must have exact base,H parents'
  if ! { git -C "$FM_ROOT" merge-base --is-ancestor "$O" "$base" \
    && git -C "$FM_ROOT" merge-base --is-ancestor "$base" "$h" \
    && [ "$(git -C "$FM_ROOT" rev-parse "$merge^{tree}")" = "$(git -C "$FM_ROOT" rev-parse "$h^{tree}")" ]; }; then
    update_refuse 'base or tested tree differs from final reviewed tree; supported normal revalidation required'
  fi
  if git -C "$FM_ROOT" diff --quiet "$base" "$h" --; then
    update_refuse 'ancestry-only candidate: supported checked publication evidence unavailable; no fake edit or skipped-phase attestation'
  fi
  [ ! -L "$RECORD/qualifications" ] && [ ! -L "$RECORD/evidence" ] || update_refuse 'unsafe qualification path'
  printf '%s %s %s\n' "$h" "$evidence_hash" "$evidence" >> "$RECORD/evidence"
  # Append snapshots; movement invalidates earlier qualification without deleting it.
  printf '%s %s %s %s %s %s\n' "$h" "$review" "$tested" "$base" "$merge" "$(git -C "$FM_ROOT" rev-parse "$merge^{tree}")" >> "$RECORD/qualifications"
  printf 'qualified-head: %s\nconflict-history: %s\n' "$h" "$HISTORY"
  [ "$HISTORY" != conflicted ] || printf 'approval-required: conflict resolution bound to %s\n' "$h"
}
verify_landed() {
  [ "$#" -eq 2 ] || { usage; exit 2; }
  update_record "$1"
  local m=$2 h review tested base merge tree
  update_sha "$m" || update_refuse 'landed commit must be a full SHA'
  [ -f "$RECORD/qualifications" ] && [ ! -L "$RECORD/qualifications" ] || update_refuse 'no final-head qualification'
  read -r h review tested base merge tree < <(tail -1 "$RECORD/qualifications")
  if ! { update_sha "$h" && update_sha "$base" && update_sha "$tree"; }; then update_refuse 'invalid qualification'; fi
  [ "$HISTORY" != unknown ] || update_refuse 'unknown conflict provenance; stop consumption'
  update_observed "$FORK_URL" "$FORK_DEFAULT" "$m"
  update_fetch "$FORK_URL" "$m"
  if ! { [ "$(git -C "$FM_ROOT" show -s --format=%P "$m")" = "$base $h" ] \
    && [ "$(git -C "$FM_ROOT" rev-parse "$m^{tree}")" = "$tree" ] \
    && git -C "$FM_ROOT" merge-base --is-ancestor "$h" "$m" \
    && git -C "$FM_ROOT" merge-base --is-ancestor "$U" "$m"; }; then
    update_refuse 'published result differs from qualified base/head/tree/ancestry; stop consumption, preserve published history'
  fi
  [ ! -L "$RECORD/landings" ] || update_refuse 'unsafe landing record path'
  printf '%s\n' "$m" >> "$RECORD/landings"
  printf 'verified-origin: %s\nprimary-activation: pending human-owned fresh-process handover\n' "$m"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
expected_origin=
case "${1:-}" in
  --prepare-upstream) shift; prepare_upstream "$@"; exit ;;
  --qualify-upstream) shift; qualify_upstream "$@"; exit ;;
  --verify-landed) shift; verify_landed "$@"; exit ;;
  --consume-origin)
    if [ "$#" -ne 2 ] || ! update_sha "$2"; then usage; exit 2; fi
    expected_origin=$2 ;;
  '') [ "$#" -eq 0 ] || { usage; exit 2; } ;;
  *) usage; exit 2 ;;
esac

"$SCRIPT_DIR/fm-guard.sh" || true

# --- main firstmate repo ---------------------------------------------------

reread_firstmate="no"
ff_target "$FM_ROOT" "firstmate" origin no no '' '' "$expected_origin"
if [ -n "$expected_origin" ] && [ "$FF_STATUS" = skipped ]; then
  echo 'reread-firstmate: no'
  echo 'restart-secondmates: none'
  echo 'nudge-secondmates: none'
  exit 1
fi
if [ "$FF_STATUS" = "updated" ]; then
  if [ -n "$FF_INSTR" ]; then
    reread_firstmate="yes"
  fi
  # A fast-forward changes bin/'s bytes out from under any locally armed
  # fm-procevent-when watch's trust binding, with no tampering involved; left
  # alone, the very next fire is refused and the watch dies silently. Refresh
  # every such watch now, right after the update that broke it. FM_ROOT_OVERRIDE
  # is passed explicitly rather than relying on the script's own location: this
  # process's own FM_ROOT is the repo that was just updated, which is not
  # always where this very script file happens to live (FM_ROOT_OVERRIDE, as
  # this test suite uses to point fm-update.sh at a fixture checkout).
  FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" "$SCRIPT_DIR/fm-procevent-when.sh" rebind-all || true
fi

# --- secondmates -----------------------------------------------------------
# Every live secondmate this pass leaves on origin's tip is restarted, whether it
# advanced or was already there. The header above owns why the git diff does not
# gate that, and which two conditions - a skipped home, an unprovable runtime -
# are the only ways a live mate stays out of the restart set.

# FF_NUDGE_WINDOWS and FF_SEEN_HOMES are the sweep's own accumulators and are
# reset here per its contract; the instruction-gated nudge set is the session-start
# sweep's threshold, not this command's, so only the two sets below are read.
FF_NUDGE_WINDOWS=""
FF_SEEN_HOMES=""
FF_RESTART_WINDOWS=""
FF_STEER_WINDOWS=""

secondmate_agent_may_be_alive() {  # <id>
  local id=$1 meta="$STATE/$1.meta" remote_host state=unreadable
  remote_host=$(fm_meta_get "$meta" remote_host)
  if [ -n "$remote_host" ]; then
    state=$("$SCRIPT_DIR/fm-on.sh" "$id" \
      fm-remote-secondmate-control.sh state "$id" < /dev/null 2>/dev/null) || state=unreadable
  elif fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1; then
    state=$(fm_backend_agent_state "$FM_BACKEND_VALIDATED_BACKEND" \
      "$FM_BACKEND_VALIDATED_TARGET" 2>/dev/null) || state=unreadable
  fi
  case "$state" in
    dead|missing) return 1 ;;
    *) return 0 ;;
  esac
}

selector_claimed() {  # <selector>
  case " $FF_RESTART_WINDOWS $FF_STEER_WINDOWS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# Route one secondmate whose home this pass left on the target commit. Restart is
# the outcome unless its runtime cannot prove one, in which case it keeps the
# re-read steer and is reported as a nudge rather than as a reload. A stopped
# endpoint has no agent to replace and is left to startup recovery.
claim_settled_secondmate() {  # <id>
  local id=$1
  selector_claimed "fm-$id" && return 0
  secondmate_agent_may_be_alive "$id" || return 0
  if fm_secondmate_restart_capable "$STATE/$id.meta"; then
    FF_RESTART_WINDOWS="$FF_RESTART_WINDOWS fm-$id"
  else
    FF_STEER_WINDOWS="$FF_STEER_WINDOWS fm-$id"
  fi
}

# bin/fm-ff-lib.sh calls this for each local home it left AT the base with a live
# endpoint - status "updated" or "current" alike. A skipped home never gets here.
fm_ff_after_secondmate_settled() {  # <id> <home> <window> <status> <instr>
  # Same bin/-changed-out-from-under-a-watch problem as the primary home
  # above, for a local secondmate's own worktree; "current" means bin/ did
  # not move there this pass, so there is nothing to rebind. Run the
  # secondmate's OWN copy of the script, explicitly overriding FM_ROOT to its
  # own worktree rather than letting an outer FM_ROOT_OVERRIDE (this process's
  # own, if the caller set one) leak into the child and misscope it.
  if [ "${4:-}" = "updated" ] && [ -x "$2/bin/fm-procevent-when.sh" ]; then
    FM_HOME="$2" FM_ROOT_OVERRIDE="$2" "$2/bin/fm-procevent-when.sh" rebind-all || true
  fi
  claim_settled_secondmate "$1"
}

# Live direct reports first: state/<id>.meta with kind=secondmate carries the
# authoritative home= path.
sweep_live_secondmate_metas "$STATE" origin yes

# Registry backstop: a secondmate registered in data/secondmates.md but without
# a live meta (e.g. between restarts) is still its persistent on-disk home.
if [ -f "$SECONDMATES_MD" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- "*) ;;
      *) continue ;;
    esac
    if ! secondmate_registry_parse_line "$line"; then
      echo "secondmate registry: skipped malformed entry: $line" >&2
      continue
    fi
    id=$SECONDMATE_REGISTRY_ID
    home=$SECONDMATE_REGISTRY_HOME
    if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
      if remote_out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh update "$id" < /dev/null 2>&1); then
        remote_result=$(printf '%s\n' "$remote_out" | tail -1)
        case "$remote_result" in
          synced:*)
            remote_detail=${remote_result#synced: }
            # The host reports its advance as "<commit> instr=<paths>"; a host
            # whose Firstmate copy predates that suffix reports the commit alone.
            # The suffix is now reporting detail only: the routing below no longer
            # reads it, so an older host's silence can no longer downgrade a
            # restartable mate to a steer.
            case "$remote_detail" in
              *' instr='*)
                remote_instr=${remote_detail##* instr=}
                remote_commit=${remote_detail%% instr=*}
                ;;
              *) remote_instr=""; remote_commit=$remote_detail ;;
            esac
            if [ -n "$remote_instr" ]; then
              echo "remote secondmate $id: updated on $SECONDMATE_REGISTRY_HOST ($remote_commit, instructions changed: $remote_instr)"
            else
              echo "remote secondmate $id: updated on $SECONDMATE_REGISTRY_HOST ($remote_commit)"
            fi
            if [ -f "$STATE/$id.meta" ] && grep -qx 'kind=secondmate' "$STATE/$id.meta"; then
              claim_settled_secondmate "$id"
            fi
            ;;
          current:*)
            echo "remote secondmate $id: already current on $SECONDMATE_REGISTRY_HOST (${remote_result#current: })"
            # Already on the target commit is a SUCCESSFUL update of that home,
            # so it earns the same restart as one that had to advance.
            if [ -f "$STATE/$id.meta" ] && grep -qx 'kind=secondmate' "$STATE/$id.meta"; then
              claim_settled_secondmate "$id"
            fi
            ;;
          *) echo "remote secondmate $id: skipped on $SECONDMATE_REGISTRY_HOST: malformed update result" >&2 ;;
        esac
      else
        echo "remote secondmate $id: skipped on $SECONDMATE_REGISTRY_HOST: ${remote_out%%$'\n'*}" >&2
      fi
    else
      process_secondmate "$id" "$home" "" origin yes
    fi
  done < "$SECONDMATES_MD"
fi

# --- caller action summary -------------------------------------------------

# claim_settled_secondmate puts each live settled mate in exactly one set, so the
# two lines below are disjoint by construction: no mate is ever restarted and
# then also steered about the instructions it just relaunched on.

echo "reread-firstmate: $reread_firstmate"
echo "restart-secondmates:${FF_RESTART_WINDOWS:- none}"
echo "nudge-secondmates:${FF_STEER_WINDOWS:- none}"
