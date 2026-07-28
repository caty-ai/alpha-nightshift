#!/bin/bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
. "$TEST_DIR/helpers.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-ledger-fail.XXXXXX")
cleanup() {
  chmod u+w "$TEST_TMP/run-state/ledger" 2>/dev/null || true
  chmod u+w "$TEST_TMP/later-state/ledger" 2>/dev/null || true
  chmod u+w "$TEST_TMP/later-state/ledger/ledger.jsonl" 2>/dev/null || true
  chmod u+w "$TEST_TMP/digest-state/ledger" 2>/dev/null || true
  chmod u+w "$TEST_TMP/digest-state/ledger/ledger.jsonl" 2>/dev/null || true
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT
NIGHT_ID=$(date -v-8H '+%F')

marker="$TEST_TMP/probe-ran"
probe="$TEST_TMP/marker-probe"
printf '%s\n' \
  '#!/bin/bash' \
  "printf '%s\\n' ran > '$marker'" \
  'printf "%s\n" "{\"tokens_spent\":0}"' \
  > "$probe"
chmod +x "$probe"

run_state="$TEST_TMP/run-state"
mkdir -p \
  "$run_state/logs" \
  "$run_state/locks" \
  "$run_state/ledger" \
  "$run_state/lanes" \
  "$run_state/digests"
chmod a-w "$run_state/ledger"
run_config="$TEST_TMP/run.conf"
printf '%s\n' \
  "NIGHTSHIFT_STATE_DIR='$run_state'" \
  "LANE_CMD_1=':'" \
  "BUDGET_PROBE_CMD='$probe'" \
  "LANE_HOME_LINKS=''" \
  > "$run_config"

run_rc=0
NIGHTSHIFT_CONFIG="$run_config" \
  /bin/bash "$ROOT/bin/nightshift-dispatch" run >/dev/null || run_rc=$?
[ "$run_rc" -ne 0 ] || fail "run succeeded with an unwritable ledger directory"
[ ! -e "$marker" ] || fail "budget probe ran after run_start ledger append failed"
[ ! -e "$run_state/ledger/ledger.jsonl" ] ||
  fail "unwritable ledger unexpectedly contains records"
[ ! -d "$run_state/locks/nightshift.lock" ] ||
  fail "run lock was not released after ledger append failure"

later_state="$TEST_TMP/later-state"
later_lane_one="$TEST_TMP/later-lane-one-ran"
later_lane_two="$TEST_TMP/later-lane-two-ran"
later_config="$TEST_TMP/later.conf"
printf '%s\n' \
  "NIGHTSHIFT_STATE_DIR='$later_state'" \
  "LANE_CMD_1='printf ran > \"$later_lane_one\"; chmod a-w \"$later_state/ledger/ledger.jsonl\"'" \
  "LANE_CMD_2='printf ran > \"$later_lane_two\"'" \
  "BUDGET_PROBE_CMD='$ROOT/bin/budget-probe-stub'" \
  "LANE_HOME_LINKS=''" \
  > "$later_config"
later_rc=0
NIGHTSHIFT_CONFIG="$later_config" \
  /bin/bash "$ROOT/bin/nightshift-dispatch" run >/dev/null || later_rc=$?
[ "$later_rc" -ne 0 ] || fail "run succeeded after a later ledger append failure"
assert_file_exists "$later_lane_one"
[ ! -e "$later_lane_two" ] ||
  fail "a new lane started after a later ledger append failure"
[ ! -d "$later_state/locks/nightshift.lock" ] ||
  fail "run lock was not released after a later ledger append failure"

digest_state="$TEST_TMP/digest-state"
mkdir -p \
  "$digest_state/logs" \
  "$digest_state/locks" \
  "$digest_state/ledger" \
  "$digest_state/lanes" \
  "$digest_state/digests"
printf '%s\n' \
  "$(jq -n -c --arg night "$NIGHT_ID" '{ts:"x", night_id:$night, type:"run_start"}')" \
  "$(jq -n -c --arg night "$NIGHT_ID" '{ts:"x", night_id:$night, type:"run_end", lanes_run:0, findings_count:0}')" \
  > "$digest_state/ledger/ledger.jsonl"
chmod a-w "$digest_state/ledger/ledger.jsonl"
chmod a-w "$digest_state/ledger"
digest_config="$TEST_TMP/digest.conf"
printf '%s\n' \
  "NIGHTSHIFT_STATE_DIR='$digest_state'" \
  "LANE_CMD_1=':'" \
  "LANE_HOME_LINKS=''" \
  > "$digest_config"

digest_rc=0
NIGHTSHIFT_CONFIG="$digest_config" \
  /bin/bash "$ROOT/bin/nightshift-dispatch" digest >/dev/null || digest_rc=$?
[ "$digest_rc" -ne 0 ] || fail "digest succeeded when digest_written append failed"
assert_file_exists "$digest_state/digests/$NIGHT_ID.md"

printf 'test_ledger_failclosed: PASS\n'
