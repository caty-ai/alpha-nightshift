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

assert_closed_skip() {
  closed_ledger=$1
  closed_label=$2
  if jq -e 'select(.type == "lane_start")' "$closed_ledger" >/dev/null; then
    fail "lane started after $closed_label"
  fi
  jq -e 'select(.type == "run_end" and .lanes_run == 0)' "$closed_ledger" >/dev/null ||
    fail "$closed_label did not write a zero-lane run_end"
}

missing_state="$TEST_TMP/missing-state"
missing_config="$TEST_TMP/missing.conf"
write_config "$missing_config" "$missing_state" "$TEST_TMP/does-not-exist" 100
run_dispatch "$missing_config"
missing_ledger="$missing_state/ledger/ledger.jsonl"
assert_ledger_record "$missing_ledger" "$NIGHT_ID" meter_error
assert_ledger_record "$missing_ledger" "$NIGHT_ID" skip meter_error
assert_closed_skip "$missing_ledger" "missing budget probe"

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
assert_closed_skip "$garbage_ledger" "invalid budget probe output"

timeout_probe="$TEST_TMP/timeout-probe"
printf '%s\n' '#!/bin/bash' 'while :; do sleep 1; done' > "$timeout_probe"
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
assert_closed_skip "$timeout_ledger" "budget probe timeout"

over_probe="$TEST_TMP/over-probe"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "{\"tokens_spent\":10}"' > "$over_probe"
chmod +x "$over_probe"
over_state="$TEST_TMP/over-state"
over_config="$TEST_TMP/over.conf"
write_config "$over_config" "$over_state" "$over_probe" 10
run_dispatch "$over_config"
over_ledger="$over_state/ledger/ledger.jsonl"
assert_ledger_record "$over_ledger" "$NIGHT_ID" skip budget_exhausted
assert_closed_skip "$over_ledger" "budget exhaustion"

float_over_probe="$TEST_TMP/float-over-probe"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "{\"tokens_spent\":900000.0}"' > "$float_over_probe"
chmod +x "$float_over_probe"
float_over_state="$TEST_TMP/float-over-state"
float_over_config="$TEST_TMP/float-over.conf"
write_config "$float_over_config" "$float_over_state" "$float_over_probe" 100
run_dispatch "$float_over_config"
float_over_ledger="$float_over_state/ledger/ledger.jsonl"
assert_ledger_record "$float_over_ledger" "$NIGHT_ID" skip budget_exhausted
assert_closed_skip "$float_over_ledger" "integral float budget exhaustion"
jq -e 'select(.type == "run_end" and .budget.tokens_spent == 900000)' \
  "$float_over_ledger" >/dev/null ||
  fail "integral float was not normalized to an integer"
(
  . "$ROOT/lib/common.sh"
  . "$ROOT/lib/ledger.sh"
  . "$ROOT/lib/budget.sh"
  STATE_DIR="$TEST_TMP/direct-float-state"
  NIGHT_BUDGET_TOKENS=100
  BUDGET_PROBE_CMD="$float_over_probe"
  BUDGET_PROBE_TIMEOUT_SEC=2
  mkdir -p "$STATE_DIR/ledger"
  direct_float_rc=0
  budget_check || direct_float_rc=$?
  [ "$direct_float_rc" -eq 2 ] ||
    fail "integral float over cap returned $direct_float_rc instead of 2"
)

fraction_probe="$TEST_TMP/fraction-probe"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "{\"tokens_spent\":12.5}"' > "$fraction_probe"
chmod +x "$fraction_probe"
fraction_state="$TEST_TMP/fraction-state"
fraction_config="$TEST_TMP/fraction.conf"
write_config "$fraction_config" "$fraction_state" "$fraction_probe" 100
run_dispatch "$fraction_config"
fraction_ledger="$fraction_state/ledger/ledger.jsonl"
assert_ledger_record "$fraction_ledger" "$NIGHT_ID" meter_error
assert_ledger_record "$fraction_ledger" "$NIGHT_ID" skip meter_error
assert_closed_skip "$fraction_ledger" "non-integral float probe"

negative_probe="$TEST_TMP/negative-probe"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "{\"tokens_spent\":-1}"' > "$negative_probe"
chmod +x "$negative_probe"
negative_state="$TEST_TMP/negative-state"
negative_config="$TEST_TMP/negative.conf"
write_config "$negative_config" "$negative_state" "$negative_probe" 100
run_dispatch "$negative_config"
negative_ledger="$negative_state/ledger/ledger.jsonl"
assert_ledger_record "$negative_ledger" "$NIGHT_ID" meter_error
assert_ledger_record "$negative_ledger" "$NIGHT_ID" skip meter_error
assert_closed_skip "$negative_ledger" "negative budget probe"

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

forking_probe="$TEST_TMP/forking-probe"
forking_child_pid="$TEST_TMP/forking-probe-child.pid"
printf '%s\n' \
  '#!/bin/bash' \
  "/bin/bash -c 'trap \"\" TERM; while :; do sleep 1; done' &" \
  "printf '%s\\n' \"\$!\" > '$forking_child_pid'" \
  'trap "" TERM' \
  'while :; do sleep 1; done' \
  > "$forking_probe"
chmod +x "$forking_probe"
forking_state="$TEST_TMP/forking-state"
forking_config="$TEST_TMP/forking.conf"
write_config "$forking_config" "$forking_state" "$forking_probe" 100
sed -i '' 's/BUDGET_PROBE_TIMEOUT_SEC=2/BUDGET_PROBE_TIMEOUT_SEC=1/' "$forking_config"
run_dispatch "$forking_config"
assert_file_exists "$forking_child_pid"
orphan_pid=$(sed -n '1p' "$forking_child_pid")
orphan_wait=0
while kill -0 "$orphan_pid" 2>/dev/null && [ "$orphan_wait" -lt 20 ]; do
  sleep 0.1
  orphan_wait=$((orphan_wait + 1))
done
if kill -0 "$orphan_pid" 2>/dev/null; then
  fail "budget probe child process survived process-group timeout"
fi
forking_ledger="$forking_state/ledger/ledger.jsonl"
assert_ledger_record "$forking_ledger" "$NIGHT_ID" meter_error
assert_closed_skip "$forking_ledger" "forking budget probe timeout"

printf 'test_budget_failclosed: PASS\n'
