#!/bin/bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
. "$TEST_DIR/helpers.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-run-visibility.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT
NIGHT_ID=$(date -v-8H '+%F')
STATE_DIR="$TEST_TMP/state"
CONFIG="$TEST_TMP/nightshift.conf"

printf '%s\n' \
  "NIGHTSHIFT_STATE_DIR='$STATE_DIR'" \
  "LANE_CMD_1='sleep 300 & printf \"%s\\n\" \"\$!\" > \"\$LANE_DIR/child.pid\"; wait'" \
  "LANE_TIMEBOX_MIN=1" \
  "BUDGET_PROBE_CMD='$ROOT/bin/budget-probe-stub'" \
  "LANE_HOME_LINKS=''" \
  > "$CONFIG"

NIGHTSHIFT_CONFIG="$CONFIG" \
  /bin/bash "$ROOT/bin/nightshift-dispatch" run >/dev/null &
dispatcher_pid=$!
child_pid_file="$STATE_DIR/lanes/$NIGHT_ID/lane_1/child.pid"
signal_wait=0
while [ ! -s "$child_pid_file" ] && [ "$signal_wait" -lt 200 ]; do
  kill -0 "$dispatcher_pid" 2>/dev/null ||
    fail "top-level dispatcher exited before its lane became observable"
  sleep 0.05
  signal_wait=$((signal_wait + 1))
done
assert_file_exists "$child_pid_file"
kill -TERM "$dispatcher_pid"
signal_rc=0
wait "$dispatcher_pid" || signal_rc=$?
[ "$signal_rc" -eq 143 ] ||
  fail "TERM-aborted run returned $signal_rc instead of 143"
ledger="$STATE_DIR/ledger/ledger.jsonl"
jq -e --arg night_id "$NIGHT_ID" '
  select(
    .night_id == $night_id and
    .type == "run_end" and
    .aborted == true and
    .signal == "TERM" and
    .lanes_run == 1
  )
' "$ledger" >/dev/null ||
  fail "TERM-aborted run did not append its closing run_end"
[ ! -d "$STATE_DIR/locks/nightshift.lock" ] ||
  fail "TERM-aborted run did not release its lock"
run_end_count=$(jq -r 'select(.type == "run_end") | .type' "$ledger" | wc -l | tr -d ' ')
[ "$run_end_count" -eq 1 ] ||
  fail "TERM-aborted run wrote $run_end_count run_end records instead of one"
child_pid=$(sed -n '1p' "$child_pid_file")
if kill -0 "$child_pid" 2>/dev/null; then
  fail "TERM-aborted run orphaned its active lane child"
fi

probe_state="$TEST_TMP/probe-state"
probe_config="$TEST_TMP/probe.conf"
probe_pid_file="$TEST_TMP/probe.pid"
printf '%s\n' \
  "NIGHTSHIFT_STATE_DIR='$probe_state'" \
  "LANE_CMD_1=':'" \
  "LANE_TIMEBOX_MIN=1" \
  "BUDGET_PROBE_CMD='printf \"%s\\n\" \"\$\$\" > \"$probe_pid_file\"; sleep 300'" \
  "LANE_HOME_LINKS=''" \
  > "$probe_config"
NIGHTSHIFT_CONFIG="$probe_config" \
  /bin/bash "$ROOT/bin/nightshift-dispatch" run >/dev/null &
probe_dispatcher_pid=$!
probe_wait=0
while [ ! -s "$probe_pid_file" ] && [ "$probe_wait" -lt 200 ]; do
  kill -0 "$probe_dispatcher_pid" 2>/dev/null ||
    fail "top-level dispatcher exited before its budget probe became observable"
  sleep 0.05
  probe_wait=$((probe_wait + 1))
done
assert_file_exists "$probe_pid_file"
kill -TERM "$probe_dispatcher_pid"
probe_rc=0
wait "$probe_dispatcher_pid" || probe_rc=$?
[ "$probe_rc" -eq 143 ] ||
  fail "TERM-aborted budget probe returned $probe_rc instead of 143"
probe_pid=$(sed -n '1p' "$probe_pid_file")
if kill -0 "$probe_pid" 2>/dev/null; then
  fail "TERM-aborted run orphaned its active budget probe"
fi
if find "$probe_state" -maxdepth 1 -name '.budget.*' -print |
  grep . >/dev/null 2>&1; then
  fail "TERM-aborted budget probe left its temporary directory behind"
fi
probe_ledger="$probe_state/ledger/ledger.jsonl"
probe_run_end_count=$(jq -r 'select(.type == "run_end") | .type' "$probe_ledger" |
  wc -l |
  tr -d ' ')
[ "$probe_run_end_count" -eq 1 ] ||
  fail "probe signal abort wrote $probe_run_end_count run_end records instead of one"

final_state="$TEST_TMP/final-state"
final_config="$TEST_TMP/final.conf"
final_marker="$TEST_TMP/finalizing"
printf '%s\n' \
  "NIGHTSHIFT_STATE_DIR='$final_state'" \
  "LANE_CMD_1='printf ready > \"$final_marker\"; sleep 0.2'" \
  "LANE_TIMEBOX_MIN=1" \
  "BUDGET_PROBE_CMD='$ROOT/bin/budget-probe-stub'" \
  "LANE_HOME_LINKS=''" \
  > "$final_config"
NIGHTSHIFT_CONFIG="$final_config" \
  /bin/bash "$ROOT/bin/nightshift-dispatch" run >/dev/null &
final_dispatcher_pid=$!
final_wait=0
while [ ! -f "$final_marker" ] && [ "$final_wait" -lt 200 ]; do
  kill -0 "$final_dispatcher_pid" 2>/dev/null ||
    fail "finalization dispatcher exited before the lane marker"
  sleep 0.01
  final_wait=$((final_wait + 1))
done
assert_file_exists "$final_marker"
sleep 0.15
kill -TERM "$final_dispatcher_pid" 2>/dev/null || true
wait "$final_dispatcher_pid" 2>/dev/null || true
final_ledger="$final_state/ledger/ledger.jsonl"
final_run_end_count=$(jq -r 'select(.type == "run_end") | .type' "$final_ledger" |
  wc -l |
  tr -d ' ')
[ "$final_run_end_count" -eq 1 ] ||
  fail "finalization signal race wrote $final_run_end_count run_end records instead of one"

printf 'test_run_visibility: PASS\n'
