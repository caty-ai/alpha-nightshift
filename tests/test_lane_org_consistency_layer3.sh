#!/bin/bash
# shellcheck disable=SC1091
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
. "$TEST_DIR/helpers.sh"
. "$TEST_DIR/fixtures/org-consistency/lib.sh"

FAKE_SEAT="$TEST_DIR/fixtures/org-consistency/fake-seat.sh"
seat_cmd="/bin/bash '$FAKE_SEAT'"
case_roots=()
cleanup() {
  rm -rf "${case_roots[@]}"
}
trap cleanup EXIT

setup_ij_case() {
  case_name=$1
  first_id=$2
  repo_count=${3:-1}
  oc_case_init "$case_name"
  case_roots+=("$OC_CASE_ROOT")

  api_items='[]'
  repo_index=1
  while [ "$repo_index" -le "$repo_count" ]; do
    repo_name="demo-$repo_index"
    repo_id=$((first_id + repo_index - 1))
    oc_make_remote "$repo_name" main none
    api_items=$(printf '%s\n' "$api_items" | jq \
      --argjson id "$repo_id" \
      --arg name "$repo_name" \
      '. + [{id:$id,name:$name,full_name:("caty-ai/"+$name),description:("Description for "+$name),default_branch:"main",clone_url:("https://github.com/caty-ai/"+$name+".git"),archived:false,private:false}]')
    repo_index=$((repo_index + 1))
  done
  printf '%s\n' "$api_items" > "$OC_API"
}

run_ij() {
  night=$1
  mode=$2
  shift 2
  oc_run "$night" \
    OC_TEST_DISABLE_L3=0 \
    OC_SEAT_CMD="$seat_cmd" \
    OC_FAKE_SEAT_MODE="$mode" \
    OC_L3_MAX_REPOS=1 \
    OC_L3_WEEKDAY=7 \
    OC_ZERO_STREAK_NIGHTS=99 \
    "$@"
}

# NIGHT_ID, rather than wall-clock time, determines the ISO weekday. Saturday
# is silent; the immediately following Sunday plans and runs both qualitative
# checks with the documented default settings and prompt shape.
setup_ij_case l3-weekday 3101
run_ij 2026-08-01 ij-assert-input
jq -e '
  .effective_settings.OC_L3_WEEKDAY == 7 and
  .effective_settings.OC_L3_MAX_REPOS == 1 and
  .effective_settings.OC_PROMPT_MAX_BYTES == 262144 and
  ([.cells[] | select(.layer == 3)] | length) == 0
' "$OC_STATE/report/2026-08-01.json" >/dev/null || fail 'non-matching NIGHT_ID planned layer 3 or failed to echo defaults'
run_ij 2026-08-02 ij-assert-input
jq -e '
  ([.cells[] | select(.repo_id == 3101 and .check_id == "OC-I" and .layer == 3 and .status == "RUN")] | length) == 1 and
  ([.cells[] | select(.repo_id == 3101 and .check_id == "OC-J" and .layer == 3 and .status == "RUN")] | length) == 1 and
  ([.events[] | select(.type == "SEAT-INVOKED" and .repo_id == 3101)] | length) == 1
' "$OC_STATE/report/2026-08-02.json" >/dev/null || fail 'matching Sunday did not run one bundled OC-I/J seat'

# OC-J score 3 is an accepted result but not a finding.
setup_ij_case l3-score-three 3201
run_ij 2026-08-01 ij-score-3
run_ij 2026-08-02 ij-score-3
jq -e '
  ([.cells[] | select(.repo_id == 3201 and .check_id == "OC-J" and .status == "RUN" and .fresh == true)] | length) == 1 and
  ([.findings.new[] | select(.repo_id == 3201 and .check_id == "OC-J")] | length) == 0
' "$OC_STATE/report/2026-08-02.json" >/dev/null || fail 'OC-J score 3 was rejected or emitted as a finding'
jq -e '[.findings[] | select(.repo_id == 3201 and .check_id == "OC-J")] | length == 0' "$OC_STATE/findings.json" >/dev/null || fail 'OC-J score 3 entered the open set'
[ ! -s "$OC_CASE_ROOT/lanes/2026-08-02/findings.jsonl" ] || fail 'OC-J score 3 leaked into ledger proposals'

# OC-J score 2 crosses the deliberately narrow threshold. Its claim retains
# the scoring rationale and its proposal uses the layer-3 three-minute cost.
setup_ij_case l3-score-two 3301
run_ij 2026-08-01 ij-score-2
run_ij 2026-08-02 ij-score-2
jq -e '
  ([.findings.new[] | select(.repo_id == 3301 and .check_id == "OC-J" and .claim_kind == "first30" and .score == 2 and (.claim | contains("score 2")))] | length) == 1
' "$OC_STATE/report/2026-08-02.json" >/dev/null || fail 'OC-J score 2 did not produce the first30 finding with rationale'
jq -e -s 'length == 1 and .[0].kind == "org-consistency/OC-J" and .[0].confirm_cost == "3分"' "$OC_CASE_ROOT/lanes/2026-08-02/findings.jsonl" >/dev/null || fail 'OC-J score 2 violated the layer-3 proposal mapping'

# A schema breach has the same INVALID-OUTPUT contract as layer 2, including
# non-fresh cells and self-health. The same single-repo queue remains retryable
# and accepts a valid output on the next configured weekly night.
setup_ij_case l3-invalid 3401
run_ij 2026-08-01 ij-valid
run_ij 2026-08-02 invalid-json
jq -e '
  ([.cells[] | select(.repo_id == 3401 and .layer == 3 and .status == "INVALID-OUTPUT" and .fresh == false)] | length) == 2 and
  ([.findings.self_health[] | select(.claim_kind == "invalid-output")] | length) == 1
' "$OC_STATE/report/2026-08-02.json" >/dev/null || fail 'invalid OC-I/J output did not fail closed'
run_ij 2026-08-09 ij-valid
jq -e '([.cells[] | select(.repo_id == 3401 and .layer == 3 and .status == "RUN" and .fresh == true)] | length) == 2' "$OC_STATE/report/2026-08-09.json" >/dev/null || fail 'valid OC-I/J retry was not accepted'

# Fairness is attempt-based. Under cap=1, a permanently failing first repo gets
# ij_night but never ij_head; the untouched second repo runs the next Sunday and
# records both fields instead of being starved by the failure retry.
setup_ij_case l3-fairness 3501 3
selective_ij_cmd="OC_FAKE_SEAT_FAIL_REPO='caty-ai/demo-1' /bin/bash '$FAKE_SEAT'"
run_ij 2026-08-01 selective-valid OC_SEAT_CMD="$selective_ij_cmd"
run_ij 2026-08-02 selective-valid OC_SEAT_CMD="$selective_ij_cmd"
jq -e '
  ([.cells[] | select(.repo_id == 3501 and .layer == 3 and .status == "NOT-RUN" and .reason == "seat-failed")] | length) == 2
' "$OC_STATE/report/2026-08-02.json" >/dev/null || {
  jq '.cells[] | select(.layer == 3)' "$OC_STATE/report/2026-08-02.json" >&2
  fail 'failed OC-I/J attempt did not produce both non-running cells'
}
jq -e '
  .repos["3501"].layer3.ij_night == "2026-08-02" and
  ((.repos["3501"].layer3.ij_head // "") == "")
' "$OC_STATE/repos.json" >/dev/null || fail 'failed OC-I/J attempt did not separate ij_night from ij_head'
run_ij 2026-08-09 selective-valid OC_SEAT_CMD="$selective_ij_cmd"
jq -e '
  ([.cells[] | select(.repo_id == 3502 and .layer == 3 and .status == "RUN")] | length) == 2 and
  ([.cells[] | select(.repo_id == 3501 and .layer == 3 and .deferred != true)] | length) == 0
' "$OC_STATE/report/2026-08-09.json" >/dev/null || fail 'permanent OC-I/J failure starved the next repository'
jq -e '
  .repos["3501"].layer3.ij_night == "2026-08-02" and
  ((.repos["3501"].layer3.ij_head // "") == "") and
  .repos["3502"].layer3.ij_night == "2026-08-09" and
  .repos["3502"].layer3.ij_head == .repos["3502"].head
' "$OC_STATE/repos.json" >/dev/null || fail 'successful OC-I/J attempt did not advance both audit fields'

printf 'test_lane_org_consistency_layer3: PASS\n'
