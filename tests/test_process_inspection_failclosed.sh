#!/bin/bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
. "$TEST_DIR/helpers.sh"
# shellcheck source=../lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=../lib/lane-env.sh
. "$ROOT/lib/lane-env.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-inspection.XXXXXX")
cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT
NIGHT_ID=$(date -v-8H '+%F')

fake_bin="$TEST_TMP/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/pgrep" <<'EOF'
#!/bin/bash
if [ "${INSPECTION_FAIL_ALWAYS:-false}" = true ] ||
  { [ -n "${INSPECTION_FAIL_FILE:-}" ] && [ -f "$INSPECTION_FAIL_FILE" ]; }; then
  if [ -n "${INSPECTION_OBSERVED_FILE:-}" ]; then
    /usr/bin/touch "$INSPECTION_OBSERVED_FILE"
  fi
  exit 2
fi
exit 1
EOF
chmod +x "$fake_bin/pgrep"
cat > "$fake_bin/ps" <<'EOF'
#!/bin/bash
/bin/ps "$@"
ps_rc=$?
if [ "$ps_rc" -eq 0 ]; then
  exit 0
fi
# This test injects inspection failure through pgrep. Normalize unrelated
# sandbox/load-sensitive "not found" ps statuses to stock macOS's status 1.
exit 1
EOF
chmod +x "$fake_bin/ps"

write_config() {
  config_path=$1
  state_path=$2
  lane_one=$3
  lane_two=${4:-}
  lane_timebox=${5:-1}
  probe_command=${6:-"$ROOT/bin/budget-probe-stub"}
  probe_timeout=${7:-2}
  {
    printf '%s\n' "NIGHTSHIFT_STATE_DIR='$state_path'"
    printf 'LANE_CMD_1=%q\n' "$lane_one"
    if [ -n "$lane_two" ]; then
      printf 'LANE_CMD_2=%q\n' "$lane_two"
    fi
    printf '%s\n' "LANE_TIMEBOX_MIN=$lane_timebox"
    printf 'BUDGET_PROBE_CMD=%q\n' "$probe_command"
    printf '%s\n' "BUDGET_PROBE_TIMEOUT_SEC=$probe_timeout"
    printf '%s\n' "LANE_HOME_LINKS=''"
  } > "$config_path"
}

assert_no_lane_start() {
  ledger=$1
  if jq -e 'select(.type == "lane_start")' "$ledger" >/dev/null; then
    fail "lane started after process inspection failed"
  fi
}

probe_state="$TEST_TMP/probe-state"
probe_config="$TEST_TMP/probe.conf"
write_config "$probe_config" "$probe_state" ':'
probe_rc=0
PATH="$fake_bin:$PATH" INSPECTION_FAIL_ALWAYS=true \
  NIGHTSHIFT_CONFIG="$probe_config" \
  /bin/bash "$ROOT/bin/nightshift-dispatch" run >/dev/null || probe_rc=$?
[ "$probe_rc" -ne 0 ] || fail "non-timeout budget inspection failure returned success"
probe_ledger="$probe_state/ledger/ledger.jsonl"
assert_ledger_record "$probe_ledger" "$NIGHT_ID" meter_error process_inspection_unavailable
assert_no_lane_start "$probe_ledger"

timeout_probe="$TEST_TMP/timeout-probe"
printf '%s\n' '#!/bin/bash' 'sleep 300' > "$timeout_probe"
chmod +x "$timeout_probe"
timeout_probe_state="$TEST_TMP/timeout-probe-state"
timeout_probe_config="$TEST_TMP/timeout-probe.conf"
write_config "$timeout_probe_config" "$timeout_probe_state" ':' '' 1 "$timeout_probe" 1
timeout_probe_rc=0
PATH="$fake_bin:$PATH" INSPECTION_FAIL_ALWAYS=true \
  NIGHTSHIFT_CONFIG="$timeout_probe_config" \
  /bin/bash "$ROOT/bin/nightshift-dispatch" run >/dev/null || timeout_probe_rc=$?
[ "$timeout_probe_rc" -ne 0 ] || fail "timeout budget inspection failure returned success"
timeout_probe_ledger="$timeout_probe_state/ledger/ledger.jsonl"
assert_ledger_record \
  "$timeout_probe_ledger" \
  "$NIGHT_ID" \
  meter_error \
  process_inspection_unavailable
assert_no_lane_start "$timeout_probe_ledger"

lane_fail_file="$TEST_TMP/lane-inspection-fails"
lane_state="$TEST_TMP/lane-state"
lane_config="$TEST_TMP/lane.conf"
lane_two_marker="$TEST_TMP/lane-two-ran"
lane_observed_file="$TEST_TMP/lane-inspection-observed"
write_config \
  "$lane_config" \
  "$lane_state" \
  "/usr/bin/touch '$lane_fail_file'; while [ ! -e '$lane_observed_file' ]; do sleep 0.01; done" \
  "printf ran > '$lane_two_marker'"
lane_rc=0
PATH="$fake_bin:$PATH" \
  INSPECTION_FAIL_FILE="$lane_fail_file" \
  INSPECTION_OBSERVED_FILE="$lane_observed_file" \
  NIGHTSHIFT_CONFIG="$lane_config" \
  /bin/bash "$ROOT/bin/nightshift-dispatch" run >/dev/null || lane_rc=$?
[ "$lane_rc" -ne 0 ] || fail "non-timeout lane inspection failure returned success"
[ ! -e "$lane_two_marker" ] || fail "lane 2 started after inspection failure"
lane_ledger="$lane_state/ledger/ledger.jsonl"
jq -e '
  select(
    .type == "lane_end" and
    .process_inspection_failed == true and
    (.survivors | type == "array")
  )
' "$lane_ledger" >/dev/null ||
  {
    sed -n '1,80p' "$lane_ledger" >&2
    fail "lane inspection failure did not keep a typed survivors array and boolean"
  }

timeout_lane_dir="$TEST_TMP/timeout-lane"
LANE_TIMEBOX_MIN=0
LANE_HOME_LINKS=
LANG=${LANG:-C}
PATH="$fake_bin:$PATH" INSPECTION_FAIL_ALWAYS=true \
  lane_exec "$timeout_lane_dir" /bin/bash -c 'sleep 300' >/dev/null 2>&1
[ "$LANE_TIMED_OUT" = true ] ||
  fail "direct timeout lane did not reach the timeout path"
[ "$LANE_EXIT_CODE" -ne 0 ] ||
  fail "direct timeout lane inspection failure returned success"
[ "$LANE_PROCESS_INSPECTION_FAILED" = true ] ||
  fail "direct timeout lane did not preserve inspection failure"
printf '%s\n' "$LANE_SURVIVORS_JSON" |
  jq -e 'type == "array"' >/dev/null ||
  fail "direct timeout lane did not preserve a typed survivors array"

signal_fail_file="$TEST_TMP/signal-inspection-fails"
signal_pid_file="$TEST_TMP/signal-lane.pid"
signal_state="$TEST_TMP/signal-state"
signal_config="$TEST_TMP/signal.conf"
write_config \
  "$signal_config" \
  "$signal_state" \
  "/usr/bin/touch '$signal_fail_file'; printf ready > '$signal_pid_file'; sleep 300"
PATH="$fake_bin:$PATH" INSPECTION_FAIL_FILE="$signal_fail_file" \
  NIGHTSHIFT_CONFIG="$signal_config" \
  /bin/bash "$ROOT/bin/nightshift-dispatch" run >/dev/null &
signal_dispatcher_pid=$!
signal_wait=0
while [ ! -s "$signal_pid_file" ] && [ "$signal_wait" -lt 200 ]; do
  kill -0 "$signal_dispatcher_pid" 2>/dev/null ||
    fail "signal inspection dispatcher exited before lane observation"
  sleep 0.05
  signal_wait=$((signal_wait + 1))
done
assert_file_exists "$signal_pid_file"
kill -TERM "$signal_dispatcher_pid"
signal_rc=0
wait "$signal_dispatcher_pid" || signal_rc=$?
[ "$signal_rc" -eq 143 ] ||
  fail "signal cleanup inspection failure returned $signal_rc instead of 143"
signal_ledger="$signal_state/ledger/ledger.jsonl"
jq -e '
  select(
    .type == "run_end" and
    .aborted == true and
    .signal == "TERM" and
    .reason == "process_inspection_unavailable"
  )
' "$signal_ledger" >/dev/null ||
  fail "signal cleanup inspection failure was not loud in run_end"

printf 'test_process_inspection_failclosed: PASS\n'
