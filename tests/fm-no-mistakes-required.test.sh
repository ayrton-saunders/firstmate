#!/usr/bin/env bash
# Structural baseline tests for the workflow's pinned shared native action.
# These controlled author-editable fixtures are not native execution proof.
# Focused-upstream authentication must be tested independently of this baseline.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACTION_REF=f6441c96c352a18b9cadcaef6b6c7017e9ac3970
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-required)
VERIFY="$TMP_ROOT/verify.py"
OLD_SHA=1111111111111111111111111111111111111111
NEW_SHA=2222222222222222222222222222222222222222
SIGNATURE='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
COMPLETED_STEPS='[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]'

fetch_shared_verifier() {
  command -v curl >/dev/null 2>&1 || fail "curl is required to exercise the pinned shared action"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to exercise the pinned shared action"
  curl --fail --silent --show-error --location \
    "https://raw.githubusercontent.com/kunchenguid/no-mistakes/${ACTION_REF}/.github/actions/require-no-mistakes/verify.py" \
    > "$VERIFY" || fail "could not fetch the pinned shared action verifier"
  [ -s "$VERIFY" ] || fail "the pinned shared action verifier was empty"
}

run_verifier() {
  local body=$1 head=$2
  PR_BODY="$body" PR_HEAD_SHA="$head" PR_AUTHOR=regression PR_NUMBER=3006 \
    NM_EXEMPT_AUTHORS='' NM_EXEMPT_BOT_AUTHORS=false NM_EXEMPT_HEAD_BRANCHES='' \
    GITHUB_OUTPUT='' GITHUB_EVENT_PATH='' \
    python3 "$VERIFY" 2>&1
}

test_matching_head_and_completed_steps_pass() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$NEW_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  expect_code 0 "$rc" "shared action rejected an attestation bound to the current PR head"
  assert_contains "$output" "Found structurally compliant pipeline step attestation." \
    "shared action did not report the matching attestation as compliant"
  assert_contains "$output" "PR-body attestation is author-editable" \
    "baseline acceptance did not disclose the existing forgery limitation"
  pass "known native-only limitation: hand-written matching body passes, not execution proof"
}

test_mismatched_head_fails_with_both_shas() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$OLD_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation from a different PR head"
  assert_contains "$output" "$OLD_SHA" \
    "mismatched-head failure did not name the attestation head SHA"
  assert_contains "$output" "$NEW_SHA" \
    "mismatched-head failure did not name the actual PR head SHA"
  pass "shared action rejects a mismatched head_sha and names both SHAs"
}

test_missing_head_fails() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation without head_sha"
  assert_contains "$output" "structured pipeline step attestation" \
    "missing-head failure did not explain that the attestation is invalid"
  pass "shared action rejects an attestation with no head_sha"
}

test_ordinary_personal_and_focused_bodies_fail() {
  local body output rc
  for body in 'Personal feature without pipeline evidence' \
    '<!-- firstmate-focused-upstream:v1 {"head_sha":"forged","evidence":"passed"} -->'; do
    rc=0
    output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
    [ "$rc" -ne 0 ] || fail "native baseline accepted a body without its signature"
    assert_contains "$output" "This PR was not raised through no-mistakes" \
      "unsigned-body rejection did not explain the native requirement"
  done
  pass "native baseline refuses ordinary personal and focused-only declarations"
}

test_incomplete_required_steps_fail() {
  local step status steps body output rc
  for step in review test document; do
    for status in skipped failed missing; do
      steps=$(python3 - "$step" "$status" <<'PY'
import json
import sys
step, status = sys.argv[1:]
print(json.dumps([
    {"step": name, "status": status if name == step else "completed"}
    for name in ("review", "test", "document")
    if name != step or status != "missing"
]))
PY
      )
      body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$NEW_SHA\",\"steps\":$steps} -->"
      rc=0
      output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
      [ "$rc" -ne 0 ] || fail "native baseline accepted $step=$status"
      assert_contains "$output" "$step (" "incomplete-step failure did not name $step"
    done
  done
  pass "native baseline rejects skipped, failed and missing review/test/document"
}

test_test_override_requires_recorded_opt_in() {
  local steps body output rc
  steps='[{"step":"review","status":"completed"},{"step":"test","status":"completed","override_reason":"controlled failing-command fixture"},{"step":"document","status":"completed"}]'
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$NEW_SHA\",\"steps\":$steps} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "native baseline accepted a test override without recorded opt-in"
  assert_contains "$output" "without a recorded repository opt-in" \
    "test override rejection did not explain the missing opt-in"
  pass "current pinned native verifier refuses test override without recorded opt-in"
}

fetch_shared_verifier
test_matching_head_and_completed_steps_pass
test_mismatched_head_fails_with_both_shas
test_missing_head_fails
test_ordinary_personal_and_focused_bodies_fail
test_incomplete_required_steps_fail
test_test_override_requires_recorded_opt_in
