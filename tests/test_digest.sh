#!/bin/bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
. "$TEST_DIR/helpers.sh"
. "$ROOT/lib/common.sh"
. "$ROOT/lib/ledger.sh"

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

dead_state="$TEST_TMP/dead-state"
dead_config="$TEST_TMP/dead.conf"
write_digest_config "$dead_config" "$dead_state"
run_digest "$dead_config"
dead_digest="$dead_state/digests/$NIGHT_ID.md"
assert_file_exists "$dead_digest"
assert_contains DEAD_MAN "$dead_digest"
assert_contains '夜番は起きなかった' "$dead_digest"
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
  '{ts:"x", night_id:$night, type:"run_end", lanes_run:1, findings_count:2, wallclock_sec:3, budget:{tokens_spent:4}}')"
run_digest "$normal_config"
normal_digest="$normal_state/digests/$NIGHT_ID.md"
assert_file_exists "$normal_digest"
assert_contains NORMAL "$normal_digest"
assert_contains 'first symptom（確認: 即断）' "$normal_digest"
assert_contains 'second symptom（確認: 3分）' "$normal_digest"

lock_state="$TEST_TMP/lock-state"
lock_config="$TEST_TMP/lock.conf"
write_digest_config "$lock_config" "$lock_state"
seed_record "$lock_state" "$(jq -n -c --arg night "$NIGHT_ID" \
  '{ts:"x", night_id:$night, type:"skip", reason:"lock_held"}')"
run_digest "$lock_config"
lock_digest="$lock_state/digests/$NIGHT_ID.md"
assert_contains LOCK_HELD "$lock_digest"
assert_contains 'ロック残留のため skip' "$lock_digest"

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

signal_aborted_state="$TEST_TMP/signal-aborted-state"
signal_aborted_config="$TEST_TMP/signal-aborted.conf"
write_digest_config "$signal_aborted_config" "$signal_aborted_state"
seed_record "$signal_aborted_state" "$(jq -n -c --arg night "$NIGHT_ID" \
  '{ts:"x", night_id:$night, type:"run_start"}')"
seed_record "$signal_aborted_state" "$(jq -n -c --arg night "$NIGHT_ID" \
  '{ts:"x", night_id:$night, type:"run_end", aborted:true, signal:"TERM", lanes_run:1, findings_count:0, wallclock_sec:1}')"
run_digest "$signal_aborted_config"
assert_contains ABORTED "$signal_aborted_state/digests/$NIGHT_ID.md"

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

printf 'test_digest: PASS\n'
