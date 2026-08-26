#!/bin/bash
# shellcheck disable=SC1091
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
. "$TEST_DIR/helpers.sh"
. "$TEST_DIR/fixtures/org-consistency/lib.sh"
. "$ROOT/lib/common.sh"
. "$ROOT/lib/ledger.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-org-life.XXXXXX")
case_roots=
trap 'rm -rf "$TEST_TMP" $case_roots' EXIT

make_nonbaseline_open() {
  prefix=$1
  oc_case_init "$prefix"
  case_roots="$case_roots $OC_CASE_ROOT"
  oc_make_remote family-os main pass
  mkdir -p "$OC_WORK/family-os/registry"
  printf '%s\n' '{"version":1,"modules":[]}' > "$OC_WORK/family-os/registry/modules.json"
  oc_commit "$OC_WORK/family-os" add-registry
  oc_push_work family-os main
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

# Leaving scope is visible, uses its own lifecycle vocabulary, and never leaks
# into the resolved-candidate path.
make_nonbaseline_open leftscope
left_state=$OC_STATE
printf '%s\n' '[]' > "$OC_API"
oc_run 2026-08-03 OC_LEFT_SCOPE_WINDOW_NIGHTS=2
jq -e '.scope.left_scope | length == 1' "$left_state/report/2026-08-03.json" >/dev/null || fail 'LEFT-SCOPE was not visible'
jq -e '.findings | all(.[]; if (.repo_id | type) == "number" then (.status == "target-left-scope" and .left_scope_nights == 1) else true end)' "$left_state/findings.json" >/dev/null || fail 'LEFT-SCOPE did not use its dedicated status'
jq -e '.findings.resolved_candidates | length == 0' "$left_state/report/2026-08-03.json" >/dev/null || fail 'LEFT-SCOPE leaked into close proposals'

# A stale target snapshot is not a fresh scope observation, so it must not
# advance the consecutive-night retirement window.
oc_run 2026-08-04 OC_LEFT_SCOPE_WINDOW_NIGHTS=2 OC_TEST_API_FAIL=1
jq -e '.findings | all(.[]; if (.repo_id | type) == "number" then (.status == "target-left-scope" and .left_scope_nights == 1) else true end)' "$left_state/findings.json" >/dev/null || fail 'stale target night advanced the LEFT-SCOPE window'
oc_run 2026-08-05 OC_LEFT_SCOPE_WINDOW_NIGHTS=2
jq -e '.findings | all(.[]; if (.repo_id | type) == "number" then (.status == "left-scope-expired" and .left_scope_nights == 2) else true end)' "$left_state/findings.json" >/dev/null || fail 'fresh LEFT-SCOPE nights did not expire at the configured window'
jq -e '.scope.left_scope_expired == 2 and ([.events[] | select(.type == "LEFT-SCOPE-EXPIRED")] | length) == 2' "$left_state/report/2026-08-05.json" >/dev/null || fail 'LEFT-SCOPE expiry was not reported and journaled'
oc_write_single_api 501 family-os main
oc_run 2026-08-06 OC_LEFT_SCOPE_WINDOW_NIGHTS=2
jq -e '.findings | all(.[]; if (.repo_id | type) == "number" then (.status == "open" and (has("left_scope_nights") | not)) else true end)' "$left_state/findings.json" >/dev/null || fail 'returning repository did not reopen expired findings'
jq -e '[.events[] | select(.type == "REOPENED" and .from == "left-scope-expired")] | length == 2' "$left_state/journal/2026-08-06.json" >/dev/null || fail 'return from scope did not record REOPENED events'

# A one-night window expires on the first fresh absence rather than requiring
# an accidental second run.
make_nonbaseline_open leftscope-one
printf '%s\n' '[]' > "$OC_API"
oc_run 2026-08-03 OC_LEFT_SCOPE_WINDOW_NIGHTS=1
jq -e '.findings | all(.[]; if (.repo_id | type) == "number" then (.status == "left-scope-expired" and .left_scope_nights == 1) else true end)' "$OC_STATE/findings.json" >/dev/null || fail 'one-night LEFT-SCOPE window had an off-by-one delay'

# A fingerprint spec change is a one-way, quiet migration: only the structured
# old->new mapping is applied, while current observations and close proposals
# stay suppressed for the whole night.
make_nonbaseline_open migration
old_fps=$(jq -c '[.findings[].fingerprint] | sort' "$OC_STATE/findings.json")
oc_run 2026-08-03 OC_FP_SPEC_VERSION=3
new_fps=$(jq -c '[.findings[].fingerprint] | sort' "$OC_STATE/findings.json")
[ "$old_fps" != "$new_fps" ] || fail 'fp migration did not change the stored fingerprints'
jq -e '.fp_spec_version == "3" and (.findings | length) == 2 and all(.findings[]; .fp_spec_version == "3" and .status == "open")' "$OC_STATE/findings.json" >/dev/null || fail 'fp migration damaged the ledger state'
jq -e '.migration_mode == true and .quiet_mode == "migration" and .migration.from == "2" and .migration.to == "3" and (.migration.mappings | length) == 2 and (.findings.new | length) == 0 and (.findings.resolved_candidates | length) == 0' "$OC_STATE/report/2026-08-03.json" >/dev/null || fail 'migration report did not enforce the quiet contract'
[ ! -s "$OC_CASE_ROOT/lanes/2026-08-03/findings.jsonl" ] || fail 'migration night leaked ledger proposals'
jq -e '.migration.from == "2" and .migration.to == "3" and (.migration.mappings | length) == 2' "$OC_STATE/journal/2026-08-03.json" >/dev/null || fail 'migration mapping was not journaled'

# A migration remains quiet even when a legitimate stale-input self-health
# event fires during the same complete night.
oc_run 2026-08-04 OC_FP_SPEC_VERSION=4 OC_STALE_ESCALATE_NIGHTS=1 OC_ZERO_STREAK_NIGHTS=99 OC_TEST_API_FAIL=1
jq -e '.migration_mode == true and (.findings.self_health | length) > 0' "$OC_STATE/report/2026-08-04.json" >/dev/null || fail 'migration/self-health overlap was not exercised'
[ ! -s "$OC_CASE_ROOT/lanes/2026-08-04/findings.jsonl" ] || fail 'migration+self-health night leaked ledger proposals'

# The initial baseline is equally quiet when self-health fires.
oc_case_init baseline-self-health
case_roots="$case_roots $OC_CASE_ROOT"
oc_make_remote family-os main pass
oc_write_single_api 504 family-os main
oc_run 2026-08-01 OC_ZERO_STREAK_NIGHTS=1 OC_STALE_ESCALATE_NIGHTS=99
jq -e '.baseline == true and (.findings.self_health | length) > 0' "$OC_STATE/report/2026-08-01.json" >/dev/null || fail 'baseline/self-health overlap was not exercised'
jq -e '[.findings.self_health[] | select(.claim_kind == "zero-streak:OC-A")] | length == 0' "$OC_STATE/report/2026-08-01.json" >/dev/null || fail 'green OC-A checker was treated as a zero-streak merely because it had no failures'
[ ! -s "$OC_CASE_ROOT/lanes/2026-08-01/findings.jsonl" ] || fail 'baseline+self-health night leaked ledger proposals'

# A self-health event resolves silently on the first complete non-firing night,
# then reopens if the same event fires again.
oc_case_init self-health-lifecycle
case_roots="$case_roots $OC_CASE_ROOT"
oc_make_remote family-os main pass
mkdir -p "$OC_WORK/family-os/registry"
printf '%s\n' '{"version":1,"modules":[]}' > "$OC_WORK/family-os/registry/modules.json"
oc_commit "$OC_WORK/family-os" add-registry
oc_push_work family-os main
oc_write_single_api 505 family-os main
oc_run 2026-08-01 OC_ZERO_STREAK_NIGHTS=99 OC_STALE_ESCALATE_NIGHTS=99
oc_run 2026-08-02 OC_ZERO_STREAK_NIGHTS=99 OC_STALE_ESCALATE_NIGHTS=1 OC_TEST_API_FAIL=1
self_health_fp=$(jq -r '.findings[] | select(.check_id == "self-health" and .claim_kind == "targets-stale") | .fingerprint' "$OC_STATE/findings.json")
[ -n "$self_health_fp" ] || fail 'self-health lifecycle did not fire targets-stale'
oc_run 2026-08-03 OC_ZERO_STREAK_NIGHTS=99 OC_STALE_ESCALATE_NIGHTS=1
jq -e --arg fp "$self_health_fp" '.findings[] | select(.fingerprint == $fp) | .status == "resolved"' "$OC_STATE/findings.json" >/dev/null || fail 'non-firing complete night did not resolve self-health'
jq -e --arg fp "$self_health_fp" '[.events[] | select(.type == "SELF-HEALTH-RESOLVED" and .fingerprint == $fp)] | length == 1' "$OC_STATE/journal/2026-08-03.json" >/dev/null || fail 'self-health resolution was not journaled'
jq -e '.findings.resolved_candidates | all(.check_id != "self-health")' "$OC_STATE/report/2026-08-03.json" >/dev/null || fail 'resolved self-health leaked into close proposals'
oc_run 2026-08-04 OC_ZERO_STREAK_NIGHTS=99 OC_STALE_ESCALATE_NIGHTS=1 OC_TEST_API_FAIL=1
jq -e --arg fp "$self_health_fp" '.findings[] | select(.fingerprint == $fp) | .status == "open" and .last_seen == "2026-08-04"' "$OC_STATE/findings.json" >/dev/null || fail 'recurring self-health did not reopen'
jq -e --arg fp "$self_health_fp" '[.events[] | select(.type == "REOPENED" and .fingerprint == $fp and .from == "resolved")] | length == 1' "$OC_STATE/journal/2026-08-04.json" >/dev/null || fail 'self-health reopen was not journaled'

# The same persistent self-health condition is emitted with a night-qualified
# proposal ID, so the central ledger ingests it on consecutive nights instead
# of treating night two as a duplicate.
oc_case_init self-health-ledger
case_roots="$case_roots $OC_CASE_ROOT"
oc_make_remote family-os main pass
mkdir -p "$OC_WORK/family-os/registry"
printf '%s\n' '{"version":1,"modules":[]}' > "$OC_WORK/family-os/registry/modules.json"
oc_commit "$OC_WORK/family-os" add-registry
oc_push_work family-os main
oc_write_single_api 503 family-os main
oc_run 2026-08-01 OC_ZERO_STREAK_NIGHTS=99 OC_STALE_ESCALATE_NIGHTS=99
oc_run 2026-08-02 OC_ZERO_STREAK_NIGHTS=99 OC_STALE_ESCALATE_NIGHTS=1 OC_TEST_API_FAIL=1
oc_run 2026-08-03 OC_ZERO_STREAK_NIGHTS=99 OC_STALE_ESCALATE_NIGHTS=1 OC_TEST_API_FAIL=1
health_two="$OC_CASE_ROOT/lanes/2026-08-02/findings.jsonl"
health_three="$OC_CASE_ROOT/lanes/2026-08-03/findings.jsonl"
jq -e -s 'length > 0 and all(.[]; .kind == "org-consistency/self-health" and (.id | startswith("oc-2026-08-02-")))' "$health_two" >/dev/null || fail 'first self-health observation violated the ledger mapping'
jq -e -s 'length > 0 and all(.[]; .kind == "org-consistency/self-health" and (.id | startswith("oc-2026-08-03-")))' "$health_three" >/dev/null || fail 'second self-health observation did not receive a fresh nightly ID'
STATE_DIR="$OC_CASE_ROOT/central-ledger"
mkdir -p "$STATE_DIR/ledger"
export NIGHT_ID=2026-08-02
ledger_ingest_proposals "$health_two"
health_ingested_two=$LEDGER_INGESTED_COUNT
[ "$health_ingested_two" -gt 0 ] && [ "$LEDGER_DUPLICATE_COUNT" -eq 0 ] && [ "$LEDGER_SKIPPED_COUNT" -eq 0 ] || fail 'first self-health proposal did not reach the central ledger'
export NIGHT_ID=2026-08-03
ledger_ingest_proposals "$health_three"
[ "$LEDGER_INGESTED_COUNT" -eq "$health_ingested_two" ] && [ "$LEDGER_DUPLICATE_COUNT" -eq 0 ] && [ "$LEDGER_SKIPPED_COUNT" -eq 0 ] || fail 'consecutive self-health proposal fell into the ledger duplicate path'

# OBS-1 positive control: two explicit OC-A NO-INPUT nights reach a two-night
# zero-streak threshold. A green checker remains covered by the negative control
# above and must not trigger merely because it found zero registry failures.
oc_case_init zero-streak-positive
case_roots="$case_roots $OC_CASE_ROOT"
oc_make_remote family-os main none
oc_write_single_api 506 family-os main
oc_run 2026-08-01 OC_ZERO_STREAK_NIGHTS=2 OC_STALE_ESCALATE_NIGHTS=99
jq -e '[.findings.self_health[] | select(.claim_kind == "zero-streak:OC-A")] | length == 0' "$OC_STATE/report/2026-08-01.json" >/dev/null || fail 'OC-A zero streak fired one night before its threshold'
oc_run 2026-08-02 OC_ZERO_STREAK_NIGHTS=2 OC_STALE_ESCALATE_NIGHTS=99
jq -e '[.cells[] | select(.check_id == "OC-A" and .status == "NO-INPUT")] | length == 1' "$OC_STATE/report/2026-08-02.json" >/dev/null || fail 'OC-A missing checker control was not NO-INPUT'
jq -e '[.findings.self_health[] | select(.claim_kind == "zero-streak:OC-A")] | length == 1' "$OC_STATE/report/2026-08-02.json" >/dev/null || fail 'two OC-A NO-INPUT nights did not fire zero-streak self-health'

printf 'test_lane_org_consistency_lifecycle: PASS\n'
