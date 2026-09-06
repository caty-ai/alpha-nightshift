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
  if [ "${METSUKE_TEST_KEEP_TMP:-0}" = 1 ]; then
    printf 'METSUKE_TEST_KEEP_TMP=1: %s\n' "$TEST_TMP" >&2
  else
    rm -rf "$TEST_TMP"
  fi
  if [ "$CREATED_PLAYWRIGHT_MARKER" = true ]; then
    rmdir "$PLAYWRIGHT_MARKER" 2>/dev/null || true
    rmdir "$ROOT/lanes/metsuke/node_modules" 2>/dev/null || true
  fi
}
# Set METSUKE_TEST_KEEP_TMP=1 to retain test evidence and print its path on exit.
trap cleanup EXIT

dump_lane_and_fail() {
  local lane_dir=$1
  local message=$2
  local log_file
  # Diagnostics are best-effort even when this function is the RHS of ||.
  {
    for log_file in stderr stdout; do
      printf 'lane %s:\n' "$log_file"
      [ -f "$lane_dir/$log_file" ] && cat "$lane_dir/$log_file" ||
        printf '%s\n' '(missing)'
    done
    printf 'findings.jsonl line count: '
    [ -f "$lane_dir/findings.jsonl" ] && wc -l < "$lane_dir/findings.jsonl" ||
      printf '%s\n' '(missing)'
    printf '%s\n' 'lane metrics.json:'
    [ -f "$lane_dir/metrics.json" ] && cat "$lane_dir/metrics.json" ||
      printf '%s\n' '(missing)'
  } >&2 || true
  fail "$message"
}

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
  'for required in "--ignore-user-config" "--ignore-rules" "--disable multi_agent" "--profile sol" "--sandbox workspace-write" "--skip-git-repo-check" "--ephemeral"; do' \
  '  case "$args" in *" $required "*) ;; *) exit 81 ;; esac' \
  'done' \
  'if [ -n "${FAKE_CODEX_ARGV_FILE:-}" ] && [ ! -e "$FAKE_CODEX_ARGV_FILE" ]; then' \
  '  printf "%s\n" "$@" > "$FAKE_CODEX_ARGV_FILE"' \
  '  pwd > "$FAKE_CODEX_CWD_FILE"' \
  'fi' \
  'prompt=$(mktemp "${TMPDIR:-/tmp}/fake-codex.XXXXXX")' \
  'trap '\''rm -f "$prompt"'\'' EXIT' \
  'cat > "$prompt"' \
  'if [ -n "${FAKE_CODEX_STDIN_FILE:-}" ] && [ ! -e "$FAKE_CODEX_STDIN_FILE" ]; then' \
  '  cp "$prompt" "$FAKE_CODEX_STDIN_FILE"' \
  'fi' \
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
  '  stage=$(find "$lane_dir" -maxdepth 1 -type f -name ".accepted-findings.*" | sed -n "1p")' \
  '  tampered=$(mktemp "${TMPDIR:-/tmp}/fake-stage-tamper.XXXXXX")' \
  '  jq -c '\''.persona = "impatient"'\'' "$stage" > "$tampered"' \
  '  mv "$tampered" "$stage"' \
  'fi' \
  'if [ "${FAKE_CONSISTENT_FORGE:-0}" = 1 ]; then' \
  '  stage=$(find "$lane_dir" -maxdepth 1 -type f -name ".accepted-findings.*" | sed -n "1p")' \
  '  metadata=$(find "$lane_dir" -maxdepth 1 -type f -name ".accepted-findings-metadata.*" | sed -n "1p")' \
  '  [ -z "$metadata" ] && : > "$FAKE_NO_METADATA_MARKER"' \
  '  forged=$(jq -n -c --arg id "mk-${NIGHT_ID}-002" '\''{id:$id,repo:"caty-talk-LP",target:"hero/cta",kind:"ux",symptom:"Fabricated CTA observation",interpretation:"forged interpretation",persona:"beginner",confirm_cost:"即断",evidence:["evidence/proof.txt"],status:"open",date:env.NIGHT_ID}'\'')' \
  '  digest=$(printf "%s\n" "$forged" | shasum -a 256 | awk '\''{print $1}'\'')' \
  '  printf "%s\n" "$forged" >> "$stage"' \
  '  if [ -n "$metadata" ]; then' \
  '    jq -n -c --arg digest "$digest" '\''{sequence:2,persona:"beginner",digest:$digest}'\'' >> "$metadata"' \
  '  fi' \
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
  '[ "$#" -eq 6 ]' \
  '[ "$1" = -p ]' \
  '[ "$3" = -m ] && [ "$4" = kimi-code/k3 ]' \
  '[ "$5" = --output-format ] && [ "$6" = text ]' \
  'prompt=$2' \
  'mode=$(basename "$0" | sed "s/^kimi-//")' \
  'case "$mode" in stdout-only|file-priority) ;; *) mode=write-output ;; esac' \
  'output=$(printf "%s\n" "$prompt" | sed -n "s/^OUTPUT_PATH: //p" | sed -n "1p")' \
  'if [ -n "$output" ]; then' \
  '  evidence=$(printf "%s\n" "$prompt" | sed -n "s/^EVIDENCE_DIR: //p" | sed -n "1p")' \
  '  [ -n "$evidence" ]' \
  '  printf "%s\n" "$HOME" > "$(dirname "$output")/seen-home.txt"' \
  '  case "$mode" in' \
  '    stdout-only)' \
  '      printf "%s\n" "{\"target\":\"hero/cta\",\"symptom\":\"CTA text is visible from stdout only\",\"interpretation\":\"the persona cannot quickly connect it to value\",\"confirm_cost\":\"即断\",\"evidence\":[\"evidence/proof.txt\"]}"' \
  '      ;;' \
  '    file-priority)' \
  '      printf "%s\n" "{\"target\":\"hero/cta\",\"symptom\":\"CTA text is visible from OUTPUT_PATH\",\"interpretation\":\"the persona cannot quickly connect it to value\",\"confirm_cost\":\"即断\",\"evidence\":[\"evidence/proof.txt\"]}" > "$output"' \
  '      printf "%s\n" "{\"target\":\"hero/cta\",\"symptom\":\"CTA text is visible from stdout alternative\",\"interpretation\":\"the persona cannot quickly connect it to value\",\"confirm_cost\":\"即断\",\"evidence\":[\"evidence/proof.txt\"]}"' \
  '      ;;' \
  '    *)' \
  '      printf "%s\n" "{\"target\":\"hero/cta\",\"symptom\":\"CTA text is visible\",\"interpretation\":\"the persona cannot quickly connect it to value\",\"confirm_cost\":\"即断\",\"evidence\":[\"evidence/proof.txt\"]}" > "$output"' \
  '      ;;' \
  '  esac' \
  'else' \
  '  for marker in GOALS_OUTPUT_PATH FEATURE_MAP_OUTPUT_PATH RANGE_MAP_OUTPUT_PATH; do' \
  '    destination=$(printf "%s\n" "$prompt" | sed -n "s/^${marker}: //p" | sed -n "1p")' \
  '    [ -n "$destination" ]' \
  '    printf "%s\n" "# generated ${marker}" > "$destination"' \
  '  done' \
  'fi' \
  > "$fake_bin/kimi"

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
  'if [ "${FAKE_RMDIR_FAIL:-0}" = 1 ]; then exit 13; fi' \
  'exec /bin/rmdir "$@"' \
  > "$fake_bin/rmdir"

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
  'if [ -n "${FAKE_PORT_STATE:-}" ] && [ -e "$FAKE_PORT_STATE" ]; then' \
  '  if [ -n "${FAKE_CLEANUP_BLOCK_FILE:-}" ] && [ -s "$LANE_DIR/metsuke-server.pid" ]; then' \
  '    : > "$FAKE_CLEANUP_STARTED_FILE"' \
  '    while [ -e "$FAKE_CLEANUP_BLOCK_FILE" ]; do sleep 0.02; done' \
  '  fi' \
  '  exit 0' \
  'fi' \
  'exit 1' \
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
  '  *" -o lstart= -p "*) printf "%s\n" "Mon Jan  1 00:00:00 2024" ;;' \
  '  *" -o stat= -p "*)' \
  '    target=${!#}' \
  '    if kill -0 "$target" 2>/dev/null; then printf "%s\n" S; exit 0; fi' \
  '    exit 1' \
  '    ;;' \
  '  *" -o pgid= -p "*) printf "%s\n" "$FAKE_EXPECTED_PGID" ;;' \
  '  *" -axo pid=,ppid= "*)' \
  '    printf "%s %s\n" "$PPID" 1' \
  '    if [ -n "${FAKE_BASELINE_ANCHOR_PID:-}" ]; then printf "%s %s\n" "$FAKE_BASELINE_ANCHOR_PID" 1; fi' \
  '    if [ -s "$LANE_DIR/metsuke-server.pid" ]; then' \
  '      root=$(sed -n "1p" "$LANE_DIR/metsuke-server.pid")' \
  '      if kill -0 "$root" 2>/dev/null; then printf "%s %s\n" "$root" 1; fi' \
  '    fi' \
  '    ;;' \
  '  *" -axo pid=,pgid= "*)' \
  '    printf "%s %s\n" "$PPID" "$FAKE_EXPECTED_PGID"' \
  '    if [ -n "${FAKE_BASELINE_ANCHOR_PID:-}" ]; then printf "%s %s\n" "$FAKE_BASELINE_ANCHOR_PID" "$FAKE_EXPECTED_PGID"; fi' \
  '    if [ -s "$LANE_DIR/metsuke-server.pid" ]; then' \
  '      root=$(sed -n "1p" "$LANE_DIR/metsuke-server.pid")' \
  '      if kill -0 "$root" 2>/dev/null; then printf "%s %s\n" "$root" "$FAKE_EXPECTED_PGID"; fi' \
  '    fi' \
  '    ;;' \
  '  *) exit 2 ;;' \
  'esac' \
  > "$fake_bin/ps"
chmod +x \
  "$fake_bin/node" \
  "$fake_bin/codex" \
  "$fake_bin/kimi" \
  "$fake_bin/mv" \
  "$fake_bin/npm" \
  "$fake_bin/lsof" \
  "$fake_bin/curl" \
  "$fake_bin/ps" \
  "$fake_bin/rmdir"
ln -s kimi "$fake_bin/kimi-stdout-only"
ln -s kimi "$fake_bin/kimi-file-priority"

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
  local consistent_forge=${11:-0}
  local rmdir_fail=${12:-0}
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
    FAKE_CONSISTENT_FORGE="$consistent_forge" \
    FAKE_NO_METADATA_MARKER="$CASE_LANE/no-metadata-file" \
    FAKE_RMDIR_FAIL="$rmdir_fail" \
    FAKE_BASELINE_ANCHOR_PID="$$" \
    FAKE_CODEX_ARGV_FILE="$CASE_LANE/codex-argv.txt" \
    FAKE_CODEX_CWD_FILE="$CASE_LANE/codex-cwd.txt" \
    FAKE_CODEX_STDIN_FILE="$CASE_LANE/codex-stdin.txt" \
    /bin/bash "$RUN_SH" >"$CASE_LANE/stdout" 2>"$CASE_LANE/stderr"
  CASE_RC=$?
  set -e
}

run_lane_case success
[ "$CASE_RC" -eq 0 ] || fail "successful stubbed lane failed"
printf '%s\n' \
  exec \
  --ignore-user-config \
  --ignore-rules \
  --disable \
  multi_agent \
  --profile \
  sol \
  --sandbox \
  workspace-write \
  --skip-git-repo-check \
  --ephemeral \
  - \
  > "$TEST_TMP/expected-codex-argv.txt"
cmp -s "$TEST_TMP/expected-codex-argv.txt" "$CASE_LANE/codex-argv.txt" ||
  fail "default seat Codex argv changed"
! grep -qx -- '--full-auto' "$CASE_LANE/codex-argv.txt" ||
  fail "default seat Codex argv contains removed --full-auto flag"
[ "$(grep -A1 -x -- '--sandbox' "$CASE_LANE/codex-argv.txt" | sed -n '2p')" = workspace-write ] ||
  fail "default seat Codex sandbox must be workspace-write"
codex_first_cwd=$(sed -n '1p' "$CASE_LANE/codex-cwd.txt")
codex_persona_dir=$(find "$CASE_LANE/codex-work" -maxdepth 1 -type d \
  -name 'persona-beginner.*' | sed -n '1p')
[ -n "$codex_persona_dir" ] && [ "$codex_first_cwd" -ef "$codex_persona_dir" ] ||
  fail "default seat Codex cwd changed: $codex_first_cwd"
cmp -s "$codex_first_cwd/prompt.md" "$CASE_LANE/codex-stdin.txt" ||
  fail "default seat Codex stdin changed"
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
  dump_lane_and_fail "$CASE_LANE" "metrics did not record explicit successful stage/persona status"
[ "$(wc -l < "$CASE_LANE/findings.jsonl" | tr -d ' ')" -eq 3 ] ||
  fail "stubbed persona findings were not merged"
jq -e -s 'all(.[]; .persona | test("^(beginner|expert|impatient)@seat:codex$"))' \
  "$CASE_LANE/findings.jsonl" >/dev/null ||
  fail "default seat marker was not recorded"
assert_file_exists "$CASE_STATE/goals/GOALS-draft.md"
assert_file_exists "$CASE_STATE/goals/feature-map.md"
assert_file_exists "$CASE_STATE/goals/range-map.md"
find "$CASE_LANE/codex-work" -maxdepth 1 -type d -name 'persona-*' |
  grep . >/dev/null || fail "persona Codex work directories were not isolated"
find "$CASE_LANE/codex-work" -maxdepth 1 -type d -name 'goals.*' |
  grep . >/dev/null || fail "goals Codex work directory was not isolated"

kimi_state="$TEST_TMP/cases/kimi-seat/state"
kimi_night=2026-07-29-kimi-seat
kimi_lane="$kimi_state/lanes/$kimi_night/lane_1"
kimi_auth="$TEST_TMP/kimi-auth"
mkdir -p "$kimi_lane/home" "$kimi_lane/tmp" "$kimi_auth"
ln -s "$kimi_auth" "$kimi_lane/home/.kimi-code"
run_kimi_lane() {
  local mode=$1
  set +e
  /usr/bin/env -i \
    PATH="$stub_path" HOME="$kimi_lane/home" TMPDIR="$kimi_lane/tmp" \
    LANG=C TERM=dumb NIGHT_ID="$kimi_night" LANE_DIR="$kimi_lane" \
    METSUKE_TARGET_URL='http://127.0.0.1:9999' METSUKE_PERSONAS=beginner \
    METSUKE_SEAT=kimi REVIEW_KIMI_BIN="$fake_bin/kimi-$mode" \
    PLAYWRIGHT_BROWSERS_PATH_REAL="$browser_cache" \
    /bin/bash "$RUN_SH" >"$kimi_lane/stdout" 2>"$kimi_lane/stderr"
  kimi_rc=$?
  set -e
  return "$kimi_rc"
}

run_kimi_lane stdout-only
[ "$kimi_rc" -eq 0 ] || {
  cat "$kimi_lane/stderr" >&2
  fail "Kimi adapter seat did not complete the persona flow"
}
jq -e '
  .persona == "beginner@seat:kimi" and
  .target == "hero/cta" and
  .symptom == "CTA text is visible from stdout only"
' \
  "$kimi_lane/findings.jsonl" >/dev/null ||
  fail "Kimi stdout-only fallback did not retain persona and seat metadata"
kimi_persona_dir=$(find "$kimi_lane/codex-work" -maxdepth 1 -type d \
  -name 'persona-beginner.*' | sed -n '1p')
[ -n "$kimi_persona_dir" ] || fail "Kimi persona work directory is missing"
[ "$(sed -n '1p' "$kimi_persona_dir/seen-home.txt")" = \
  "$kimi_lane/metsuke-homes/kimi" ] ||
  fail "Kimi adapter did not receive its isolated HOME"
[ -L "$kimi_lane/metsuke-homes/kimi/.kimi-code" ] ||
  fail "Kimi isolated HOME did not expose the opted-in auth link"
(
  # shellcheck source=lib/common.sh
  . "$ROOT/lib/common.sh"
  # shellcheck source=lib/ledger.sh
  . "$ROOT/lib/ledger.sh"
  STATE_DIR="$TEST_TMP/kimi-ledger-state"
  NIGHT_ID="$kimi_night"
  mkdir -p "$STATE_DIR/ledger"
  ledger_ingest_proposals "$kimi_lane/findings.jsonl"
  [ "$LEDGER_INGESTED_COUNT" -eq 1 ]
  ledger_validate_jsonl_shape
) || fail "Kimi seat marker failed ledger ingestion"
run_kimi_lane file-priority
[ "$kimi_rc" -eq 0 ] || {
  cat "$kimi_lane/stderr" >&2
  fail "same-lane Kimi rerun did not complete"
}
jq -e '
  .persona == "beginner@seat:kimi" and
  .symptom == "CTA text is visible from OUTPUT_PATH"
' "$kimi_lane/findings.jsonl" >/dev/null ||
  fail "Kimi OUTPUT_PATH finding did not win over stdout fallback"
if grep -F 'stdout alternative' "$kimi_lane/findings.jsonl" >/dev/null; then
  fail "Kimi stdout fallback overrode a nonempty OUTPUT_PATH"
fi
[ "$(find "$kimi_lane/codex-work" -maxdepth 1 -type d \
  -name 'persona-beginner.*' | wc -l | tr -d ' ')" -ge 2 ] ||
  fail "same-lane Kimi rerun did not create a fresh persona work directory"
[ -L "$kimi_lane/metsuke-homes/kimi/.kimi-code" ] ||
  fail "same-lane Kimi rerun did not recreate the isolated auth link"

for rejected_seat in glm unknown-seat; do
  rejected_lane="$TEST_TMP/rejected-$rejected_seat"
  mkdir -p "$rejected_lane/home" "$rejected_lane/tmp"
  if /usr/bin/env -i \
    PATH="$stub_path" HOME="$rejected_lane/home" TMPDIR="$rejected_lane/tmp" \
    LANG=C TERM=dumb NIGHT_ID="2026-07-29-$rejected_seat" \
    LANE_DIR="$rejected_lane" METSUKE_SEAT="$rejected_seat" \
    /bin/bash "$RUN_SH" >"$rejected_lane/stdout" 2>"$rejected_lane/stderr"; then
    fail "METSUKE_SEAT=$rejected_seat did not fail closed"
  fi
  [ ! -e "$rejected_lane/evidence" ] ||
    fail "METSUKE_SEAT=$rejected_seat reached capture setup"
done
assert_contains "METSUKE_SEAT=glm is unsupported" \
  "$TEST_TMP/rejected-glm/stderr"
assert_contains "unknown METSUKE_SEAT 'unknown-seat'" \
  "$TEST_TMP/rejected-unknown-seat/stderr"

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
  dump_lane_and_fail "$CASE_LANE" "direct dispatcher forgery made metrics dishonest"

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
  dump_lane_and_fail "$CASE_LANE" "total failure cleanup did not retain honest metrics"

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
  dump_lane_and_fail "$CASE_LANE" "staging contract tamper was not recorded honestly"

run_lane_case consistent-staging-forge "beginner" "" valid valid 0 0 "" "" 0 1
[ "$CASE_RC" -ne 0 ] ||
  fail "consistent staging/metadata forgery did not fail publication"
[ -e "$CASE_LANE/no-metadata-file" ] ||
  fail "fake Codex found writable file-backed finding contract metadata"
if find "$CASE_LANE" -maxdepth 1 -type f \
  -name '.accepted-findings-metadata.*' | grep . >/dev/null; then
  fail "file-backed finding contract metadata still exists"
fi
if grep -F 'Fabricated CTA observation' "$CASE_LANE/findings.jsonl" >/dev/null; then
  fail "consistent staging/metadata forgery reached final findings"
fi
assert_contains "in-memory finding contract ended before the staged findings" \
  "$CASE_LANE/stderr"

run_lane_case one-persona-fails "beginner expert impatient" beginner
[ "$CASE_RC" -eq 0 ] || fail "one persona failure incorrectly failed the lane"
jq -e '
  .personas_attempted == 3 and
  .personas_succeeded == 2 and
  .personas_failed == 1 and
  .persona_failures == ["beginner"] and
  .stages.analysis.status == "degraded"
' "$CASE_LANE/metrics.json" >/dev/null ||
  dump_lane_and_fail "$CASE_LANE" "one persona failure was not recorded as degraded"
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
  dump_lane_and_fail "$CASE_LANE" "all persona failure did not finish goals with honest status"

run_lane_case valid-empty "beginner" "" valid valid 0 0 beginner
[ "$CASE_RC" -eq 0 ] || fail "valid empty persona output was treated as failure"
jq -e '
  .personas_attempted == 1 and
  .personas_succeeded == 1 and
  .personas_failed == 0 and
  .stages.analysis.status == "succeeded"
' "$CASE_LANE/metrics.json" >/dev/null ||
  dump_lane_and_fail "$CASE_LANE" "valid empty persona output was not recorded as success"
[ ! -s "$CASE_LANE/findings.jsonl" ] ||
  fail "valid empty persona output unexpectedly created a finding"

run_lane_case goals-fail "beginner expert impatient" "" valid valid 1
[ "$CASE_RC" -eq 0 ] || fail "goals failure was incorrectly fatal after persona success"
jq -e '.goals_failed == true and .stages.goals.status == "failed"' \
  "$CASE_LANE/metrics.json" >/dev/null ||
  dump_lane_and_fail "$CASE_LANE" "goals failure was not recorded"
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
  dump_lane_and_fail "$CASE_LANE" "capture process failure metrics were dishonest"

run_lane_case malformed-manifest "beginner" "" valid malformed
[ "$CASE_RC" -ne 0 ] || fail "malformed capture manifest did not fail closed"
jq -e '.capture_failed == true and .stages.capture.status == "failed"' \
  "$CASE_LANE/metrics.json" >/dev/null ||
  dump_lane_and_fail "$CASE_LANE" "malformed manifest was not recorded as capture failure"

for negative_mode in unmanifested invented cross console-cross; do
  run_lane_case "negative-$negative_mode" "beginner" "" "$negative_mode"
  [ "$CASE_RC" -ne 0 ] ||
    fail "$negative_mode finding did not contribute to total analysis failure"
  jq -e '
    .invalid_findings == 1 and
    .personas_succeeded == 0 and
    .personas_failed == 1
  ' "$CASE_LANE/metrics.json" >/dev/null ||
    dump_lane_and_fail "$CASE_LANE" "$negative_mode finding was not rejected"
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

run_lane_case goals-backup-housekeeping-fail \
  "beginner" "" valid valid 0 0 "" "" 0 0 1
[ "$CASE_RC" -eq 0 ] ||
  fail "backup cleanup inverted a successfully published GOALS set"
jq -e '
  .goals_failed == false and
  .stages.goals == {attempted:true,status:"succeeded"}
' "$CASE_LANE/metrics.json" >/dev/null ||
  dump_lane_and_fail "$CASE_LANE" "backup cleanup failure made GOALS publication status dishonest"
assert_file_exists "$CASE_STATE/goals/GOALS-draft.md"
assert_file_exists "$CASE_STATE/goals/feature-map.md"
assert_file_exists "$CASE_STATE/goals/range-map.md"

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
  dump_lane_and_fail "$CASE_LANE" "goals publication failure was not recorded"
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
  dump_lane_and_fail "$CASE_LANE" "unsafe goals destination refusal was not recorded"

unsafe_goals_dir_state="$TEST_TMP/cases/unsafe-goals-directory/state"
mkdir -p "$unsafe_goals_dir_state/protected-goals"
printf '%s\n' "# protected goals directory" \
  > "$unsafe_goals_dir_state/protected-goals/keep.md"
for protected_goal_file in GOALS-draft.md feature-map.md range-map.md; do
  printf '%s\n' "# protected $protected_goal_file" \
    > "$unsafe_goals_dir_state/protected-goals/$protected_goal_file"
done
ln -s "$unsafe_goals_dir_state/protected-goals" \
  "$unsafe_goals_dir_state/goals"
run_lane_case unsafe-goals-directory "beginner"
[ "$CASE_RC" -eq 0 ] ||
  fail "unsafe goals directory aborted independent capture/persona analysis"
[ "$(wc -l < "$CASE_LANE/findings.jsonl" | tr -d ' ')" -eq 1 ] ||
  fail "unsafe goals directory discarded accepted persona findings"
assert_contains "# protected goals directory" \
  "$unsafe_goals_dir_state/protected-goals/keep.md"
jq -e '
  .goals_failed == true and
  .stages.capture.status == "succeeded" and
  .stages.analysis.status == "succeeded" and
  .stages.goals == {attempted:true,status:"failed"}
' "$CASE_LANE/metrics.json" >/dev/null ||
  dump_lane_and_fail "$CASE_LANE" "unsafe goals directory was not isolated to the goals stage"

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
  dump_lane_and_fail "$serve_failure_lane" "early serve failure reported later stages as successful"

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
  FAKE_EXPECTED_PGID=777 FAKE_BASELINE_ANCHOR_PID="$$" \
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
  dump_lane_and_fail "$cleanup_failure_lane" "server cleanup failure was absent from metrics"
[ "$(wc -l < "$cleanup_failure_lane/findings.jsonl" | tr -d ' ')" -eq 1 ] ||
  fail "server cleanup failure prevented honest final findings publication"
rm -f "$cleanup_failure_port_state"

publication_order_state="$TEST_TMP/cases/publication-before-cleanup/state"
publication_order_night=2026-07-29-publication-before-cleanup
publication_order_lane="$publication_order_state/lanes/$publication_order_night/lane_1"
publication_order_checkout="$TEST_TMP/publication-order-checkout"
publication_order_port_state="$TEST_TMP/publication-order-port"
publication_order_block="$TEST_TMP/publication-order-block"
publication_order_started="$TEST_TMP/publication-order-cleanup-started"
mkdir -p \
  "$publication_order_lane/home" \
  "$publication_order_lane/tmp" \
  "$publication_order_checkout/node_modules"
: > "$publication_order_block"
/usr/bin/env -i \
  PATH="$stub_path" HOME="$publication_order_lane/home" \
  TMPDIR="$publication_order_lane/tmp" LANG=C TERM=dumb \
  NIGHT_ID="$publication_order_night" LANE_DIR="$publication_order_lane" \
  METSUKE_LP_CHECKOUT="$publication_order_checkout" METSUKE_PORT=43126 \
  METSUKE_PERSONAS=beginner PLAYWRIGHT_BROWSERS_PATH_REAL="$browser_cache" \
  METSUKE_CODEX_BIN=codex FAKE_PORT_STATE="$publication_order_port_state" \
  FAKE_EXPECTED_PGID=778 FAKE_BASELINE_ANCHOR_PID="$$" \
  FAKE_CLEANUP_BLOCK_FILE="$publication_order_block" \
  FAKE_CLEANUP_STARTED_FILE="$publication_order_started" \
  /bin/bash "$RUN_SH" >"$publication_order_lane/stdout" \
  2>"$publication_order_lane/stderr" &
publication_order_pid=$!
publication_order_ticks=0
while [ ! -e "$publication_order_started" ] &&
  [ "$publication_order_ticks" -lt 500 ]; do
  sleep 0.02
  publication_order_ticks=$((publication_order_ticks + 1))
done
publication_order_fail() {
  local message=$1
  local count=$2
  local staging_file
  local staging_exists=false
  local rc=0
  {
    printf 'findings.jsonl line count at cleanup seam: %s\n' "$count"
    printf 'cleanup-marker ticks: %s/500\n' "$publication_order_ticks"
    for staging_file in "$publication_order_lane"/.accepted-findings.*; do
      [ -e "$staging_file" ] || continue
      staging_exists=true
      printf 'staging file: %s\n' "$staging_file"
    done
    printf 'staging file exists: %s\n' "$staging_exists"
  } >&2 || true
  kill -TERM "$publication_order_pid" 2>/dev/null || true
  rm -f "$publication_order_block" || kill -KILL "$publication_order_pid" 2>/dev/null || true
  wait "$publication_order_pid" 2>/dev/null || rc=$?
  printf 'lane exit status: %s\n' "$rc" >&2 || true
  dump_lane_and_fail "$publication_order_lane" "$message"
}
# Snapshot immediately at the cleanup seam: waiting for publication here would
# hide a regression that publishes findings after cleanup has already begun.
publication_order_count=missing
if [ -f "$publication_order_lane/findings.jsonl" ]; then
  publication_order_count=$(wc -l < "$publication_order_lane/findings.jsonl" | tr -d ' ')
fi
[ -e "$publication_order_started" ] ||
  publication_order_fail "blocking cleanup seam never began" "$publication_order_count"
[ "$publication_order_count" = 1 ] ||
  publication_order_fail "accepted finding was not atomically published before cleanup began" "$publication_order_count"
kill -TERM "$publication_order_pid" 2>/dev/null || true
rm -f "$publication_order_block"
wait "$publication_order_pid" 2>/dev/null || true
[ "$(wc -l < "$publication_order_lane/findings.jsonl" | tr -d ' ')" -eq 1 ] ||
  fail "termination during cleanup lost an already accepted finding"

candidate_probe="$TEST_TMP/candidate-race-probe.sh"
{
  printf '%s\n' '#!/bin/bash'
  sed -n '/^candidate_is_active()/,/^}/p' "$SERVE_SH"
  cat <<'EOF'
kill_calls=0
kill() {
  kill_calls=$((kill_calls + 1))
  [ "$kill_calls" -eq 1 ]
}
ps() {
  return 1
}
set +e
candidate_is_active 424242
candidate_status=$?
set -e
[ "$candidate_status" -eq 1 ]
EOF
} > "$candidate_probe"
/bin/bash "$candidate_probe" ||
  fail "candidate exit between kill -0 and ps was reported as inspection failure"

printf 'test_metsuke_offline: PASS\n'
