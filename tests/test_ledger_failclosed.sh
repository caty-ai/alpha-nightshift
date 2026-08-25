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

projection_state="$TEST_TMP/projection-state"
mkdir -p "$projection_state/ledger"
printf '%s\n' \
  '{"ts":"2026-07-29T00:00:00Z","night_id":"2026-07-28","type":"finding","id":"known","repo":"r","target":"t","symptom":"s","kind":"Bug","status":"open","confirm_cost":"1分","date":"2026-07-28"}' \
  '{"type":"verdict","verdict_id":"bad-history","ts":"2026-07-29T01:00:00Z","finding_id":"missing","status":"fixed","actor":"human","source":"manual-comment","source_ref":"c:bad","observed_at":"2026-07-29T01:00:00Z"}' \
  > "$projection_state/ledger/ledger.jsonl"
STATE_DIR="$projection_state"
. "$ROOT/lib/common.sh"
. "$ROOT/lib/ledger.sh"
if ledger_project_findings >/dev/null 2>&1; then
  fail "projection accepted a verdict for an unknown finding"
fi

assert_projection_history_rejected() {
  history_name=$1
  shift
  history_state="$TEST_TMP/history-$history_name"
  mkdir -p "$history_state/ledger"
  printf '%s\n' \
    '{"ts":"2026-07-29T00:00:00Z","night_id":"2026-07-28","type":"finding","id":"known","repo":"r","target":"t","symptom":"s","kind":"Bug","status":"open","confirm_cost":"1分","date":"2026-07-28"}' \
    > "$history_state/ledger/ledger.jsonl"
  for history_record in "$@"; do
    printf '%s\n' "$history_record" \
      >> "$history_state/ledger/ledger.jsonl"
  done
  STATE_DIR="$history_state"
  if ledger_project_findings >/dev/null 2>&1; then
    fail "projection accepted unsupported $history_name history"
  fi
}

assert_projection_history_rejected open-to-deferred \
  '{"type":"verdict","verdict_id":"v1","ts":"2026-07-29T01:00:00Z","finding_id":"known","status":"deferred","actor":"human","source":"manual-comment","source_ref":"c:1","observed_at":"2026-07-29T01:00:00Z"}'
assert_projection_history_rejected open-to-regression \
  '{"type":"verdict","verdict_id":"v1","ts":"2026-07-29T01:00:00Z","finding_id":"known","status":"regression","actor":"observer","source":"manual-comment","source_ref":"c:1","observed_at":"2026-07-29T01:00:00Z"}'
assert_projection_history_rejected adopted-to-deferred \
  '{"type":"verdict","verdict_id":"v1","ts":"2026-07-29T01:00:00Z","finding_id":"known","status":"adopted","actor":"human","source":"manual-comment","source_ref":"c:1","observed_at":"2026-07-29T01:00:00Z"}' \
  '{"type":"verdict","verdict_id":"v2","ts":"2026-07-29T02:00:00Z","finding_id":"known","status":"deferred","actor":"human","source":"manual-comment","source_ref":"c:2","observed_at":"2026-07-29T02:00:00Z"}'
assert_projection_history_rejected fixed-to-deferred \
  '{"type":"verdict","verdict_id":"v1","ts":"2026-07-29T01:00:00Z","finding_id":"known","status":"fixed","actor":"human","source":"manual-comment","source_ref":"c:1","observed_at":"2026-07-29T01:00:00Z"}' \
  '{"type":"verdict","verdict_id":"v2","ts":"2026-07-29T02:00:00Z","finding_id":"known","status":"deferred","actor":"human","source":"manual-comment","source_ref":"c:2","observed_at":"2026-07-29T02:00:00Z"}'
assert_projection_history_rejected rejected-to-regression \
  '{"type":"verdict","verdict_id":"v1","ts":"2026-07-29T01:00:00Z","finding_id":"known","status":"rejected","actor":"human","source":"manual-comment","source_ref":"c:1","observed_at":"2026-07-29T01:00:00Z","rejection_reason":"not accepted"}' \
  '{"type":"verdict","verdict_id":"v2","ts":"2026-07-29T02:00:00Z","finding_id":"known","status":"regression","actor":"observer","source":"manual-comment","source_ref":"c:2","observed_at":"2026-07-29T02:00:00Z"}'
assert_projection_history_rejected regression-to-fixed \
  '{"type":"verdict","verdict_id":"v1","ts":"2026-07-29T01:00:00Z","finding_id":"known","status":"fixed","actor":"human","source":"manual-comment","source_ref":"c:1","observed_at":"2026-07-29T01:00:00Z"}' \
  '{"type":"verdict","verdict_id":"v2","ts":"2026-07-29T02:00:00Z","finding_id":"known","status":"regression","actor":"observer","source":"manual-comment","source_ref":"c:2","observed_at":"2026-07-29T02:00:00Z"}' \
  '{"type":"verdict","verdict_id":"v3","ts":"2026-07-29T03:00:00Z","finding_id":"known","status":"fixed","actor":"human","source":"manual-comment","source_ref":"c:3","observed_at":"2026-07-29T03:00:00Z"}'

printf 'test_ledger_failclosed: PASS\n'
