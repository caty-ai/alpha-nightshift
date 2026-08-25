#!/bin/bash
# shellcheck disable=SC1091
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
. "$TEST_DIR/helpers.sh"
. "$TEST_DIR/fixtures/org-consistency/lib.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-org-life.XXXXXX")
case_roots=
trap 'rm -rf "$TEST_TMP" $case_roots' EXIT

make_nonbaseline_open() {
  prefix=$1
  oc_case_init "$prefix"
  case_roots="$case_roots $OC_CASE_ROOT"
  oc_make_remote family-os main pass
  oc_write_single_api 501 family-os main
  oc_run 2026-08-01
  [ "$(jq '.findings | length' "$OC_STATE/findings.json")" -eq 0 ] || fail "$prefix baseline was not empty"
  oc_write_checker "$OC_WORK/family-os" fail
  oc_commit "$OC_WORK/family-os" add-failure
  oc_push_work family-os main
  oc_run 2026-08-02
  jq -e '.findings | length == 2 and all(.[]; .baseline == false and .status == "open")' "$OC_STATE/findings.json" >/dev/null || fail "$prefix did not create a non-baseline open finding"
}

# A fresh RUN with no repeated observation is the only resolved-candidate gate.
make_nonbaseline_open resolved
resolved_state=$OC_STATE
resolved_work=$OC_WORK
oc_write_checker "$resolved_work/family-os" pass
oc_commit "$resolved_work/family-os" fix-failure
oc_push_work family-os main
oc_run 2026-08-03
jq -e '.findings | length == 2 and all(.[]; .status == "resolved-candidate" and .resolved_candidate_night == "2026-08-03")' "$resolved_state/findings.json" >/dev/null || fail 'fresh RUN did not produce resolved-candidates'
jq -e '.findings.resolved_candidates | length == 2' "$resolved_state/report/2026-08-03.json" >/dev/null || fail 'resolved-candidates were absent from the report'
assert_contains '## Digest vocabulary mapping' "$resolved_state/report/2026-08-03.md"
assert_contains 'ABORTED-equivalent' "$resolved_state/report/2026-08-03.md"
assert_contains 'ZERO-equivalent' "$resolved_state/report/2026-08-03.md"
assert_contains '## Resolved candidates' "$resolved_state/report/2026-08-03.md"
oc_write_checker "$resolved_work/family-os" fail
oc_commit "$resolved_work/family-os" regress-after-resolution
oc_push_work family-os main
oc_run 2026-08-04
jq -e '.findings | length == 2 and all(.[]; .status == "open" and .last_seen == "2026-08-04" and (has("resolved_candidate_night") | not))' "$resolved_state/findings.json" >/dev/null || fail 'reappearing findings stayed falsely resolved'
jq -e '[.events[] | select(.type == "REOPENED" and .from == "resolved-candidate")] | length == 2' "$resolved_state/journal/2026-08-04.json" >/dev/null || fail 'finding regression did not record REOPENED events'

# A baseline finding resolves silently in the journal, never as a close proposal.
oc_case_init baseline-resolve
case_roots="$case_roots $OC_CASE_ROOT"
oc_make_remote family-os main fail
oc_write_single_api 502 family-os main
oc_run 2026-08-01
jq -e '.findings | length == 2 and all(.[]; .baseline == true)' "$OC_STATE/findings.json" >/dev/null || fail 'baseline-resolution precondition was empty'
oc_write_checker "$OC_WORK/family-os" pass
oc_commit "$OC_WORK/family-os" baseline-fixed
oc_push_work family-os main
oc_run 2026-08-02
jq -e '.findings | length == 2 and all(.[]; .status == "resolved")' "$OC_STATE/findings.json" >/dev/null || fail 'baseline findings did not resolve silently'
jq -e '[.events[] | select(.type == "BASELINE-RESOLVED")] | length == 2' "$OC_STATE/journal/2026-08-02.json" >/dev/null || fail 'baseline resolved journal events are missing'
jq -e '.findings.resolved_candidates | length == 0' "$OC_STATE/report/2026-08-02.json" >/dev/null || fail 'baseline findings leaked into resolved-candidates'

# Fetch failure is NOT-RUN and cannot resolve existing findings.
make_nonbaseline_open notrun
notrun_state=$OC_STATE
mv "$OC_REMOTES/family-os.git" "$OC_REMOTES/family-os.git.offline"
oc_run 2026-08-03
[ "$(oc_status 2026-08-03 501)" = NOT-RUN ] || fail 'fetch failure was not NOT-RUN'
jq -e '.findings | all(.[]; .status == "open")' "$notrun_state/findings.json" >/dev/null || fail 'NOT-RUN resolved an open finding'

# A checker that prints a FAILED block while exiting zero violated the checker
# contract. It is NOT-RUN and cannot resolve the existing open findings.
make_nonbaseline_open zero-exit-failed
zero_exit_state=$OC_STATE
oc_write_checker "$OC_WORK/family-os" exit-zero-fail
oc_commit "$OC_WORK/family-os" zero-exit-with-failed-block
oc_push_work family-os main
oc_run 2026-08-03
jq -e '.cells[0].status == "NOT-RUN" and .cells[0].reason == "checker-contract-violation" and .cells[0].fresh == false' "$zero_exit_state/report/2026-08-03.json" >/dev/null || fail 'exit-zero FAILED block was accepted as a fresh RUN'
jq -e '.findings | all(.[]; .status == "open")' "$zero_exit_state/findings.json" >/dev/null || fail 'checker contract violation resolved an open finding'

# A missing checker is NO-INPUT and cannot resolve existing findings.
make_nonbaseline_open noinput
noinput_state=$OC_STATE
mv "$OC_WORK/family-os/tools/check_registry.py" "$OC_WORK/family-os/tools/check_registry.py.absent"
oc_commit "$OC_WORK/family-os" remove-checker-input
oc_push_work family-os main
oc_run 2026-08-03
[ "$(oc_status 2026-08-03 501)" = NO-INPUT ] || fail 'missing checker was not NO-INPUT'
jq -e '.findings | all(.[]; .status == "open")' "$noinput_state/findings.json" >/dev/null || fail 'NO-INPUT resolved an open finding'

# Degraded/skipped output is STALE-INPUT and cannot resolve existing findings.
make_nonbaseline_open stale
stale_state=$OC_STATE
oc_write_checker "$OC_WORK/family-os" degraded
oc_commit "$OC_WORK/family-os" degrade-checker
oc_push_work family-os main
oc_run 2026-08-03
[ "$(oc_status 2026-08-03 501)" = STALE-INPUT ] || fail 'degraded checker output was not STALE-INPUT'
jq -e '.findings | all(.[]; .status == "open")' "$stale_state/findings.json" >/dev/null || fail 'STALE-INPUT resolved an open finding'

# A last-good target snapshot also makes the cell input stale, even if its Git
# fetch succeeds; an API outage must never create close proposals.
make_nonbaseline_open target-stale
target_stale_state=$OC_STATE
oc_write_checker "$OC_WORK/family-os" pass
oc_commit "$OC_WORK/family-os" target-stale-would-resolve
oc_push_work family-os main
oc_run 2026-08-03 OC_TEST_API_FAIL=1
[ "$(oc_status 2026-08-03 501)" = STALE-INPUT ] || fail 'stale target snapshot did not stale the otherwise fresh OC-A cell'
jq -e '.findings | all(.[]; .status == "open")' "$target_stale_state/findings.json" >/dev/null || fail 'stale target snapshot resolved an open finding'

# Leaving scope is visible but never misreported as resolution in S1.
make_nonbaseline_open leftscope
left_state=$OC_STATE
printf '%s\n' '[]' > "$OC_API"
oc_run 2026-08-03
jq -e '.scope.left_scope | length == 1' "$left_state/report/2026-08-03.json" >/dev/null || fail 'LEFT-SCOPE was not visible'
jq -e '.findings | all(.[]; .status == "open")' "$left_state/findings.json" >/dev/null || fail 'LEFT-SCOPE resolved an open finding'

printf 'test_lane_org_consistency_lifecycle: PASS\n'
