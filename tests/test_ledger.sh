#!/bin/bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
. "$TEST_DIR/helpers.sh"
. "$ROOT/lib/common.sh"
. "$ROOT/lib/ledger.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-ledger.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT
STATE_DIR="$TEST_TMP/state"
NIGHT_ID=2026-07-28
mkdir -p "$STATE_DIR/ledger"

ledger_append '{
  "ts": "2026-07-29T00:00:00Z",
  "night_id": "2026-07-28",
  "type": "run_start"
}' || fail "valid JSON was rejected"

ledger=$(ledger_file_path)
assert_file_exists "$ledger"
[ "$(wc -l < "$ledger" | tr -d ' ')" -eq 1 ] || fail "record was not compacted to one line"
if ledger_append '{invalid'; then
  fail "invalid JSON was accepted"
fi
if ledger_append 'null'; then
  fail "JSON null was accepted as a ledger record"
fi
[ "$(wc -l < "$ledger" | tr -d ' ')" -eq 1 ] || fail "invalid JSON changed ledger"

ledger_append '{"ts":"x","night_id":"other","type":"run_start"}'
query_output=$(ledger_query_night 2026-07-28 run_start)
[ "$(printf '%s\n' "$query_output" | wc -l | tr -d ' ')" -eq 1 ] ||
  fail "night/type query returned the wrong number of records"

proposal="$TEST_TMP/findings.jsonl"
printf '%s\n' \
  '{"id":"f-1","repo":"demo","target":"screen","symptom":"button is hidden","kind":"UX","status":"rejected","confirm_cost":"1分","date":"2026-07-28"}' \
  '{malformed' \
  '{"id":"","repo":"demo","target":"screen","symptom":"bad schema","kind":"UX","confirm_cost":"1分","date":"2026-07-28"}' \
  > "$proposal"

ledger_ingest_proposals "$proposal"
[ "$LEDGER_INGESTED_COUNT" -eq 1 ] || fail "valid proposal was not ingested"
[ "$LEDGER_SKIPPED_COUNT" -eq 2 ] || fail "malformed proposals were not skipped"
[ "$LEDGER_DUPLICATE_COUNT" -eq 0 ] || fail "first proposal ingest reported duplicates"
finding=$(ledger_query_night 2026-07-28 finding)
[ "$(printf '%s\n' "$finding" | jq -r '.status')" = open ] ||
  fail "dispatcher did not force finding status to open"
[ "$(printf '%s\n' "$finding" | jq -r '.symptom')" = "button is hidden" ] ||
  fail "finding fields were not retained"

first_ingested=$LEDGER_INGESTED_COUNT
ledger_ingest_proposals "$proposal"
[ "$LEDGER_INGESTED_COUNT" -eq 0 ] || fail "duplicate proposal was ingested twice"
[ "$LEDGER_DUPLICATE_COUNT" -eq "$first_ingested" ] ||
  fail "duplicate proposal count did not match the first ingest"
[ "$LEDGER_SKIPPED_COUNT" -eq 2 ] ||
  fail "malformed proposal count changed during duplicate ingest"

printf 'test_ledger: PASS\n'
