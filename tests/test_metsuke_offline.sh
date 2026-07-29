#!/bin/bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
# shellcheck source=tests/helpers.sh
. "$TEST_DIR/helpers.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-metsuke.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT
RUN_SH="$ROOT/lanes/metsuke/run.sh"
SERVE_SH="$ROOT/lanes/metsuke/serve-lp.sh"

valid_candidate='{"target":"hero/cta","symptom":"CTA text is visible at x=20","interpretation":"a beginner may not connect it to the product value","confirm_cost":"即断","evidence":["evidence/proof.txt"]}'
printf '%s\n' "$valid_candidate" |
  /bin/bash "$RUN_SH" validate-finding >/dev/null ||
  fail "valid finding candidate was rejected"

if printf '%s\n' '{"target":"hero/cta","symptom":"missing fields"}' |
  /bin/bash "$RUN_SH" validate-finding >/dev/null 2>&1; then
  fail "malformed finding candidate was accepted"
fi
if printf '%s\n' '{"target":"hero/cta","symptom":"CTA is hiddenかもしれない","interpretation":"beginner impact","confirm_cost":"1分","evidence":["evidence/proof.txt"]}' |
  /bin/bash "$RUN_SH" validate-finding >/dev/null 2>&1; then
  fail "hedged observation was accepted"
fi

lane_for_render="$TEST_TMP/render-lane"
mkdir -p "$lane_for_render"
manifest="$TEST_TMP/manifest.json"
printf '%s\n' '{"files":{"evidence/proof.txt":{"flow":"hero","step":"cta"}}}' > "$manifest"
persona_render="$TEST_TMP/persona-render.md"
LANE_DIR="$lane_for_render" /bin/bash "$RUN_SH" render-persona \
  "$ROOT/lanes/metsuke/personas/beginner.md" \
  "$manifest" \
  "$lane_for_render/evidence" \
  "$lane_for_render/proposals/beginner.jsonl" > "$persona_render"
if grep -E '\{\{[^}]+\}\}' "$persona_render" >/dev/null; then
  fail "persona template retained an unsubstituted placeholder"
fi
assert_contains "$lane_for_render/evidence" "$persona_render"
assert_contains '"evidence/proof.txt"' "$persona_render"

goals_render="$TEST_TMP/goals-render.md"
LANE_DIR="$lane_for_render" /bin/bash "$RUN_SH" render-goals \
  "$manifest" \
  "$lane_for_render/evidence" \
  "$TEST_TMP/goals/GOALS-draft.md" \
  "$TEST_TMP/goals/feature-map.md" \
  "$TEST_TMP/goals/range-map.md" > "$goals_render"
if grep -E '\{\{[^}]+\}\}' "$goals_render" >/dev/null; then
  fail "goals template retained an unsubstituted placeholder"
fi
assert_contains "$TEST_TMP/goals/range-map.md" "$goals_render"

missing_lane="$TEST_TMP/missing-lane"
mkdir -p "$missing_lane"
if LANE_DIR="$missing_lane" METSUKE_LP_CHECKOUT="$TEST_TMP/not-there" \
  /bin/bash "$SERVE_SH" start >/dev/null 2>"$TEST_TMP/serve-error"; then
  fail "serve-lp accepted a missing checkout"
fi
assert_contains "LP checkout does not exist" "$TEST_TMP/serve-error"

fake_bin="$TEST_TMP/fake-bin"
mkdir -p "$fake_bin"
REAL_JQ=$(command -v jq)
# The following single-quoted strings are the literal bodies of test doubles.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'out=' \
  'while [ "$#" -gt 0 ]; do' \
  '  if [ "$1" = "--out" ]; then out=$2; shift 2; else shift; fi' \
  'done' \
  '[ -n "$out" ]' \
  'mkdir -p "$out"' \
  'printf "%s\n" "visible proof" > "$out/proof.txt"' \
  'printf "%s\n" "{\"files\":{\"evidence/proof.txt\":{\"flow\":\"hero\",\"step\":\"cta\"}}}" > "$out/manifest.json"' \
  > "$fake_bin/node"
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'prompt=$(mktemp "${TMPDIR:-/tmp}/fake-codex.XXXXXX")' \
  'trap '\''rm -f "$prompt"'\'' EXIT' \
  'cat > "$prompt"' \
  'output=$(sed -n "s/^OUTPUT_PATH: //p" "$prompt" | sed -n "1p")' \
  'if [ -n "$output" ]; then' \
  '  mkdir -p "$(dirname "$output")"' \
  '  printf "%s\n" "{\"target\":\"hero/cta\",\"symptom\":\"CTA text is visible\",\"interpretation\":\"the persona cannot quickly connect it to value\",\"confirm_cost\":\"即断\",\"evidence\":[\"evidence/proof.txt\"]}" > "$output"' \
  '  exit 0' \
  'fi' \
  'for marker in GOALS_OUTPUT_PATH FEATURE_MAP_OUTPUT_PATH RANGE_MAP_OUTPUT_PATH; do' \
  '  destination=$(sed -n "s/^${marker}: //p" "$prompt" | sed -n "1p")' \
  '  [ -n "$destination" ]' \
  '  mkdir -p "$(dirname "$destination")"' \
  '  printf "%s\n" "# stub ${marker}" > "$destination"' \
  'done' \
  > "$fake_bin/codex"
printf '%s\n' \
  '#!/bin/bash' \
  'exit 0' \
  > "$fake_bin/curl"
chmod +x "$fake_bin/node" "$fake_bin/codex" "$fake_bin/curl"

night_id=2026-07-29
state_dir="$TEST_TMP/state"
lane_dir="$state_dir/lanes/$night_id/lane_1"
fake_home="$lane_dir/home"
fake_tmp="$lane_dir/tmp"
mkdir -p "$lane_dir" "$fake_home" "$fake_tmp"
stub_path="$fake_bin:$(dirname "$REAL_JQ"):/usr/bin:/bin"
/usr/bin/env -i \
  PATH="$stub_path" \
  HOME="$fake_home" \
  TMPDIR="$fake_tmp" \
  LANG=C \
  TERM=dumb \
  NIGHT_ID="$night_id" \
  LANE_DIR="$lane_dir" \
  METSUKE_TARGET_URL='http://127.0.0.1:9999' \
  METSUKE_CODEX_BIN=codex \
  /bin/bash "$RUN_SH"

metrics="$lane_dir/metrics.json"
assert_file_exists "$metrics"
jq -e '
  (.t_serve | type == "number") and
  (.t_capture | type == "number") and
  (.t_analysis | type == "number") and
  (.t_goals | type == "number") and
  .capture_failed == false and
  .goals_failed == false and
  .persona_failures == []
' "$metrics" >/dev/null ||
  fail "metrics did not record all successful stubbed phases"
[ "$(wc -l < "$lane_dir/findings.jsonl" | tr -d ' ')" -eq 3 ] ||
  fail "stubbed persona findings were not merged"
assert_file_exists "$state_dir/goals/GOALS-draft.md"
assert_file_exists "$state_dir/goals/feature-map.md"
assert_file_exists "$state_dir/goals/range-map.md"

printf 'test_metsuke_offline: PASS\n'
