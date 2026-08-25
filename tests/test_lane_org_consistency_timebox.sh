#!/bin/bash
# shellcheck disable=SC1091
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
. "$TEST_DIR/helpers.sh"
. "$TEST_DIR/fixtures/org-consistency/lib.sh"

oc_case_init timebox
case_root=$OC_CASE_ROOT
case_roots=$case_root
trap 'rm -rf $case_roots' EXIT
oc_make_remote family-os main pass
oc_write_single_api 801 family-os main

lane="$OC_CASE_ROOT/lanes/2026-08-01"
mkdir -p "$lane/tmp" "$lane/home"
/usr/bin/env -i \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin \
  HOME="$lane/home" TMPDIR="$lane/tmp" LANG=C TERM=dumb \
  NIGHT_ID=2026-08-01 LANE_DIR="$lane" GIT_CEILING_DIRECTORIES="$lane" \
  OC_STATE_DIR="$OC_STATE" OC_API_FIXTURE="$OC_API" \
  OC_TEST_FIXTURE_GIT_ROOT="$OC_REMOTES" \
  OC_TEST_MUTATE="${OC_TEST_MUTATE:-}" \
  OC_TEST_PAUSE_AFTER_PLAN_SEC=20 \
  /bin/bash "$OC_RUN_SH" > "$OC_CASE_ROOT/lane.out" 2>&1 &
lane_pid=$!
report="$OC_STATE/report/2026-08-01.json"
plan="$OC_STATE/plan-2026-08-01.json"
attempt=0
while [ "$attempt" -lt 100 ] && { [ ! -s "$report" ] || [ ! -s "$plan" ]; }; do
  sleep 0.05
  attempt=$((attempt + 1))
done
[ -s "$report" ] && [ -s "$plan" ] || fail 'write-ahead plan/partial report were not published before the paused layer'

# Parse while the lane is still alive: tmp->mv publication must never expose a
# torn JSON document, and the completion flag belongs only to the final stage.
jq -e 'has("complete") | not' "$report" >/dev/null || fail 'partial report was marked complete'
assert_not_contains 'COMPLETE:' "$OC_STATE/report/2026-08-01.md"
jq -e '.scope.not_run == 1 and .cells[0].status == "NOT-RUN" and .cells[0].reason == "missing-result"' "$report" >/dev/null || fail 'plan/result reconciliation did not expose partial NOT-RUN'
jq -e '(.cells | length) == 1 and (.cells[0] | has("result") | not)' "$plan" >/dev/null || fail 'write-ahead plan was not written before execution'

kill -TERM "$lane_pid"
lane_rc=0
wait "$lane_pid" || lane_rc=$?
[ "$lane_rc" -ne 0 ] || fail 'timeboxed partial lane exited successfully'
jq -e 'has("complete") | not' "$report" >/dev/null || fail 'killed lane retroactively marked the partial report complete'
[ ! -e "$OC_STATE/.lock" ] || fail 'killed lane retained the state lock'

# Exercise readers across live initial/cell/final replacements, not only after
# a completed write. Every visible report must remain parseable throughout.
oc_case_init atomic-reader
case_roots="$case_roots $OC_CASE_ROOT"
oc_make_remote family-os main slow-pass
oc_write_single_api 802 family-os main
oc_run 2026-08-02 > "$OC_CASE_ROOT/lane.out" 2>&1 &
atomic_pid=$!
atomic_report="$OC_STATE/report/2026-08-02.json"
reader_iterations=0
while kill -0 "$atomic_pid" 2>/dev/null; do
  if [ -e "$atomic_report" ]; then
    jq -e 'type == "object" and .night_id == "2026-08-02"' "$atomic_report" >/dev/null || fail 'reader observed a torn atomic report'
    reader_iterations=$((reader_iterations + 1))
  fi
  sleep 0.01
done
wait "$atomic_pid" || fail 'atomic-reader fixture lane failed'
[ "$reader_iterations" -gt 1 ] || fail 'atomic-reader probe did not overlap report publication'
jq -e '.complete == true' "$atomic_report" >/dev/null || fail 'atomic-reader run did not reach its final stage'

printf 'test_lane_org_consistency_timebox: PASS\n'
