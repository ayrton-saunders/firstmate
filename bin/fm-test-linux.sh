#!/usr/bin/env bash
# fm-test-linux.sh - opt-in: run the shell tests changed on this branch inside a
# Linux container with GNU userland.
#
# macOS ships BSD stat, date, sed and friends, so a fixture that passes locally
# can fail on Linux CI (for example `stat -f ... || stat -c ...`, where GNU
# `stat -f` prints filesystem output before failing). Run this before
# publishing a branch whose tests touch stat, date, or process behavior.
#
# Usage:
#   fm-test-linux.sh [--base <git-ref>] [--list] [tests/<name>.test.sh ...]
#   fm-test-linux.sh -h|--help
#
# With no test paths, the tests are the tests/*.test.sh files that differ from
# the merge base with --base (default: origin/main, else main), including
# uncommitted and untracked ones. A local clone of the repo, overlaid with the
# working tree files, is mounted read-write from a scratch directory, so tests
# see git history and the checkout is never modified. Tests run as the host
# user, not root, to match CI file-mode behavior.
# --list prints the selected tests and exits without a container runtime.
#
# Runtime: FM_CONTAINER_RUNTIME, else docker, else podman. With none installed
# the script stops with exit 2. The image is built from tests/linux/Dockerfile
# (Debian bookworm, GNU coreutils) and tagged fm-test-linux:bookworm.
#
# Exit status: 0 all selected tests passed (or none changed), 1 a test failed,
# 2 usage error or no container runtime.
set -eu
set -o pipefail

usage() {
  sed -n '2,/^set -eu/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

die() {
  printf 'fm-test-linux: %s\n' "$1" >&2
  exit 2
}

base=""
list_only=0
tests=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --base) [ $# -ge 2 ] || die "--base needs a ref"; base=$2; shift 2 ;;
    --list) list_only=1; shift ;;
    -*) die "unknown option: $1" ;;
    *) tests+=("$1"); shift ;;
  esac
done

root=$(git rev-parse --show-toplevel 2>/dev/null) || die "run inside a git checkout"
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
dockerfile_dir="$script_dir/../tests/linux"

if [ ${#tests[@]} -eq 0 ]; then
  if [ -z "$base" ]; then
    for ref in origin/main main; do
      if git -C "$root" rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then base=$ref; break; fi
    done
  fi
  [ -n "$base" ] || die "no origin/main or main to compare against; pass --base <git-ref>"
  merge_base=$(git -C "$root" merge-base HEAD "$base") || die "no merge base with $base"
  changed=$(git -C "$root" diff --name-only --diff-filter=ACMR "$merge_base" --) || die 'could not list changed paths'
  untracked=$(git -C "$root" ls-files --others --exclude-standard) || die 'could not list untracked paths'
  selected=$(printf '%s\n' "$changed" "$untracked" | sort -u) || die 'could not sort changed paths'
  while IFS= read -r path; do
    if [[ "$path" =~ ^tests/[^/]+\.test\.sh$ ]] && [ -f "$root/$path" ]; then tests+=("$path"); fi
  done <<<"$selected"
fi

if [ ${#tests[@]} -eq 0 ]; then
  echo "fm-test-linux: no changed shell tests"
  exit 0
fi

if [ "$list_only" = 1 ]; then
  printf '%s\n' "${tests[@]}"
  exit 0
fi

. "$script_dir/fm-test-scratch-lib.sh"
scratch_base=$(fm_test_validate_scratch_base "$root" "${TMPDIR:-/tmp}") || exit "$?"

runtime=${FM_CONTAINER_RUNTIME:-}
if [ -z "$runtime" ]; then
  for candidate in docker podman; do
    if command -v "$candidate" >/dev/null 2>&1; then runtime=$candidate; break; fi
  done
fi
{ [ -n "$runtime" ] && command -v "$runtime" >/dev/null 2>&1; } ||
  die "no container runtime found; install docker or podman, or set FM_CONTAINER_RUNTIME"

image=fm-test-linux:bookworm
"$runtime" build -q -t "$image" "$dockerfile_dir" >/dev/null ||
  die "$runtime could not build $image; is the container engine running?"

fm_test_allocate_scratch "${scratch_base%/}/fm-test-linux.XXXXXX" || exit "$?"
scratch=$FM_TEST_SCRATCH
ROOT=$(cd "$script_dir/.." && pwd -P)
. "$ROOT/bin/fm-timeout-lib.sh"
probe_owner=
container=

stop_linux_container() {
  local running filter
  [ -n "$container" ] || return 0
  filter="name=^/?${container//./[.]}\$"
  running=$(fm_run_timed 5 "$runtime" ps -q --filter "$filter") || return 1
  if [ -n "$running" ]; then
    fm_run_timed 5 "$runtime" stop --time 2 "$running" >/dev/null || return 1
    running=$(fm_run_timed 5 "$runtime" ps -q --filter "$filter") || return 1
    [ -z "$running" ] || return 1
  fi
  container=
}

finish_linux() {
  local status=$1 teardown=$2
  trap '' HUP INT QUIT TERM
  trap - EXIT
  if [ "$teardown" -ne 0 ]; then
    if [ -n "${FM_TEST_RETAIN_MARKER:-}" ]; then
      : > "$FM_TEST_RETAIN_MARKER.$$.linux" || printf 'could not publish Linux retention marker\n' >&2
    fi
    printf 'could not verify Linux probe teardown; retaining scratch: %s\n' "$scratch" >&2
    [ "$status" -ne 0 ] || status=1
  elif ! fm_test_cleanup_scratch "$scratch"; then
    [ "$status" -ne 0 ] || status=1
  fi
  exit "$status"
}
cleanup_linux() {
  local status=$? teardown=0
  trap '' HUP INT QUIT TERM
  fm_test_probe_drain || teardown=1
  stop_linux_container || teardown=1
  finish_linux "$status" "$teardown"
}
trap cleanup_linux EXIT

git clone -q --no-checkout --local --no-hardlinks "$root" "$scratch" || die "could not clone $root into the scratch directory"
if git -C "$scratch" rev-parse --verify --quiet HEAD >/dev/null; then
  git -C "$scratch" read-tree HEAD
fi
inventory="$scratch/.git/fm-test-overlay"
git -C "$root" ls-files -z --cached --others --exclude-standard -- "$fm_test_scratch_exclusion" >"$inventory" || die 'could not enumerate overlay paths'
files=()
while IFS= read -r -d '' path; do
  parent=$path
  while [[ "$parent" == */* ]]; do
    parent=${parent%/*}
    [ ! -L "$root/$parent" ] || continue 2
  done
  [ -e "$root/$path" ] || [ -L "$root/$path" ] && files+=("$path")
done <"$inventory"
rm -f -- "$inventory"
if [ "${#files[@]}" -gt 0 ]; then
  (cd "$root" && printf '%s\0' "${files[@]}" | tar --no-recursion --null -T - -cf -) | tar -C "$scratch" -xf - || die 'could not copy complete overlay'
fi

printf 'fm-test-linux: %s on %s\n' "${#tests[@]}" "$("$runtime" run --rm "$image" sh -c 'uname -sr')"
case "$(basename "$runtime")" in
  podman*) identity=(--userns=keep-id) ;;
  *) identity=(--user "$(id -u):$(id -g)") ;;
esac
failed=()
for t in "${tests[@]}"; do
  container="${scratch##*/}"
  rc=0
  fm_test_probe_run "$runtime" run --rm --name "$container" "${identity[@]}" -v "$scratch:/work" -w /work -e HOME=/tmp -e TMPDIR=/tmp "$image" bash "$t" || rc=$?
  [ -z "$probe_owner" ] || exit 1
  stop_linux_container || finish_linux 1 1
  if [ "$rc" -eq 0 ]; then
    printf 'PASS %s\n' "$t"
  else
    printf 'FAIL %s\n' "$t"
    failed+=("$t")
  fi
done
[ ${#failed[@]} -eq 0 ] || { printf 'fm-test-linux: %s failed\n' "${#failed[@]}" >&2; exit 1; }
