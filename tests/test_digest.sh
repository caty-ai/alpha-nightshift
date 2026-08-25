#!/bin/bash
# shellcheck disable=SC1091
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
. "$TEST_DIR/helpers.sh"
. "$ROOT/lib/common.sh"
. "$ROOT/lib/ledger.sh"
. "$ROOT/lib/digest.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-digest.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT
NIGHT_ID=$(date -v-8H '+%F')

write_digest_config() {
  config_path=$1
  state_path=$2
  printf '%s\n' \
    "NIGHTSHIFT_STATE_DIR='$state_path'" \
    "LANE_CMD_1=':'" \
    "LANE_HOME_LINKS=''" \
    > "$config_path"
}

append_freshness_config() {
  config_path=$1
  report_dir=$2
  enforce=$3
  max_age_days=$4
  printf '%s\n' \
    "OC_FRESHNESS_ENFORCE='$enforce'" \
    "OC_REPORT_DIR='$report_dir'" \
    "OC_REPORT_MAX_AGE_DAYS='$max_age_days'" \
    >> "$config_path"
}

run_digest() {
  config_path=$1
  NIGHTSHIFT_CONFIG="$config_path" /bin/bash "$ROOT/bin/nightshift-dispatch" digest >/dev/null
}

seed_record() {
  state_path=$1
  record=$2
  STATE_DIR=$state_path
  mkdir -p "$STATE_DIR/ledger"
  ledger_append "$record"
}

write_report_fixture() {
  report_dir=$1
  report_name=$2
  mkdir -p "$report_dir"
  printf '%s\n' '{}' > "$report_dir/$report_name.json"
}

assert_zero_kpi() {
  digest_path=$1
  assert_contains 'total: 0' "$digest_path"
  assert_contains 'decision_rate: 0/0 (not calibrated)' "$digest_path"
  assert_contains 'completion_rate: 0/0 (not calibrated)' "$digest_path"
  assert_contains 'rejection_rate: 0/0 (not calibrated)' "$digest_path"
  assert_contains \
    'revert_rate: unavailable (no explicit revert relation)' \
    "$digest_path"
}

dead_state="$TEST_TMP/dead-state"
dead_config="$TEST_TMP/dead.conf"
write_digest_config "$dead_config" "$dead_state"
run_digest "$dead_config"
dead_digest="$dead_state/digests/$NIGHT_ID.md"
assert_file_exists "$dead_digest"
assert_contains DEAD_MAN "$dead_digest"
assert_contains '夜番は起きなかった' "$dead_digest"
assert_contains 'org-consistency freshness: disabled' "$dead_digest"
assert_zero_kpi "$dead_digest"
printf '%s\n' 'sentinel-that-must-be-overwritten' >> "$dead_digest"
run_digest "$dead_config"
assert_not_contains 'sentinel-that-must-be-overwritten' "$dead_digest"
jq -e --arg night_id "$NIGHT_ID" \
  'select(.night_id == $night_id and .type == "digest_written" and .dead_man == true)' \
  "$dead_state/ledger/ledger.jsonl" >/dev/null ||
  fail "dead-man digest record was not appended"

zero_state="$TEST_TMP/zero-state"
zero_config="$TEST_TMP/zero.conf"
write_digest_config "$zero_config" "$zero_state"
seed_record "$zero_state" "$(jq -n -c --arg night "$NIGHT_ID" \
  '{ts:"x", night_id:$night, type:"run_start"}')"
seed_record "$zero_state" "$(jq -n -c --arg night "$NIGHT_ID" \
  '{ts:"x", night_id:$night, type:"run_end", lanes_run:1, findings_count:0, wallclock_sec:2, budget:{tokens_spent:0}}')"
run_digest "$zero_config"
zero_digest="$zero_state/digests/$NIGHT_ID.md"
assert_file_exists "$zero_digest"
assert_contains ZERO "$zero_digest"
assert_contains '観測項目は0件' "$zero_digest"
assert_not_contains '夜番は起きなかった' "$zero_digest"
assert_zero_kpi "$zero_digest"

normal_state="$TEST_TMP/normal-state"
normal_config="$TEST_TMP/normal.conf"
write_digest_config "$normal_config" "$normal_state"
seed_record "$normal_state" "$(jq -n -c --arg night "$NIGHT_ID" \
  '{ts:"x", night_id:$night, type:"run_start"}')"
seed_record "$normal_state" "$(jq -n -c --arg night "$NIGHT_ID" \
  '{ts:"x", night_id:$night, type:"finding", id:"f1", repo:"r", target:"a", symptom:"first symptom", kind:"UX", status:"open", confirm_cost:"即断", date:$night}')"
seed_record "$normal_state" "$(jq -n -c --arg night "$NIGHT_ID" \
  '{ts:"x", night_id:$night, type:"finding", id:"f2", repo:"r", target:"b", symptom:"second symptom", kind:"Bug", status:"open", confirm_cost:"3分", date:$night}')"
seed_record "$normal_state" "$(jq -n -c --arg night "$NIGHT_ID" \
  '{ts:"x", night_id:$night, type:"finding", id:"f3", repo:"r", target:"c", symptom:"fixed symptom", kind:"Bug", status:"open", confirm_cost:"1分", date:$night}')"
seed_record "$normal_state" "$(jq -n -c --arg night "$NIGHT_ID" \
  '{ts:"x", night_id:$night, type:"finding", id:"f4", repo:"r", target:"d", symptom:"rejected symptom", kind:"Bug", status:"open", confirm_cost:"1分", date:$night}')"
seed_record "$normal_state" "$(jq -n -c --arg night "$NIGHT_ID" \
  '{ts:"x", night_id:$night, type:"finding", id:"f5", repo:"r", target:"e", symptom:"another open symptom", kind:"Bug", status:"open", confirm_cost:"1分", date:$night}')"
seed_record "$normal_state" "$(jq -n -c --arg night "$NIGHT_ID" \
  '{ts:"x", night_id:$night, type:"finding", id:"f6", repo:"r", target:"f", symptom:"regression symptom", kind:"Bug", status:"open", confirm_cost:"1分", date:$night, evidence:["evidence/regression.png"]}')"
seed_record "$normal_state" \
  '{"type":"verdict","verdict_id":"v-f2","ts":"2026-07-29T01:00:00Z","finding_id":"f2","status":"adopted","actor":"human","source":"manual-comment","source_ref":"c:f2","observed_at":"2026-07-29T01:00:00Z"}'
seed_record "$normal_state" \
  '{"type":"verdict","verdict_id":"v-f3","ts":"2026-07-29T01:00:00Z","finding_id":"f3","status":"fixed","actor":"human","source":"manual-comment","source_ref":"c:f3","observed_at":"2026-07-29T01:00:01Z"}'
seed_record "$normal_state" \
  '{"type":"verdict","verdict_id":"v-f4","ts":"2026-07-29T01:00:00Z","finding_id":"f4","status":"rejected","actor":"human","source":"manual-comment","source_ref":"c:f4","observed_at":"2026-07-29T01:00:02Z","rejection_reason":"not appropriate"}'
seed_record "$normal_state" \
  '{"type":"verdict","verdict_id":"v-f6-fixed","ts":"2026-07-29T01:00:00Z","finding_id":"f6","status":"fixed","actor":"human","source":"manual-comment","source_ref":"c:f6-fixed","observed_at":"2026-07-29T01:00:04Z"}'
seed_record "$normal_state" \
  '{"type":"verdict","verdict_id":"v-f6-regression","ts":"2026-07-29T02:00:00Z","finding_id":"f6","status":"regression","actor":"observer","source":"manual-comment","source_ref":"observation:f6","observed_at":"2026-07-29T02:00:00Z"}'
seed_record "$normal_state" "$(jq -n -c --arg night "$NIGHT_ID" \
  '{ts:"x", night_id:$night, type:"run_end", lanes_run:1, findings_count:6, wallclock_sec:3, budget:{tokens_spent:4}}')"
run_digest "$normal_config"
normal_digest="$normal_state/digests/$NIGHT_ID.md"
assert_file_exists "$normal_digest"
assert_contains NORMAL "$normal_digest"
assert_contains 'first symptom（確認: 即断）' "$normal_digest"
assert_contains 'second symptom（確認: 3分）' "$normal_digest"
assert_contains 'another open symptom（確認: 1分）' "$normal_digest"
assert_contains '[regression] regression symptom' "$normal_digest"
assert_not_contains 'fixed symptom' "$normal_digest"
assert_not_contains 'rejected symptom' "$normal_digest"
assert_contains 'total: 6' "$normal_digest"
assert_contains 'open: 2' "$normal_digest"
assert_contains 'adopted: 1' "$normal_digest"
assert_contains 'fixed: 1' "$normal_digest"
assert_contains 'rejected: 1' "$normal_digest"
assert_contains 'regression: 1' "$normal_digest"
assert_contains 'deferred: 0' "$normal_digest"
assert_contains 'decision_rate: 3/6' "$normal_digest"
assert_contains 'completion_rate: 1/6' "$normal_digest"
assert_contains 'rejection_rate: 1/3' "$normal_digest"
assert_contains \
  'revert_rate: unavailable (no explicit revert relation)' \
  "$normal_digest"

lock_state="$TEST_TMP/lock-state"
lock_config="$TEST_TMP/lock.conf"
write_digest_config "$lock_config" "$lock_state"
seed_record "$lock_state" "$(jq -n -c --arg night "$NIGHT_ID" \
  '{ts:"x", night_id:$night, type:"skip", reason:"lock_held"}')"
run_digest "$lock_config"
lock_digest="$lock_state/digests/$NIGHT_ID.md"
assert_contains LOCK_HELD "$lock_digest"
assert_contains 'ロック残留のため skip' "$lock_digest"
assert_zero_kpi "$lock_digest"

aborted_state="$TEST_TMP/aborted-state"
aborted_config="$TEST_TMP/aborted.conf"
write_digest_config "$aborted_config" "$aborted_state"
seed_record "$aborted_state" "$(jq -n -c --arg night "$NIGHT_ID" \
  '{ts:"x", night_id:$night, type:"run_start"}')"
seed_record "$aborted_state" "$(jq -n -c --arg night "$NIGHT_ID" \
  '{ts:"x", night_id:$night, type:"run_end", lanes_run:1, findings_count:0, wallclock_sec:1}')"
seed_record "$aborted_state" "$(jq -n -c --arg night "$NIGHT_ID" \
  '{ts:"x", night_id:$night, type:"run_start"}')"
run_digest "$aborted_config"
aborted_digest="$aborted_state/digests/$NIGHT_ID.md"
assert_contains ABORTED "$aborted_digest"
assert_contains '中断されました' "$aborted_digest"
assert_zero_kpi "$aborted_digest"

signal_aborted_state="$TEST_TMP/signal-aborted-state"
signal_aborted_config="$TEST_TMP/signal-aborted.conf"
write_digest_config "$signal_aborted_config" "$signal_aborted_state"
seed_record "$signal_aborted_state" "$(jq -n -c --arg night "$NIGHT_ID" \
  '{ts:"x", night_id:$night, type:"run_start"}')"
seed_record "$signal_aborted_state" "$(jq -n -c --arg night "$NIGHT_ID" \
  '{ts:"x", night_id:$night, type:"run_end", aborted:true, signal:"TERM", lanes_run:1, findings_count:0, wallclock_sec:1}')"
run_digest "$signal_aborted_config"
assert_contains ABORTED "$signal_aborted_state/digests/$NIGHT_ID.md"
assert_zero_kpi "$signal_aborted_state/digests/$NIGHT_ID.md"

skipped_state="$TEST_TMP/skipped-state"
skipped_config="$TEST_TMP/skipped.conf"
write_digest_config "$skipped_config" "$skipped_state"
seed_record "$skipped_state" "$(jq -n -c --arg night "$NIGHT_ID" \
  '{ts:"x", night_id:$night, type:"run_start"}')"
seed_record "$skipped_state" "$(jq -n -c --arg night "$NIGHT_ID" \
  '{ts:"x", night_id:$night, type:"skip", reason:"budget_exhausted"}')"
seed_record "$skipped_state" "$(jq -n -c --arg night "$NIGHT_ID" \
  '{ts:"x", night_id:$night, type:"run_end", lanes_run:0, findings_count:0, wallclock_sec:1}')"
run_digest "$skipped_config"
skipped_digest="$skipped_state/digests/$NIGHT_ID.md"
assert_contains SKIPPED "$skipped_digest"
assert_contains 'budget_exhausted' "$skipped_digest"
assert_zero_kpi "$skipped_digest"

fresh_state="$TEST_TMP/fresh-state"
fresh_config="$TEST_TMP/fresh.conf"
fresh_report_dir="$fresh_state/org-consistency/report"
write_digest_config "$fresh_config" "$fresh_state"
append_freshness_config "$fresh_config" "$fresh_report_dir" 1 3
write_report_fixture "$fresh_report_dir" "$NIGHT_ID"
run_digest "$fresh_config"
fresh_digest="$fresh_state/digests/$NIGHT_ID.md"
assert_contains "org-consistency freshness: OK ($NIGHT_ID age 0d)" "$fresh_digest"
assert_not_contains 'WARNING: org-consistency has never published a report' "$fresh_digest"
assert_not_contains 'WARNING: org-consistency latest report is' "$fresh_digest"

stale_state="$TEST_TMP/stale-state"
stale_config="$TEST_TMP/stale.conf"
stale_report_dir="$stale_state/org-consistency/report"
write_digest_config "$stale_config" "$stale_state"
append_freshness_config "$stale_config" "$stale_report_dir" 1 3
write_report_fixture "$stale_report_dir" "$NIGHT_ID"
touch -t "$(date -v-5d '+%Y%m%d0000')" "$stale_report_dir/$NIGHT_ID.json"
run_digest "$stale_config"
stale_digest="$stale_state/digests/$NIGHT_ID.md"
assert_contains 'WARNING: org-consistency latest report is 5 days old (max 3)' "$stale_digest"

boundary_state="$TEST_TMP/boundary-state"
boundary_config="$TEST_TMP/boundary.conf"
boundary_report_dir="$boundary_state/org-consistency/report"
write_digest_config "$boundary_config" "$boundary_state"
append_freshness_config "$boundary_config" "$boundary_report_dir" 1 3
write_report_fixture "$boundary_report_dir" "$NIGHT_ID"
boundary_now=1800000000
boundary_mtime=$((boundary_now - 3 * 86400))
touch -t "$(date -r "$boundary_mtime" '+%Y%m%d%H%M.%S')" "$boundary_report_dir/$NIGHT_ID.json"
digest_org_consistency_freshness 1 "$boundary_report_dir" 3 "$boundary_now" > "$TEST_TMP/boundary.out"
assert_contains "org-consistency freshness: OK ($NIGHT_ID age 3d)" "$TEST_TMP/boundary.out"
assert_not_contains 'WARNING: org-consistency latest report is' "$TEST_TMP/boundary.out"

over_boundary_mtime=$((boundary_now - 3 * 86400 - 3600))
touch -t "$(date -r "$over_boundary_mtime" '+%Y%m%d%H%M.%S')" "$boundary_report_dir/$NIGHT_ID.json"
digest_org_consistency_freshness 1 "$boundary_report_dir" 3 "$boundary_now" > "$TEST_TMP/over-boundary.out"
assert_contains 'WARNING: org-consistency latest report is 3 days old (max 3)' "$TEST_TMP/over-boundary.out"

missing_state="$TEST_TMP/missing-state"
missing_config="$TEST_TMP/missing.conf"
missing_report_dir="$missing_state/org-consistency/report"
write_digest_config "$missing_config" "$missing_state"
append_freshness_config "$missing_config" "$missing_report_dir" 1 3
run_digest "$missing_config"
missing_digest="$missing_state/digests/$NIGHT_ID.md"
assert_contains 'WARNING: org-consistency has never published a report' "$missing_digest"
mkdir -p "$missing_report_dir"
run_digest "$missing_config"
assert_contains 'WARNING: org-consistency has never published a report' "$missing_digest"

invalid_state="$TEST_TMP/invalid-state"
invalid_config="$TEST_TMP/invalid.conf"
invalid_report_dir="$invalid_state/org-consistency/report"
write_digest_config "$invalid_config" "$invalid_state"
append_freshness_config "$invalid_config" "$invalid_report_dir" 1 invalid
if run_digest "$invalid_config"; then
  fail 'digest should fail when OC_REPORT_MAX_AGE_DAYS is invalid'
fi

invalid_disabled_state="$TEST_TMP/invalid-disabled-state"
invalid_disabled_config="$TEST_TMP/invalid-disabled.conf"
write_digest_config "$invalid_disabled_config" "$invalid_disabled_state"
append_freshness_config "$invalid_disabled_config" "$invalid_disabled_state/report" 0 invalid
if run_digest "$invalid_disabled_config"; then
  fail 'digest accepted invalid OC_REPORT_MAX_AGE_DAYS while freshness enforcement was disabled'
fi

invalid_enforce_state="$TEST_TMP/invalid-enforce-state"
invalid_enforce_config="$TEST_TMP/invalid-enforce.conf"
write_digest_config "$invalid_enforce_config" "$invalid_enforce_state"
append_freshness_config "$invalid_enforce_config" "$invalid_enforce_state/report" maybe 3
if run_digest "$invalid_enforce_config"; then
  fail 'digest accepted OC_FRESHNESS_ENFORCE outside 0/1'
fi

printf 'test_digest: PASS\n'
