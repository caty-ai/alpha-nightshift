#!/bin/bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
PYTHON_BIN=$(command -v python3)
. "$TEST_DIR/helpers.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-dispatch-failclosed.XXXXXX")
cleanup() {
  chmod u+w "$TEST_TMP/lanes-state/lanes" 2>/dev/null || true
  chmod u+w "$TEST_TMP/lock-state/locks" 2>/dev/null || true
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT
NIGHT_ID=$(date -v-8H '+%F')

write_config() {
  config_path=$1
  state_path=$2
  lane_one=$3
  lane_two=${4:-}
  lane_timebox=${5:-1}
  {
    printf '%s\n' "NIGHTSHIFT_STATE_DIR='$state_path'"
    printf 'LANE_CMD_1=%q\n' "$lane_one"
    if [ -n "$lane_two" ]; then
      printf 'LANE_CMD_2=%q\n' "$lane_two"
    fi
    printf '%s\n' "LANE_TIMEBOX_MIN=$lane_timebox"
    printf '%s\n' "BUDGET_PROBE_CMD='$ROOT/bin/budget-probe-stub'"
    printf '%s\n' "LANE_HOME_LINKS=''"
  } > "$config_path"
}

lanes_state="$TEST_TMP/lanes-state"
mkdir -p \
  "$lanes_state/logs" \
  "$lanes_state/locks" \
  "$lanes_state/ledger" \
  "$lanes_state/lanes" \
  "$lanes_state/digests"
chmod a-w "$lanes_state/lanes"
lanes_config="$TEST_TMP/lanes.conf"
write_config "$lanes_config" "$lanes_state" ':'
lanes_rc=0
NIGHTSHIFT_CONFIG="$lanes_config" \
  /bin/bash "$ROOT/bin/nightshift-dispatch" run >/dev/null || lanes_rc=$?
[ "$lanes_rc" -ne 0 ] || fail "run succeeded with an unwritable lanes directory"
lanes_ledger="$lanes_state/ledger/ledger.jsonl"
if jq -e 'select(.type == "lane_start")' "$lanes_ledger" >/dev/null; then
  fail "lane_start was recorded after lane directory creation failed"
fi
jq -e '
  select(
    .type == "run_end" and
    .aborted == true and
    .reason == "lane_directory_failed" and
    .lanes_run == 0
  )
' "$lanes_ledger" >/dev/null ||
  fail "unwritable lane directory did not produce a zero-lane abort"

setup_state="$TEST_TMP/setup-state"
setup_marker="$TEST_TMP/setup-lane-two-ran"
mkdir -p "$setup_state/lanes/$NIGHT_ID/lane_1/home/.gitconfig"
setup_config="$TEST_TMP/setup.conf"
write_config \
  "$setup_config" \
  "$setup_state" \
  ':' \
  "printf ran > \"$setup_marker\""
setup_rc=0
NIGHTSHIFT_CONFIG="$setup_config" \
  /bin/bash "$ROOT/bin/nightshift-dispatch" run >/dev/null || setup_rc=$?
[ "$setup_rc" -ne 0 ] || fail "run succeeded after lane environment setup failed"
[ ! -e "$setup_marker" ] || fail "lane 2 started after lane setup failure"
setup_ledger="$setup_state/ledger/ledger.jsonl"
jq -e '
  select(
    .type == "run_end" and
    .aborted == true and
    .reason == "lane_setup_failed"
  )
' "$setup_ledger" >/dev/null ||
  fail "lane setup failure did not produce an infrastructure abort"

lock_state="$TEST_TMP/lock-state"
mkdir -p \
  "$lock_state/logs" \
  "$lock_state/locks" \
  "$lock_state/ledger" \
  "$lock_state/lanes" \
  "$lock_state/digests"
chmod a-w "$lock_state/locks"
lock_config="$TEST_TMP/lock.conf"
write_config "$lock_config" "$lock_state" ':'
lock_rc=0
NIGHTSHIFT_CONFIG="$lock_config" \
  /bin/bash "$ROOT/bin/nightshift-dispatch" run >/dev/null || lock_rc=$?
[ "$lock_rc" -ne 0 ] || fail "run succeeded when its lock directory was unwritable"
lock_ledger="$lock_state/ledger/ledger.jsonl"
assert_ledger_record "$lock_ledger" "$NIGHT_ID" skip lock_error
if jq -e 'select(.type == "skip" and .reason == "lock_held")' "$lock_ledger" >/dev/null; then
  fail "lock error was misrecorded as lock_held"
fi
NIGHTSHIFT_CONFIG="$lock_config" \
  /bin/bash "$ROOT/bin/nightshift-dispatch" digest >/dev/null
lock_digest="$lock_state/digests/$NIGHT_ID.md"
assert_not_contains LOCK_HELD "$lock_digest"

setsid_state="$TEST_TMP/setsid-state"
setsid_config="$TEST_TMP/setsid.conf"
setsid_pid_file="$TEST_TMP/dispatch-setsid.pid"
setsid_lane_two="$TEST_TMP/setsid-lane-two-ran"
setsid_command="\"$PYTHON_BIN\" -c 'import os,time; time.sleep(0.2); os.setsid(); open(\"$setsid_pid_file\", \"w\").write(str(os.getpid())); time.sleep(300)' & wait"
write_config \
  "$setsid_config" \
  "$setsid_state" \
  "$setsid_command" \
  "printf ran > \"$setsid_lane_two\"" \
  0
setsid_rc=0
NIGHTSHIFT_CONFIG="$setsid_config" \
  /bin/bash "$ROOT/bin/nightshift-dispatch" run >/dev/null || setsid_rc=$?
assert_file_exists "$setsid_pid_file"
setsid_pid=$(sed -n '1p' "$setsid_pid_file")
if kill -0 "$setsid_pid" 2>/dev/null; then
  setsid_ledger="$setsid_state/ledger/ledger.jsonl"
  jq -e '
    select(
      .type == "lane_end" and
      .lane == "lane_1" and
      (.survivors | type == "array" and length > 0)
    )
  ' "$setsid_ledger" >/dev/null ||
    fail "setsid survivor was not recorded in lane_end"
  [ ! -e "$setsid_lane_two" ] ||
    fail "lane 2 started after a setsid survivor"
  [ "$setsid_rc" -ne 0 ] ||
    fail "setsid survivor did not fail the night"
  kill -KILL "$setsid_pid" 2>/dev/null || true
fi

printf 'test_dispatch_failclosed: PASS\n'
