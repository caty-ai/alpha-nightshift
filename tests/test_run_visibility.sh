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
  "LANE_CMD_1='kill -TERM \"\$PPID\"; exit 0'" \
  "LANE_TIMEBOX_MIN=1" \
  "BUDGET_PROBE_CMD='$ROOT/bin/budget-probe-stub'" \
  "LANE_HOME_LINKS=''" \
  > "$CONFIG"

signal_rc=0
NIGHTSHIFT_CONFIG="$CONFIG" \
  /bin/bash "$ROOT/bin/nightshift-dispatch" run >/dev/null || signal_rc=$?
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

printf 'test_run_visibility: PASS\n'
