#!/bin/bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
. "$TEST_DIR/helpers.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-budget.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT
NIGHT_ID=$(date -v-8H '+%F')

write_config() {
  config_path=$1
  state_path=$2
  probe_command=$3
  budget_cap=$4
  printf '%s\n' \
    "NIGHTSHIFT_STATE_DIR='$state_path'" \
    "LANE_CMD_1='printf \"%s\\n\" ran > \"\$LANE_DIR/ran\"'" \
    "LANE_TIMEBOX_MIN=1" \
    "NIGHT_BUDGET_TOKENS=$budget_cap" \
    "BUDGET_PROBE_CMD='$probe_command'" \
    "BUDGET_PROBE_TIMEOUT_SEC=2" \
    "LANE_HOME_LINKS=''" \
    > "$config_path"
}

run_dispatch() {
  config_path=$1
  NIGHTSHIFT_CONFIG="$config_path" /bin/bash "$ROOT/bin/nightshift-dispatch" run >/dev/null
}

missing_state="$TEST_TMP/missing-state"
missing_config="$TEST_TMP/missing.conf"
write_config "$missing_config" "$missing_state" "$TEST_TMP/does-not-exist" 100
run_dispatch "$missing_config"
missing_ledger="$missing_state/ledger/ledger.jsonl"
assert_ledger_record "$missing_ledger" "$NIGHT_ID" meter_error
assert_ledger_record "$missing_ledger" "$NIGHT_ID" skip meter_error
if jq -e 'select(.type == "lane_start")' "$missing_ledger" >/dev/null; then
  fail "lane started after missing budget probe"
fi

garbage_probe="$TEST_TMP/garbage-probe"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "not-json"' > "$garbage_probe"
chmod +x "$garbage_probe"
garbage_state="$TEST_TMP/garbage-state"
garbage_config="$TEST_TMP/garbage.conf"
write_config "$garbage_config" "$garbage_state" "$garbage_probe" 100
run_dispatch "$garbage_config"
garbage_ledger="$garbage_state/ledger/ledger.jsonl"
assert_ledger_record "$garbage_ledger" "$NIGHT_ID" meter_error
assert_ledger_record "$garbage_ledger" "$NIGHT_ID" skip meter_error
if jq -e 'select(.type == "lane_start")' "$garbage_ledger" >/dev/null; then
  fail "lane started after invalid budget probe output"
fi

timeout_probe="$TEST_TMP/timeout-probe"
printf '%s\n' '#!/bin/bash' 'trap "" TERM' 'while :; do sleep 1; done' > "$timeout_probe"
chmod +x "$timeout_probe"
timeout_state="$TEST_TMP/timeout-state"
timeout_config="$TEST_TMP/timeout.conf"
write_config "$timeout_config" "$timeout_state" "$timeout_probe" 100
run_dispatch "$timeout_config"
timeout_ledger="$timeout_state/ledger/ledger.jsonl"
jq -e --arg night_id "$NIGHT_ID" \
  'select(.night_id == $night_id and .type == "meter_error" and .reason == "probe_timeout")' \
  "$timeout_ledger" >/dev/null || fail "timed-out probe did not record meter_error"
assert_ledger_record "$timeout_ledger" "$NIGHT_ID" skip meter_error
if jq -e 'select(.type == "lane_start")' "$timeout_ledger" >/dev/null; then
  fail "lane started after budget probe timeout"
fi

over_probe="$TEST_TMP/over-probe"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "{\"tokens_spent\":10}"' > "$over_probe"
chmod +x "$over_probe"
over_state="$TEST_TMP/over-state"
over_config="$TEST_TMP/over.conf"
write_config "$over_config" "$over_state" "$over_probe" 10
run_dispatch "$over_config"
over_ledger="$over_state/ledger/ledger.jsonl"
assert_ledger_record "$over_ledger" "$NIGHT_ID" skip budget_exhausted
if jq -e 'select(.type == "lane_start")' "$over_ledger" >/dev/null; then
  fail "lane started after budget exhaustion"
fi

healthy_probe="$TEST_TMP/healthy-probe"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "{\"tokens_spent\":3}"' > "$healthy_probe"
chmod +x "$healthy_probe"
healthy_state="$TEST_TMP/healthy-state"
healthy_config="$TEST_TMP/healthy.conf"
write_config "$healthy_config" "$healthy_state" "$healthy_probe" 10
run_dispatch "$healthy_config"
healthy_ledger="$healthy_state/ledger/ledger.jsonl"
assert_ledger_record "$healthy_ledger" "$NIGHT_ID" lane_start
[ -f "$healthy_state/lanes/$NIGHT_ID/lane_1/ran" ] ||
  fail "healthy budget probe did not allow lane execution"
jq -e 'select(.type == "run_end" and .lanes_run == 1)' "$healthy_ledger" >/dev/null ||
  fail "healthy run did not record one lane"
assert_file_exists "$healthy_state/logs/run-$NIGHT_ID.log"
status_output="$TEST_TMP/status.txt"
NIGHTSHIFT_CONFIG="$healthy_config" /bin/bash "$ROOT/bin/nightshift-dispatch" status > "$status_output"
assert_contains 'lock: free' "$status_output"
assert_contains '"type":"run_end"' "$status_output"
assert_file_exists "$healthy_state/logs/status-$NIGHT_ID.log"

printf 'test_budget_failclosed: PASS\n'
