#!/bin/bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
# shellcheck source=tests/helpers.sh
. "$TEST_DIR/helpers.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-metsuke.XXXXXX")
PLAYWRIGHT_MARKER="$ROOT/lanes/metsuke/node_modules/playwright"
CREATED_PLAYWRIGHT_MARKER=false
cleanup() {
  rm -rf "$TEST_TMP"
  if [ "$CREATED_PLAYWRIGHT_MARKER" = true ]; then
    rmdir "$PLAYWRIGHT_MARKER" 2>/dev/null || true
    rmdir "$ROOT/lanes/metsuke/node_modules" 2>/dev/null || true
  fi
}
trap cleanup EXIT

RUN_SH="$ROOT/lanes/metsuke/run.sh"
SERVE_SH="$ROOT/lanes/metsuke/serve-lp.sh"
CAPTURE_MJS="$ROOT/lanes/metsuke/capture.mjs"
BOUNDS_MJS="$ROOT/lanes/metsuke/capture-bounds.mjs"
REAL_JQ=$(command -v jq)
REAL_NODE=$(command -v node)

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
printf '%s\n' \
  '{"files":{"evidence/proof.txt":{"flow":"hero","step":"cta"}},"steps":[{"flow":"hero","step":"cta"}]}' \
  > "$manifest"
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

unsafe_lane="$TEST_TMP/unsafe-evidence-lane"
mkdir -p "$unsafe_lane/redirect"
ln -s "$unsafe_lane/redirect" "$unsafe_lane/evidence"
if LANE_DIR="$unsafe_lane" /bin/bash -c \
  '. "$1"; evidence_prepare_dir' _ "$ROOT/lib/evidence.sh" \
  >/dev/null 2>"$TEST_TMP/unsafe-evidence-error"; then
  fail "evidence_prepare_dir accepted a symlink evidence path"
fi
assert_contains "refusing unsafe symlink evidence directory" \
  "$TEST_TMP/unsafe-evidence-error"

preflight_module="$TEST_TMP/preflight/playwright"
preflight_cache="$TEST_TMP/preflight/ms-playwright"
mkdir -p "$preflight_cache"
if PLAYWRIGHT_BROWSERS_PATH_REAL="$preflight_cache" \
  /bin/bash "$RUN_SH" check-capture-preflight "$preflight_module" \
  >/dev/null 2>"$TEST_TMP/preflight-missing-module"; then
  fail "capture preflight accepted a missing Playwright dependency"
fi
assert_contains "Playwright dependency is missing" "$TEST_TMP/preflight-missing-module"
mkdir -p "$preflight_module"
if env -u PLAYWRIGHT_BROWSERS_PATH_REAL \
  /bin/bash "$RUN_SH" check-capture-preflight "$preflight_module" \
  >/dev/null 2>"$TEST_TMP/preflight-missing-cache"; then
  fail "capture preflight accepted a missing browser cache setting"
fi
assert_contains "PLAYWRIGHT_BROWSERS_PATH_REAL is required" "$TEST_TMP/preflight-missing-cache"
if PLAYWRIGHT_BROWSERS_PATH_REAL=relative/cache \
  /bin/bash "$RUN_SH" check-capture-preflight "$preflight_module" \
  >/dev/null 2>"$TEST_TMP/preflight-relative-cache"; then
  fail "capture preflight accepted a relative browser cache"
fi
assert_contains "must be an absolute path" "$TEST_TMP/preflight-relative-cache"
if PLAYWRIGHT_BROWSERS_PATH_REAL="$TEST_TMP/preflight/not-there" \
  /bin/bash "$RUN_SH" check-capture-preflight "$preflight_module" \
  >/dev/null 2>"$TEST_TMP/preflight-absent-cache"; then
  fail "capture preflight accepted a nonexistent browser cache"
fi
assert_contains "does not exist or is not a directory" "$TEST_TMP/preflight-absent-cache"
PLAYWRIGHT_BROWSERS_PATH_REAL="$preflight_cache" \
  /bin/bash "$RUN_SH" check-capture-preflight "$preflight_module" >/dev/null ||
  fail "capture preflight rejected valid dependency/cache markers"

"$REAL_NODE" --input-type=module - "$BOUNDS_MJS" <<'NODE'
const modulePath = process.argv[2];
const bounds = await import(`file://${modulePath}`);
const element = bounds.boundedText("x".repeat(700), bounds.ELEMENT_TEXT_MAX_CHARS);
if (element.text.length !== 500 || element.truncated !== true) process.exit(1);
const collector = bounds.createConsoleCollector();
for (let index = 0; index < 250; index += 1) {
  collector.add({
    flow: "hero",
    step: "cta",
    viewport: "mobile",
    text: "y".repeat(1_500),
    location: { url: "z".repeat(700), lineNumber: 2, columnNumber: 3 },
  });
}
const snapshot = collector.snapshot();
if (snapshot.entries.length !== 200) process.exit(1);
if (snapshot.mappings.length !== 200) process.exit(1);
if (snapshot.status.dropped !== 50) process.exit(1);
if (snapshot.status.mappingsDropped !== 50) process.exit(1);
if (snapshot.status.mappingsTruncated !== true) process.exit(1);
if (snapshot.status.textTruncations !== 200) process.exit(1);
if (snapshot.status.locationTruncations !== 200) process.exit(1);
if (!snapshot.entries.every((entry) => entry.text.length === 1_000)) process.exit(1);
if (!snapshot.entries.every((entry) => entry.location.url.length === 500)) process.exit(1);
NODE

assert_contains 'await context.route("**/*"' "$CAPTURE_MJS"
assert_contains 'context.on("page"' "$CAPTURE_MJS"
if grep -F 'page.route(' "$CAPTURE_MJS" >/dev/null; then
  fail "capture still uses page-scoped navigation interception"
fi
if grep -F 'stopAtOutbound' "$ROOT/lanes/metsuke/flows.json" >/dev/null; then
  fail "flows.json retained dead stopAtOutbound fields"
fi

fake_bin="$TEST_TMP/fake-bin"
mkdir -p "$fake_bin"
# The following single-quoted strings are literal test-double bodies.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'out=' \
  'while [ "$#" -gt 0 ]; do' \
  '  if [ "$1" = "--out" ]; then out=$2; shift 2; else shift; fi' \
  'done' \
  '[ -n "$out" ]' \
  'case "${FAKE_CAPTURE_MODE:-valid}" in' \
  '  fail) exit 7 ;;' \
  '  malformed)' \
  '    mkdir -p "$out"' \
  '    printf "%s\n" "{\"files\":[]}" > "$out/manifest.json"' \
  '    exit 0' \
  '    ;;' \
  'esac' \
  'mkdir -p "$out"' \
  'printf "%s\n" "visible proof" > "$out/proof.txt"' \
  'printf "%s\n" "other proof" > "$out/other.txt"' \
  ': > "$out/console-errors.jsonl"' \
  'printf "%s\n" "{\"files\":{\"evidence/proof.txt\":{\"flow\":\"hero\",\"step\":\"cta\",\"type\":\"visible-text\"},\"evidence/other.txt\":{\"flow\":\"other\",\"step\":\"step\",\"type\":\"visible-text\"},\"evidence/console-errors.jsonl\":{\"flow\":\"*\",\"step\":\"*\",\"type\":\"console-errors\",\"mappings\":[{\"flow\":\"hero\",\"step\":\"cta\",\"viewport\":\"mobile\"}]}},\"steps\":[{\"flow\":\"hero\",\"step\":\"cta\"},{\"flow\":\"other\",\"step\":\"step\"}]}" > "$out/manifest.json"' \
  > "$fake_bin/node"

# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'args=" $* "' \
  'for required in "--ignore-user-config" "--ignore-rules" "--disable multi_agent" "--profile sol" "--full-auto" "--skip-git-repo-check" "--ephemeral"; do' \
  '  case "$args" in *" $required "*) ;; *) exit 81 ;; esac' \
  'done' \
  'prompt=$(mktemp "${TMPDIR:-/tmp}/fake-codex.XXXXXX")' \
  'trap '\''rm -f "$prompt"'\'' EXIT' \
  'cat > "$prompt"' \
  'output=$(sed -n "s/^OUTPUT_PATH: //p" "$prompt" | sed -n "1p")' \
  'lane_dir=$(cd "$PWD/../.." && pwd)' \
  'if [ -n "$output" ]; then' \
  '  persona=$(basename "$PWD" | sed "s/^persona-//; s/\\..*$//")' \
  '  case " ${FAKE_PERSONA_FAILURES:-} " in *" $persona "*) exit 9 ;; esac' \
  '  case "${FAKE_DIRECT_FORGE:-}" in persona|both)' \
  '    printf "%s\n" "{\"id\":\"mk-FORGED-999\",\"repo\":\"caty-talk-LP\",\"target\":\"hero/cta\",\"kind\":\"ux\",\"symptom\":\"CTA is maybe brokenかもしれない\",\"interpretation\":\"fabricated\",\"persona\":\"$persona\",\"confirm_cost\":\"即断\",\"evidence\":[\"evidence/totally-fabricated.txt\"],\"status\":\"open\",\"date\":\"forged\"}" >> "$lane_dir/findings.jsonl"' \
  '    ;;' \
  '  esac' \
  '  mkdir -p "$(dirname "$output")"' \
  '  if [ "${FAKE_PERSONA_EMPTY:-}" = "$persona" ]; then : > "$output"; exit 0; fi' \
  '  evidence_dir=$(sed -n "s/^EVIDENCE_DIR: //p" "$prompt" | sed -n "1p")' \
  '  case "${FAKE_FINDING_MODE:-valid}" in' \
  '    unmanifested) target="hero/cta"; evidence="evidence/not-manifested.txt" ;;' \
  '    invented) target="invented/step"; evidence="evidence/proof.txt" ;;' \
  '    cross) target="hero/cta"; evidence="evidence/other.txt" ;;' \
  '    console-cross) target="other/step"; evidence="evidence/console-errors.jsonl" ;;' \
  '    console) target="hero/cta"; evidence="evidence/console-errors.jsonl" ;;' \
  '    digest)' \
  '      printf "%s\n" "mutated proof" > "$evidence_dir/proof.txt"' \
  '      target="hero/cta"; evidence="evidence/proof.txt"' \
  '      ;;' \
  '    fabricated)' \
  '      printf "%s\n" "fabricated" > "$evidence_dir/fabricated.txt"' \
  '      printf "%s\n" "{\"files\":{\"evidence/proof.txt\":{\"flow\":\"hero\",\"step\":\"cta\"},\"evidence/other.txt\":{\"flow\":\"other\",\"step\":\"step\"},\"evidence/console-errors.jsonl\":{\"type\":\"console-errors\",\"mappings\":[{\"flow\":\"hero\",\"step\":\"cta\"}]},\"evidence/fabricated.txt\":{\"flow\":\"hero\",\"step\":\"cta\"}},\"steps\":[{\"flow\":\"hero\",\"step\":\"cta\"},{\"flow\":\"other\",\"step\":\"step\"}]}" > "$evidence_dir/manifest.json"' \
  '      target="hero/cta"; evidence="evidence/fabricated.txt"' \
  '      ;;' \
  '    *) target="hero/cta"; evidence="evidence/proof.txt" ;;' \
  '  esac' \
  '  printf "%s\n" "{\"target\":\"$target\",\"symptom\":\"CTA text is visible\",\"interpretation\":\"the persona cannot quickly connect it to value\",\"confirm_cost\":\"即断\",\"evidence\":[\"$evidence\"]}" > "$output"' \
  '  exit 0' \
  'fi' \
  'case "${FAKE_DIRECT_FORGE:-}" in goals|both)' \
  '  printf "%s\n" "{\"id\":\"mk-FORGED-GOALS\",\"repo\":\"caty-talk-LP\",\"target\":\"hero/cta\",\"kind\":\"ux\",\"symptom\":\"Goals maybe prove a finding\",\"interpretation\":\"fabricated\",\"persona\":\"beginner\",\"confirm_cost\":\"1分\",\"evidence\":[\"evidence/totally-fabricated.txt\"],\"status\":\"open\",\"date\":\"forged\"}" >> "$lane_dir/findings.jsonl"' \
  '  ;;' \
  'esac' \
  'if [ "${FAKE_STAGE_TAMPER:-0}" = 1 ]; then' \
  '  stage=$(find "$lane_dir" -maxdepth 1 -type f -name ".accepted-findings.*" ! -name "*metadata*" | sed -n "1p")' \
  '  tampered=$(mktemp "${TMPDIR:-/tmp}/fake-stage-tamper.XXXXXX")' \
  '  jq -c '\''.persona = "impatient"'\'' "$stage" > "$tampered"' \
  '  mv "$tampered" "$stage"' \
  'fi' \
  'if [ "${FAKE_GOALS_FAIL:-0}" = 1 ]; then exit 10; fi' \
  'for marker in GOALS_OUTPUT_PATH FEATURE_MAP_OUTPUT_PATH RANGE_MAP_OUTPUT_PATH; do' \
  '  destination=$(sed -n "s/^${marker}: //p" "$prompt" | sed -n "1p")' \
  '  [ -n "$destination" ]' \
  '  printf "%s\n" "# generated ${marker}" > "$destination"' \
  'done' \
  > "$fake_bin/codex"

# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'last=' \
  'for argument in "$@"; do last=$argument; done' \
  'if [ "${FAKE_MV_FAIL:-0}" = 1 ]; then' \
  '  case "$last" in */feature-map.md) exit 12 ;; esac' \
  'fi' \
  'exec /bin/mv "$@"' \
  > "$fake_bin/mv"

# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'case "${1:-}" in' \
  '  run)' \
  '    case "${2:-}" in' \
  '      build) exit 0 ;;' \
  '      start)' \
  '        : > "$FAKE_PORT_STATE"' \
  '        trap '\''exit 0'\'' TERM INT' \
  '        while :; do read -r -t 1 _ || true; done' \
  '        ;;' \
  '    esac' \
  '    ;;' \
  'esac' \
  'exit 2' \
  > "$fake_bin/npm"

# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  '[ -n "${FAKE_PORT_STATE:-}" ] && [ -e "$FAKE_PORT_STATE" ]' \
  > "$fake_bin/lsof"

# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'if [ -n "${FAKE_PORT_STATE:-}" ] && [ -e "$FAKE_PORT_STATE" ]; then' \
  '  case " $* " in *" -w "*) printf 200 ;; esac' \
  '  exit 0' \
  'fi' \
  'exit 7' \
  > "$fake_bin/curl"

# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'case " $* " in' \
  '  *" -o stat= -p "*)' \
  '    target=${!#}' \
  '    if kill -0 "$target" 2>/dev/null; then printf "%s\n" S; exit 0; fi' \
  '    exit 1' \
  '    ;;' \
  '  *" -o pgid= -p "*) printf "%s\n" "$FAKE_EXPECTED_PGID" ;;' \
  '  *" -axo pid=,ppid= "*)' \
  '    root=$(sed -n "1p" "$LANE_DIR/metsuke-server.pid")' \
  '    if kill -0 "$root" 2>/dev/null; then printf "%s %s\n" "$root" 1; fi' \
  '    ;;' \
  '  *" -axo pid=,pgid= "*)' \
  '    root=$(sed -n "1p" "$LANE_DIR/metsuke-server.pid")' \
  '    if kill -0 "$root" 2>/dev/null; then printf "%s %s\n" "$root" "$FAKE_EXPECTED_PGID"; fi' \
  '    ;;' \
  '  *) exit 2 ;;' \
  'esac' \
  > "$fake_bin/ps"
chmod +x \
  "$fake_bin/node" \
  "$fake_bin/codex" \
  "$fake_bin/mv" \
  "$fake_bin/npm" \
  "$fake_bin/lsof" \
  "$fake_bin/curl" \
  "$fake_bin/ps"

if [ ! -d "$PLAYWRIGHT_MARKER" ]; then
  mkdir -p "$PLAYWRIGHT_MARKER"
  CREATED_PLAYWRIGHT_MARKER=true
fi
browser_cache="$TEST_TMP/browser-cache"
mkdir -p "$browser_cache"
stub_path="$fake_bin:$(dirname "$REAL_JQ"):/usr/bin:/bin"

CASE_LANE=
CASE_STATE=
CASE_RC=0
run_lane_case() {
  local case_name=$1
  local personas=${2:-"beginner expert impatient"}
  local persona_failures=${3:-}
  local finding_mode=${4:-valid}
  local capture_mode=${5:-valid}
  local goals_fail=${6:-0}
  local mv_fail=${7:-0}
  local empty_persona=${8:-}
  local direct_forge=${9:-}
  local stage_tamper=${10:-0}
  local night_id="2026-07-29-$case_name"
  CASE_STATE="$TEST_TMP/cases/$case_name/state"
  CASE_LANE="$CASE_STATE/lanes/$night_id/lane_1"
  mkdir -p "$CASE_LANE/home" "$CASE_LANE/tmp"
  set +e
  /usr/bin/env -i \
    PATH="$stub_path" \
    HOME="$CASE_LANE/home" \
    TMPDIR="$CASE_LANE/tmp" \
    LANG=C \
    TERM=dumb \
    NIGHT_ID="$night_id" \
    LANE_DIR="$CASE_LANE" \
    METSUKE_TARGET_URL='http://127.0.0.1:9999' \
    METSUKE_PERSONAS="$personas" \
    PLAYWRIGHT_BROWSERS_PATH_REAL="$browser_cache" \
    METSUKE_CODEX_BIN=codex \
    FAKE_PERSONA_FAILURES="$persona_failures" \
    FAKE_FINDING_MODE="$finding_mode" \
    FAKE_CAPTURE_MODE="$capture_mode" \
    FAKE_GOALS_FAIL="$goals_fail" \
    FAKE_MV_FAIL="$mv_fail" \
    FAKE_PERSONA_EMPTY="$empty_persona" \
    FAKE_DIRECT_FORGE="$direct_forge" \
    FAKE_STAGE_TAMPER="$stage_tamper" \
    /bin/bash "$RUN_SH" >"$CASE_LANE/stdout" 2>"$CASE_LANE/stderr"
  CASE_RC=$?
  set -e
}

run_lane_case success
[ "$CASE_RC" -eq 0 ] || fail "successful stubbed lane failed"
metrics="$CASE_LANE/metrics.json"
assert_file_exists "$metrics"
jq -e '
  (.t_serve | type == "number") and
  (.t_capture | type == "number") and
  (.t_analysis | type == "number") and
  (.t_goals | type == "number") and
  .capture_failed == false and
  .goals_failed == false and
  .personas_attempted == 3 and
  .personas_succeeded == 3 and
  .personas_failed == 0 and
  .stages.serve == {
    attempted:false,
    status:"skipped",
    cleanup_status:"skipped"
  } and
  .stages.capture == {attempted:true,status:"succeeded"} and
  .stages.analysis == {attempted:true,status:"succeeded"} and
  .stages.goals == {attempted:true,status:"succeeded"}
' "$metrics" >/dev/null ||
  fail "metrics did not record explicit successful stage/persona status"
[ "$(wc -l < "$CASE_LANE/findings.jsonl" | tr -d ' ')" -eq 3 ] ||
  fail "stubbed persona findings were not merged"
assert_file_exists "$CASE_STATE/goals/GOALS-draft.md"
assert_file_exists "$CASE_STATE/goals/feature-map.md"
assert_file_exists "$CASE_STATE/goals/range-map.md"
find "$CASE_LANE/codex-work" -maxdepth 1 -type d -name 'persona-*' |
  grep . >/dev/null || fail "persona Codex work directories were not isolated"
find "$CASE_LANE/codex-work" -maxdepth 1 -type d -name 'goals.*' |
  grep . >/dev/null || fail "goals Codex work directory was not isolated"

run_lane_case direct-dispatcher-forge "beginner" "" valid valid 0 0 "" both
[ "$CASE_RC" -eq 0 ] || fail "direct dispatcher forgery changed honest lane exit behavior"
[ "$(wc -l < "$CASE_LANE/findings.jsonl" | tr -d ' ')" -eq 1 ] ||
  fail "final findings publication did not retain exactly the normalized finding"
if grep -F 'FORGED' "$CASE_LANE/findings.jsonl" >/dev/null; then
  fail "direct Codex write survived final findings publication"
fi
jq -e '
  .invalid_findings == 0 and
  .personas_attempted == 1 and
  .personas_succeeded == 1 and
  .stages.analysis.status == "succeeded" and
  .stages.goals.status == "succeeded"
' "$CASE_LANE/metrics.json" >/dev/null ||
  fail "direct dispatcher forgery made metrics dishonest"

run_lane_case total-failure-direct-forge "beginner" beginner valid valid 0 0 "" both
[ "$CASE_RC" -ne 0 ] ||
  fail "total persona failure with direct forgery looked like a clean night"
[ ! -s "$CASE_LANE/findings.jsonl" ] ||
  fail "EXIT publication retained a forged finding on total persona failure"
jq -e '
  .personas_attempted == 1 and
  .personas_succeeded == 0 and
  .personas_failed == 1 and
  .stages.analysis.status == "failed" and
  .stages.goals.status == "succeeded"
' "$CASE_LANE/metrics.json" >/dev/null ||
  fail "total failure cleanup did not retain honest metrics"

run_lane_case staging-contract-tamper "beginner" "" valid valid 0 0 "" "" 1
[ "$CASE_RC" -ne 0 ] ||
  fail "tampered shell-assigned finding contract did not fail publication"
[ ! -s "$CASE_LANE/findings.jsonl" ] ||
  fail "tampered shell-assigned finding contract was published"
assert_contains "shell-normalized content was tampered" "$CASE_LANE/stderr"
jq -e '
  .invalid_findings == 1 and
  .personas_succeeded == 1 and
  .stages.analysis.status == "succeeded"
' "$CASE_LANE/metrics.json" >/dev/null ||
  fail "staging contract tamper was not recorded honestly"

run_lane_case one-persona-fails "beginner expert impatient" beginner
[ "$CASE_RC" -eq 0 ] || fail "one persona failure incorrectly failed the lane"
jq -e '
  .personas_attempted == 3 and
  .personas_succeeded == 2 and
  .personas_failed == 1 and
  .persona_failures == ["beginner"] and
  .stages.analysis.status == "degraded"
' "$CASE_LANE/metrics.json" >/dev/null ||
  fail "one persona failure was not recorded as degraded"
[ "$(wc -l < "$CASE_LANE/findings.jsonl" | tr -d ' ')" -eq 2 ] ||
  fail "remaining personas did not continue after one failure"

run_lane_case all-personas-fail "beginner expert impatient" "beginner expert impatient"
[ "$CASE_RC" -ne 0 ] || fail "all persona failure looked like a clean night"
jq -e '
  .personas_attempted == 3 and
  .personas_succeeded == 0 and
  .personas_failed == 3 and
  .stages.analysis.status == "failed" and
  .stages.goals.status == "succeeded"
' "$CASE_LANE/metrics.json" >/dev/null ||
  fail "all persona failure did not finish goals with honest status"

run_lane_case valid-empty "beginner" "" valid valid 0 0 beginner
[ "$CASE_RC" -eq 0 ] || fail "valid empty persona output was treated as failure"
jq -e '
  .personas_attempted == 1 and
  .personas_succeeded == 1 and
  .personas_failed == 0 and
  .stages.analysis.status == "succeeded"
' "$CASE_LANE/metrics.json" >/dev/null ||
  fail "valid empty persona output was not recorded as success"
[ ! -s "$CASE_LANE/findings.jsonl" ] ||
  fail "valid empty persona output unexpectedly created a finding"

run_lane_case goals-fail "beginner expert impatient" "" valid valid 1
[ "$CASE_RC" -eq 0 ] || fail "goals failure was incorrectly fatal after persona success"
jq -e '.goals_failed == true and .stages.goals.status == "failed"' \
  "$CASE_LANE/metrics.json" >/dev/null ||
  fail "goals failure was not recorded"
[ "$(wc -l < "$CASE_LANE/findings.jsonl" | tr -d ' ')" -eq 3 ] ||
  fail "goals failure discarded findings"

run_lane_case capture-fail "beginner" "" valid fail
[ "$CASE_RC" -ne 0 ] || fail "capture process failure did not fail closed"
jq -e '
  .capture_failed == true and
  .stages.capture.status == "failed" and
  .stages.analysis == {attempted:false,status:"not_attempted"} and
  .stages.goals == {attempted:false,status:"not_attempted"}
' "$CASE_LANE/metrics.json" >/dev/null ||
  fail "capture process failure metrics were dishonest"

run_lane_case malformed-manifest "beginner" "" valid malformed
[ "$CASE_RC" -ne 0 ] || fail "malformed capture manifest did not fail closed"
jq -e '.capture_failed == true and .stages.capture.status == "failed"' \
  "$CASE_LANE/metrics.json" >/dev/null ||
  fail "malformed manifest was not recorded as capture failure"

for negative_mode in unmanifested invented cross console-cross; do
  run_lane_case "negative-$negative_mode" "beginner" "" "$negative_mode"
  [ "$CASE_RC" -ne 0 ] ||
    fail "$negative_mode finding did not contribute to total analysis failure"
  jq -e '
    .invalid_findings == 1 and
    .personas_succeeded == 0 and
    .personas_failed == 1
  ' "$CASE_LANE/metrics.json" >/dev/null ||
    fail "$negative_mode finding was not rejected"
done

run_lane_case shared-console "beginner" "" console
[ "$CASE_RC" -eq 0 ] || fail "mapped shared console evidence was rejected"
[ "$(wc -l < "$CASE_LANE/findings.jsonl" | tr -d ' ')" -eq 1 ] ||
  fail "mapped shared console evidence was not retained"

for mutation_mode in digest fabricated; do
  run_lane_case "mutation-$mutation_mode" "beginner" "" "$mutation_mode"
  [ "$CASE_RC" -ne 0 ] || fail "$mutation_mode capture mutation did not fail closed"
  assert_contains "captured manifest/evidence changed" "$CASE_LANE/stderr"
done

partial_state="$TEST_TMP/cases/partial-goals-success/state"
mkdir -p "$partial_state/goals"
printf '%s\n' "# stale goals" > "$partial_state/goals/GOALS-draft.md"
printf '%s\n' "# stale feature map" > "$partial_state/goals/feature-map.md"
run_lane_case partial-goals-success "beginner"
[ "$CASE_RC" -eq 0 ] || fail "partial goals set regeneration failed"
partial_state="$CASE_STATE"
assert_contains "# generated GOALS_OUTPUT_PATH" "$partial_state/goals/GOALS-draft.md"
assert_contains "# generated FEATURE_MAP_OUTPUT_PATH" "$partial_state/goals/feature-map.md"
assert_file_exists "$partial_state/goals/feature-map.md"
assert_file_exists "$partial_state/goals/range-map.md"

failed_goals_state="$TEST_TMP/cases/partial-goals-codex-fail/state"
mkdir -p "$failed_goals_state/goals"
printf '%s\n' "# curated goals" > "$failed_goals_state/goals/GOALS-draft.md"
printf '%s\n' "# curated feature map" > "$failed_goals_state/goals/feature-map.md"
cp "$failed_goals_state/goals/GOALS-draft.md" "$TEST_TMP/goals-before-codex-fail"
cp "$failed_goals_state/goals/feature-map.md" "$TEST_TMP/feature-before-codex-fail"
run_lane_case partial-goals-codex-fail "beginner" "" valid valid 1
[ "$CASE_RC" -eq 0 ] || fail "goals Codex failure was incorrectly fatal"
cmp -s "$TEST_TMP/goals-before-codex-fail" "$CASE_STATE/goals/GOALS-draft.md" ||
  fail "goals Codex failure changed the existing GOALS draft"
cmp -s "$TEST_TMP/feature-before-codex-fail" "$CASE_STATE/goals/feature-map.md" ||
  fail "goals Codex failure changed the existing feature map"
[ ! -e "$CASE_STATE/goals/range-map.md" ] ||
  fail "goals Codex failure created a missing range map"

publication_state="$TEST_TMP/cases/publication-fail/state"
mkdir -p "$publication_state/goals"
printf '%s\n' "# curated publication goals" > "$publication_state/goals/GOALS-draft.md"
printf '%s\n' "# curated publication feature map" > "$publication_state/goals/feature-map.md"
cp "$publication_state/goals/GOALS-draft.md" "$TEST_TMP/goals-before-publication-fail"
cp "$publication_state/goals/feature-map.md" "$TEST_TMP/feature-before-publication-fail"
run_lane_case publication-fail "beginner" "" valid valid 0 1
[ "$CASE_RC" -eq 0 ] || fail "goals publication failure was incorrectly fatal"
jq -e '.goals_failed == true and .stages.goals.status == "failed"' \
  "$CASE_LANE/metrics.json" >/dev/null ||
  fail "goals publication failure was not recorded"
cmp -s "$TEST_TMP/goals-before-publication-fail" "$CASE_STATE/goals/GOALS-draft.md" ||
  fail "publication failure did not restore the previous GOALS draft"
cmp -s "$TEST_TMP/feature-before-publication-fail" "$CASE_STATE/goals/feature-map.md" ||
  fail "publication failure did not restore the previous feature map"
[ ! -e "$CASE_STATE/goals/range-map.md" ] ||
  fail "publication failure did not restore the previous missing range map"
[ "$(wc -l < "$CASE_LANE/findings.jsonl" | tr -d ' ')" -eq 1 ] ||
  fail "publication failure discarded findings"

unsafe_goals_state="$TEST_TMP/cases/unsafe-goals-symlink/state"
mkdir -p "$unsafe_goals_state/goals"
printf '%s\n' "# protected target" > "$unsafe_goals_state/protected-feature-map"
ln -s "$unsafe_goals_state/protected-feature-map" \
  "$unsafe_goals_state/goals/feature-map.md"
run_lane_case unsafe-goals-symlink "beginner"
[ "$CASE_RC" -eq 0 ] || fail "unsafe goals destination made persona findings fatal"
[ -L "$CASE_STATE/goals/feature-map.md" ] ||
  fail "unsafe goals destination symlink was replaced"
assert_contains "# protected target" "$unsafe_goals_state/protected-feature-map"
jq -e '.goals_failed == true and .stages.goals.status == "failed"' \
  "$CASE_LANE/metrics.json" >/dev/null ||
  fail "unsafe goals destination refusal was not recorded"

serve_failure_state="$TEST_TMP/cases/serve-failure/state"
serve_failure_night=2026-07-29-serve-failure
serve_failure_lane="$serve_failure_state/lanes/$serve_failure_night/lane_1"
mkdir -p "$serve_failure_lane/home" "$serve_failure_lane/tmp"
set +e
/usr/bin/env -i \
  PATH="$stub_path" HOME="$serve_failure_lane/home" TMPDIR="$serve_failure_lane/tmp" \
  LANG=C TERM=dumb NIGHT_ID="$serve_failure_night" LANE_DIR="$serve_failure_lane" \
  METSUKE_LP_CHECKOUT="$TEST_TMP/missing-checkout" \
  PLAYWRIGHT_BROWSERS_PATH_REAL="$browser_cache" METSUKE_CODEX_BIN=codex \
  /bin/bash "$RUN_SH" >"$serve_failure_lane/stdout" 2>"$serve_failure_lane/stderr"
serve_failure_rc=$?
set -e
[ "$serve_failure_rc" -ne 0 ] || fail "serve failure did not fail the lane"
jq -e '
  .stages.serve == {
    attempted:true,
    status:"failed",
    cleanup_status:"not_attempted"
  } and
  .stages.capture == {attempted:false,status:"not_attempted"} and
  .stages.analysis == {attempted:false,status:"not_attempted"} and
  .stages.goals == {attempted:false,status:"not_attempted"}
' "$serve_failure_lane/metrics.json" >/dev/null ||
  fail "early serve failure reported later stages as successful"

cleanup_failure_state="$TEST_TMP/cases/cleanup-failure/state"
cleanup_failure_night=2026-07-29-cleanup-failure
cleanup_failure_lane="$cleanup_failure_state/lanes/$cleanup_failure_night/lane_1"
cleanup_failure_checkout="$TEST_TMP/cleanup-failure-checkout"
cleanup_failure_port_state="$TEST_TMP/cleanup-failure-port"
mkdir -p \
  "$cleanup_failure_lane/home" \
  "$cleanup_failure_lane/tmp" \
  "$cleanup_failure_checkout/node_modules"
set +e
/usr/bin/env -i \
  PATH="$stub_path" HOME="$cleanup_failure_lane/home" TMPDIR="$cleanup_failure_lane/tmp" \
  LANG=C TERM=dumb NIGHT_ID="$cleanup_failure_night" LANE_DIR="$cleanup_failure_lane" \
  METSUKE_LP_CHECKOUT="$cleanup_failure_checkout" METSUKE_PORT=43125 \
  METSUKE_PERSONAS=beginner PLAYWRIGHT_BROWSERS_PATH_REAL="$browser_cache" \
  METSUKE_CODEX_BIN=codex FAKE_PORT_STATE="$cleanup_failure_port_state" \
  FAKE_EXPECTED_PGID=777 \
  /bin/bash "$RUN_SH" >"$cleanup_failure_lane/stdout" 2>"$cleanup_failure_lane/stderr"
cleanup_failure_rc=$?
set -e
[ "$cleanup_failure_rc" -ne 0 ] ||
  fail "server cleanup failure did not fail the lane"
jq -e '
  .stages.serve == {
    attempted:true,
    status:"succeeded",
    cleanup_status:"failed"
  } and
  .stages.capture.status == "succeeded" and
  .stages.analysis.status == "succeeded"
' "$cleanup_failure_lane/metrics.json" >/dev/null ||
  {
    jq . "$cleanup_failure_lane/metrics.json" >&2
    cat "$cleanup_failure_lane/stderr" >&2
    fail "server cleanup failure was absent from metrics"
  }
[ "$(wc -l < "$cleanup_failure_lane/findings.jsonl" | tr -d ' ')" -eq 1 ] ||
  fail "server cleanup failure prevented honest final findings publication"
rm -f "$cleanup_failure_port_state"

printf 'test_metsuke_offline: PASS\n'
