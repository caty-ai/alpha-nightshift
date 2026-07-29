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
  '{"id":"f-1","repo":"demo","target":"screen","symptom":"button is hidden","interpretation":"a beginner cannot discover the action","persona":"beginner","evidence":["evidence/01-hero-mobile.png","evidence/01-hero-mobile.txt"],"kind":"UX","status":"rejected","confirm_cost":"1分","date":"2026-07-28"}' \
  '{"id":"f-2","repo":"demo","target":"footer","symptom":"legal link is visible","kind":"UX","confirm_cost":"即断","date":"2026-07-28"}' \
  '{malformed' \
  '{"id":"","repo":"demo","target":"screen","symptom":"bad schema","kind":"UX","confirm_cost":"1分","date":"2026-07-28"}' \
  '{"id":"bad-interpretation","repo":"demo","target":"screen","symptom":"bad schema","interpretation":[],"kind":"UX","confirm_cost":"1分","date":"2026-07-28"}' \
  '{"id":"bad-persona","repo":"demo","target":"screen","symptom":"bad schema","persona":42,"kind":"UX","confirm_cost":"1分","date":"2026-07-28"}' \
  '{"id":"bad-evidence-type","repo":"demo","target":"screen","symptom":"bad schema","evidence":"shot.png","kind":"UX","confirm_cost":"1分","date":"2026-07-28"}' \
  '{"id":"bad-evidence-path","repo":"demo","target":"screen","symptom":"bad schema","evidence":["../shot.png"],"kind":"UX","confirm_cost":"1分","date":"2026-07-28"}' \
  > "$proposal"

ledger_ingest_proposals "$proposal"
[ "$LEDGER_INGESTED_COUNT" -eq 2 ] || fail "valid proposals were not ingested"
[ "$LEDGER_SKIPPED_COUNT" -eq 6 ] || fail "malformed proposals were not skipped"
[ "$LEDGER_DUPLICATE_COUNT" -eq 0 ] || fail "first proposal ingest reported duplicates"
finding=$(ledger_query_night 2026-07-28 finding | jq -c 'select(.id == "f-1")')
[ "$(printf '%s\n' "$finding" | jq -r '.status')" = open ] ||
  fail "dispatcher did not force finding status to open"
[ "$(printf '%s\n' "$finding" | jq -r '.symptom')" = "button is hidden" ] ||
  fail "finding fields were not retained"
[ "$(printf '%s\n' "$finding" | jq -r '.interpretation')" = \
  "a beginner cannot discover the action" ] ||
  fail "optional interpretation was not retained"
[ "$(printf '%s\n' "$finding" | jq -r '.persona')" = beginner ] ||
  fail "optional persona was not retained"
[ "$(printf '%s\n' "$finding" | jq -c '.evidence')" = \
  '["evidence/01-hero-mobile.png","evidence/01-hero-mobile.txt"]' ] ||
  fail "optional evidence was not retained"
without_optional=$(
  ledger_query_night 2026-07-28 finding |
    jq -c 'select(.id == "f-2")'
)
printf '%s\n' "$without_optional" |
  jq -e '
    has("interpretation") == false and
    has("persona") == false and
    has("evidence") == false
  ' >/dev/null ||
  fail "absent optional fields were not omitted"

first_ingested=$LEDGER_INGESTED_COUNT
ledger_ingest_proposals "$proposal"
[ "$LEDGER_INGESTED_COUNT" -eq 0 ] || fail "duplicate proposal was ingested twice"
[ "$LEDGER_DUPLICATE_COUNT" -eq "$first_ingested" ] ||
  fail "duplicate proposal count did not match the first ingest"
[ "$LEDGER_SKIPPED_COUNT" -eq 6 ] ||
  fail "malformed proposal count changed during duplicate ingest"

ledger_append '{
  "type": "verdict",
  "verdict_id": "projection-v1",
  "ts": "2026-07-29T03:00:00Z",
  "finding_id": "f-1",
  "status": "adopted",
  "actor": "human",
  "source": "manual-comment",
  "source_ref": "comment:projection",
  "observed_at": "2026-07-29T02:00:00Z"
}'
projected=$(ledger_project_findings)
[ "$(printf '%s\n' "$projected" |
  jq -r 'select(.id == "f-1") | .current_status')" = adopted ] ||
  fail "current-state projection did not apply the verdict"
[ "$(printf '%s\n' "$projected" |
  jq -r 'select(.id == "f-1") | .status')" = adopted ] ||
  fail "projected status was not the effective current status"
[ "$(printf '%s\n' "$projected" |
  jq -r 'select(.id == "f-1") | .base_status')" = open ] ||
  fail "current-state projection did not retain the base status"
[ "$(printf '%s\n' "$projected" |
  jq -c 'select(.id == "f-1") | .evidence')" = \
  '["evidence/01-hero-mobile.png","evidence/01-hero-mobile.txt"]' ] ||
  fail "current-state projection dropped finding evidence"
[ "$(printf '%s\n' "$projected" |
  jq -r 'select(.id == "f-1") | .latest_verdict.source_ref')" = \
  comment:projection ] ||
  fail "current-state projection omitted latest verdict metadata"
[ "$(printf '%s\n' "$projected" | jq -r '.id')" = \
  "$(printf '%s\n' "$projected" | jq -r '.id' | sort)" ] ||
  fail "current findings were not returned deterministically"

ledger_append '{
  "type": "verdict",
  "verdict_id": "projection-fixed",
  "ts": "2026-07-29T03:01:00Z",
  "finding_id": "f-2",
  "status": "fixed",
  "actor": "human",
  "source": "manual-comment",
  "source_ref": "comment:fixed",
  "observed_at": "2026-07-29T02:01:00Z"
}'
ledger_append '{
  "type": "verdict",
  "verdict_id": "projection-regression",
  "ts": "2026-07-29T03:02:00Z",
  "finding_id": "f-2",
  "status": "regression",
  "actor": "observer",
  "source": "manual-comment",
  "source_ref": "observation:regression",
  "observed_at": "2026-07-29T02:02:00Z"
}'
[ "$(ledger_get_current_finding f-2 | jq -r '.current_status')" = regression ] ||
  fail "projection rejected the documented fixed-to-regression edge"

printf 'test_ledger: PASS\n'
