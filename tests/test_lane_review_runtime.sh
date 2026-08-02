#!/bin/bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
# shellcheck source=tests/helpers.sh
. "$TEST_DIR/helpers.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-review-runtime.XXXXXX")
TEST_TMP=$(cd -P "$TEST_TMP" && pwd -P)
cleanup() {
  find "$TEST_TMP" -type d -name review-checkout -prune -exec chmod -R u+w {} \; 2>/dev/null || true
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT
RUN_SH="$ROOT/lanes/review/run.sh"
SOURCE_REPO="$TEST_TMP/source-repo"
FAKE_BIN="$TEST_TMP/bin"
mkdir -p "$SOURCE_REPO" "$FAKE_BIN"
git -C "$SOURCE_REPO" init -q
git -C "$SOURCE_REPO" config user.name review-test
git -C "$SOURCE_REPO" config user.email review-test@example.invalid
printf '%s\n' '# Runtime fixture' > "$SOURCE_REPO/README.md"
git -C "$SOURCE_REPO" add README.md
git -C "$SOURCE_REPO" commit -qm fixture

candidate='{"id":"candidate-id","repo":"candidate-repo","target":"README.md","symptom":"The README contains only a title","kind":"documentation","confirm_cost":"即断","date":"candidate-date","interpretation":"A new operator has no run instructions","persona":"candidate-persona","evidence":["candidate/proof.txt"]}'
GLM_KEY_CANARY="$TEST_TMP/operator-glm-key"
printf '%s\n' 'glm-canary-key' > "$GLM_KEY_CANARY"
chmod 600 "$GLM_KEY_CANARY"

write_success_bins() {
  # The quoted lines below are literal test-double programs.
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    '[ -z "${GH_TOKEN:-}" ] || exit 77' \
    '[ -z "${GLM_KEY_FILE:-}" ] || exit 78' \
    '[ -z "${REVIEW_CLAUDE_CONFIG_DIR:-}" ] || exit 79' \
    'prompt=$(mktemp "${TMPDIR:-/tmp}/review-codex-prompt.XXXXXX")' \
    'trap '\''rm -f "$prompt"'\'' EXIT' \
    'cat > "$prompt"' \
    'out=$(sed -n '\''/\/candidates\.jsonl$/p'\'' "$prompt" | sed -n '\''1p'\'')' \
    '[ -n "$out" ]' \
    "printf '%s\\n' '$candidate' > \"\$out\"" \
    > "$FAKE_BIN/codex"
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    '[ -z "${GH_TOKEN:-}" ] || exit 77' \
    '[ -z "${GLM_KEY_FILE:-}" ] || exit 78' \
    '[ -z "${REVIEW_CLAUDE_CONFIG_DIR:-}" ] || exit 79' \
    'for chatter in 1 2 3 4 5 6 7 8; do printf "chatter-%s\n" "$chatter" >&2; done' \
    "printf '%s\\n' '$candidate'" \
    > "$FAKE_BIN/kimi"
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    '[ -z "${GH_TOKEN:-}" ] || exit 77' \
    '[ -z "${GLM_KEY_FILE:-}" ] || exit 78' \
    '[ -z "${REVIEW_CLAUDE_CONFIG_DIR:-}" ] || exit 79' \
    "printf '%s\\n' '$candidate'" \
    > "$FAKE_BIN/grok"
  chmod +x "$FAKE_BIN/codex" "$FAKE_BIN/kimi" "$FAKE_BIN/grok"
}

run_review() {
  lane=$1
  shift
  /usr/bin/env -i \
    PATH="$PATH" \
    HOME="$lane/home" \
    TMPDIR="$lane/tmp" \
    LANG="${LANG:-C}" \
    TERM=dumb \
    GH_TOKEN=canary-not-real \
    NIGHT_ID=runtime-night \
    LANE_DIR="$lane" \
    REVIEW_TARGET_SOURCE="$SOURCE_REPO" \
    REVIEW_SEAT_ROSTER=codex,kimi,grok \
    REVIEW_SEATS_PER_NIGHT=3 \
    REVIEW_SEAT_TIMEOUT_SEC=5 \
    REVIEW_CODEX_BIN="$FAKE_BIN/codex" \
    REVIEW_KIMI_BIN="$FAKE_BIN/kimi" \
    REVIEW_GROK_BIN="$FAKE_BIN/grok" \
    GLM_KEY_FILE="$GLM_KEY_CANARY" \
    REVIEW_CLAUDE_CONFIG_DIR="$TEST_TMP/claude-config-canary" \
    /bin/bash "$RUN_SH" "$@"
}

write_success_bins

# Each selected adapter gets a HOME exposing only its own opted-in auth link.
HOME_LANE="$TEST_TMP/home-isolation-lane"
HOME_AUTH_ROOT="$TEST_TMP/home-auth"
mkdir -p "$HOME_LANE/home" "$HOME_AUTH_ROOT/codex" "$HOME_AUTH_ROOT/kimi"
ln -s "$HOME_AUTH_ROOT/codex" "$HOME_LANE/home/.codex"
ln -s "$HOME_AUTH_ROOT/kimi" "$HOME_LANE/home/.kimi-code"
# The quoted lines below are literal test-double programs.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'prompt=$(mktemp "${TMPDIR:-/tmp}/review-home-codex.XXXXXX")' \
  'trap '\''rm -f "$prompt"'\'' EXIT' \
  'cat > "$prompt"' \
  'out=$(sed -n '\''/\/candidates\.jsonl$/p'\'' "$prompt" | sed -n '\''1p'\'')' \
  'printf "%s\n" "$HOME" > "$(dirname "$out")/seen-home.txt"' \
  'find "$HOME" -mindepth 1 -maxdepth 1 -print > "$(dirname "$out")/home-entries.txt"' \
  "printf '%s\\n' '$candidate' > \"\$out\"" \
  > "$FAKE_BIN/codex"
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'prompt=$2' \
  'out=$(printf "%s\n" "$prompt" | sed -n '\''/\/candidates\.jsonl$/p'\'' | sed -n '\''1p'\'')' \
  'printf "%s\n" "$HOME" > "$(dirname "$out")/seen-home.txt"' \
  'find "$HOME" -mindepth 1 -maxdepth 1 -print > "$(dirname "$out")/home-entries.txt"' \
  "printf '%s\\n' '$candidate'" \
  > "$FAKE_BIN/kimi"
chmod +x "$FAKE_BIN/codex" "$FAKE_BIN/kimi"
/usr/bin/env -i \
  PATH="$PATH" \
  HOME="$HOME_LANE/home" \
  TMPDIR="$HOME_LANE/tmp" \
  LANG="${LANG:-C}" \
  TERM=dumb \
  LANE_DIR="$HOME_LANE" \
  NIGHT_ID=home-isolation-night \
  REVIEW_TARGET_SOURCE="$SOURCE_REPO" \
  REVIEW_SEAT_ROSTER=codex,kimi \
  REVIEW_SEATS_PER_NIGHT=2 \
  REVIEW_SEAT_TIMEOUT_SEC=5 \
  REVIEW_CODEX_BIN="$FAKE_BIN/codex" \
  REVIEW_KIMI_BIN="$FAKE_BIN/kimi" \
  /bin/bash "$RUN_SH" || fail "per-seat HOME isolation run failed"
[ "$(sed -n '1p' "$HOME_LANE/work/review-seats/codex/seen-home.txt")" = \
  "$HOME_LANE/work/review-homes/codex" ] || fail "Codex did not receive its isolated HOME"
[ "$(sed -n '1p' "$HOME_LANE/work/review-seats/kimi/seen-home.txt")" = \
  "$HOME_LANE/work/review-homes/kimi" ] || fail "Kimi did not receive its isolated HOME"
assert_contains '/.codex' "$HOME_LANE/work/review-seats/codex/home-entries.txt"
assert_not_contains '/.kimi-code' "$HOME_LANE/work/review-seats/codex/home-entries.txt"
assert_contains '/.kimi-code' "$HOME_LANE/work/review-seats/kimi/home-entries.txt"
assert_not_contains '/.codex' "$HOME_LANE/work/review-seats/kimi/home-entries.txt"

write_success_bins
# Make one of three seats fail. The other two must still publish findings.
printf '%s\n' '#!/bin/bash' 'exit 9' > "$FAKE_BIN/kimi"
chmod +x "$FAKE_BIN/kimi"
DEGRADED_LANE="$TEST_TMP/degraded-lane"
mkdir -p "$DEGRADED_LANE"
run_review "$DEGRADED_LANE" || fail "one failed seat made the whole lane fail"
[ "$(wc -l < "$DEGRADED_LANE/findings.jsonl" | tr -d '[:space:]')" -eq 2 ] ||
  fail "degraded lane did not retain findings from two successful seats"
assert_file_exists "$DEGRADED_LANE/evidence/seat-kimi.log"
assert_contains 'seat=kimi status=failed' "$DEGRADED_LANE/evidence/run.log"
assert_not_contains canary-not-real "$DEGRADED_LANE/evidence/seat-codex.log" \
  "$DEGRADED_LANE/evidence/seat-kimi.log" "$DEGRADED_LANE/evidence/seat-grok.log" \
  "$DEGRADED_LANE/evidence/run.log"
assert_not_contains "$GLM_KEY_CANARY" "$DEGRADED_LANE/evidence/seat-codex.log" \
  "$DEGRADED_LANE/evidence/seat-kimi.log" "$DEGRADED_LANE/evidence/seat-grok.log"
assert_not_contains glm-canary-key "$DEGRADED_LANE/evidence/seat-codex.log" \
  "$DEGRADED_LANE/evidence/seat-kimi.log" "$DEGRADED_LANE/evidence/seat-grok.log"
assert_not_contains "$TEST_TMP/claude-config-canary" \
  "$DEGRADED_LANE/evidence/seat-codex.log" \
  "$DEGRADED_LANE/evidence/seat-kimi.log" \
  "$DEGRADED_LANE/evidence/seat-grok.log"
# A same-directory rerun regenerates findings rather than appending duplicates.
write_success_bins
run_review "$DEGRADED_LANE" || fail "same-directory rerun failed"
[ "$(wc -l < "$DEGRADED_LANE/findings.jsonl" | tr -d '[:space:]')" -eq 3 ] ||
  fail "same-directory rerun duplicated prior findings"
[ "$(jq -r '.id' "$DEGRADED_LANE/findings.jsonl" | LC_ALL=C sort -u | wc -l | tr -d '[:space:]')" -eq 3 ] ||
  fail "normalized finding IDs were not unique"
assert_contains 'chatter-8' "$DEGRADED_LANE/evidence/seat-kimi.log"

# Every evidence file except the manifest must appear with exact digest/bytes.
for evidence_file in "$DEGRADED_LANE"/evidence/*; do
  [ "$(basename "$evidence_file")" = manifest.json ] && continue
  ref=${evidence_file#"$DEGRADED_LANE/"}
  expected_sha=$(shasum -a 256 "$evidence_file" | awk '{print $1}')
  expected_bytes=$(wc -c < "$evidence_file" | tr -d '[:space:]')
  jq -e --arg ref "$ref" --arg sha "$expected_sha" --argjson bytes "$expected_bytes" \
    '.files[$ref] == {sha256:$sha,bytes:$bytes}' \
    "$DEGRADED_LANE/evidence/manifest.json" >/dev/null ||
    fail "manifest metadata mismatch for $ref"
done
manifest_count=$(jq '.files | length' "$DEGRADED_LANE/evidence/manifest.json")
evidence_count=$(find "$DEGRADED_LANE/evidence" -type f ! -name manifest.json | wc -l | tr -d '[:space:]')
[ "$manifest_count" -eq "$evidence_count" ] || fail "manifest did not cover the exact evidence file set"

# The GLM adapter sends an Anthropic-shaped request through stdin config and
# extracts candidate JSONL from Anthropic messages content.
GLM_CURL_BIN="$FAKE_BIN/glm-curl"
# The quoted lines below are a literal curl test double.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  '[ "$#" -eq 3 ] && [ "$1" = -q ] && [ "$2" = --config ] && [ "$3" = - ] || exit 81' \
  'case "$*" in *glm-canary-key*) exit 82 ;; esac' \
  'config_file="$TMPDIR/glm-curl-config.txt"' \
  'cat > "$config_file"' \
  'grep -F -x '\''header = "x-api-key: glm-canary-key"'\'' "$config_file" >/dev/null || exit 83' \
  'grep -F -x '\''header = "anthropic-version: 2023-06-01"'\'' "$config_file" >/dev/null || exit 84' \
  'grep -F -x '\''data-binary = "@glm-request.json"'\'' "$config_file" >/dev/null || exit 85' \
  'jq -e '\''.model == "glm-5.2" and .max_tokens == 4096 and (.messages | length == 1) and .messages[0].role == "user" and (.messages[0].content | type == "string")'\'' glm-request.json >/dev/null || exit 86' \
  "jq -n --arg text '$candidate' '{id:\"msg_test\",type:\"message\",role:\"assistant\",model:\"glm-5.2\",content:[{type:\"text\",text:\$text}],stop_reason:\"end_turn\",usage:{input_tokens:12,output_tokens:34}}'" \
  > "$GLM_CURL_BIN"
chmod +x "$GLM_CURL_BIN"

run_glm_review() {
  glm_lane=$1
  glm_curl=$2
  mkdir -p "$glm_lane"
  /usr/bin/env -i \
    PATH="$PATH" \
    HOME="$glm_lane/home" \
    TMPDIR="$glm_lane/tmp" \
    LANG="${LANG:-C}" \
    TERM=dumb \
    LANE_DIR="$glm_lane" \
    NIGHT_ID=glm-runtime-night \
    REVIEW_TARGET_SOURCE="$SOURCE_REPO" \
    REVIEW_SEAT_ROSTER=glm \
    REVIEW_SEATS_PER_NIGHT=1 \
    REVIEW_SEAT_TIMEOUT_SEC=5 \
    GLM_KEY_FILE="$GLM_KEY_CANARY" \
    REVIEW_CURL_BIN="$glm_curl" \
    /bin/bash "$RUN_SH"
}

GLM_LANE="$TEST_TMP/glm-lane"
run_glm_review "$GLM_LANE" "$GLM_CURL_BIN" || fail "GLM happy-path lane failed"
[ "$(wc -l < "$GLM_LANE/findings.jsonl" | tr -d '[:space:]')" -eq 1 ] ||
  fail "GLM Anthropic response did not produce one validated finding"
jq -e '.persona == "seat:glm" and .target == "README.md"' \
  "$GLM_LANE/findings.jsonl" >/dev/null || fail "GLM finding was not normalized end-to-end"
assert_contains 'seat=glm status=ok candidates=1' "$GLM_LANE/evidence/run.log"
assert_contains 'header = "x-api-key: glm-canary-key"' \
  "$GLM_LANE/tmp/glm-curl-config.txt"

GLM_EMPTY_CURL_BIN="$FAKE_BIN/glm-empty-curl"
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  '[ "$#" -eq 3 ] && [ "$1" = -q ] && [ "$2" = --config ] && [ "$3" = - ] || exit 81' \
  'case "$*" in *glm-canary-key*) exit 82 ;; esac' \
  'cat >/dev/null' \
  'printf '\''%s\n'\'' '\''{"id":"msg_empty","type":"message","role":"assistant","model":"glm-5.2","content":[{"type":"text","text":"No structured findings were returned."}],"stop_reason":"end_turn"}'\''' \
  > "$GLM_EMPTY_CURL_BIN"
chmod +x "$GLM_EMPTY_CURL_BIN"
GLM_EMPTY_LANE="$TEST_TMP/glm-empty-lane"
run_glm_review "$GLM_EMPTY_LANE" "$GLM_EMPTY_CURL_BIN" ||
  fail "GLM non-JSONL envelope should complete successfully"
[ ! -s "$GLM_EMPTY_LANE/findings.jsonl" ] ||
  fail "GLM non-JSONL envelope unexpectedly produced a finding"
assert_contains 'seat=glm status=ok candidates=0' "$GLM_EMPTY_LANE/evidence/run.log"

# Content-derived IDs make repeated lines true within-night duplicates.
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  "printf '%s\\n' '$candidate' '$candidate'" \
  > "$FAKE_BIN/grok"
chmod +x "$FAKE_BIN/grok"
DUPLICATE_LANE="$TEST_TMP/duplicate-lane"
mkdir -p "$DUPLICATE_LANE"
/usr/bin/env -i \
  PATH="$PATH" \
  HOME="$DUPLICATE_LANE/home" \
  TMPDIR="$DUPLICATE_LANE/tmp" \
  LANG="${LANG:-C}" \
  TERM=dumb \
  LANE_DIR="$DUPLICATE_LANE" \
  NIGHT_ID=duplicate-night \
  REVIEW_TARGET_SOURCE="$SOURCE_REPO" \
  REVIEW_SEAT_ROSTER=grok \
  REVIEW_SEATS_PER_NIGHT=1 \
  REVIEW_SEAT_TIMEOUT_SEC=5 \
  REVIEW_GROK_BIN="$FAKE_BIN/grok" \
  /bin/bash "$RUN_SH" || fail "within-night duplicate lane failed"
[ "$(wc -l < "$DUPLICATE_LANE/findings.jsonl" | tr -d '[:space:]')" -eq 1 ] ||
  fail "within-night duplicate finding was not suppressed"
assert_contains 'seat=grok skipped duplicate finding id=' "$DUPLICATE_LANE/evidence/run.log"
assert_contains 'seat=grok status=ok candidates=1' "$DUPLICATE_LANE/evidence/run.log"

# All selected adapters failing is a lane failure.
printf '%s\n' '#!/bin/bash' 'exit 8' > "$FAKE_BIN/codex"
printf '%s\n' '#!/bin/bash' 'exit 9' > "$FAKE_BIN/kimi"
printf '%s\n' '#!/bin/bash' 'exit 10' > "$FAKE_BIN/grok"
chmod +x "$FAKE_BIN/codex" "$FAKE_BIN/kimi" "$FAKE_BIN/grok"
FAILED_LANE="$TEST_TMP/failed-lane"
mkdir -p "$FAILED_LANE"
if run_review "$FAILED_LANE" >/dev/null 2>&1; then
  fail "all failed seats produced a successful lane exit"
fi
assert_file_exists "$FAILED_LANE/evidence/manifest.json"

# A failed adapter that mutates the shared clone is infrastructure failure;
# later seats must not inspect the poisoned checkout.
write_success_bins
POISON_LATER_MARKER="$TEST_TMP/poison-later-seat-ran"
# The following single-quoted lines are the literal malicious stub body.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'while [ "$#" -gt 0 ]; do' \
  '  if [ "$1" = --cwd ]; then cd "$2"; break; fi' \
  '  shift' \
  'done' \
  '[ -z "$(git remote)" ]' \
  'if git push origin HEAD:refs/heads/review-poison 2>/dev/null; then exit 80; fi' \
  'leaked_source=$(grep -R -h "clone: from /" .git 2>/dev/null | sed -n "s/.*clone: from //p" | sed -n "1p" || true)' \
  'if [ -n "$leaked_source" ]; then git -C "$leaked_source" branch review-poison; exit 81; fi' \
  'chmod u+w .git/index' \
  'git update-index --assume-unchanged README.md' \
  'chmod u+w README.md' \
  'printf "%s\n" "poisoned" > README.md' \
  'exit 9' \
  > "$FAKE_BIN/grok"
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  "printf '%s\\n' ran > '$POISON_LATER_MARKER'" \
  "printf '%s\\n' '$candidate'" \
  > "$FAKE_BIN/kimi"
chmod +x "$FAKE_BIN/grok" "$FAKE_BIN/kimi"
POISON_LANE="$TEST_TMP/poison-lane"
mkdir -p "$POISON_LANE"
if run_review "$POISON_LANE" >/dev/null 2>&1; then
  fail "failed seat mutation did not fail the lane"
fi
[ ! -e "$POISON_LATER_MARKER" ] ||
  fail "later seat ran after failed adapter poisoned the checkout"
if git -C "$SOURCE_REPO" show-ref --verify --quiet refs/heads/review-poison; then
  fail "seat wrote a ref into the source checkout"
fi
[ ! -e "$POISON_LANE/work/review-checkout/.git/logs" ] ||
  fail "clone retained source-disclosing reflogs"
if grep -R -F -- "$SOURCE_REPO" \
  "$POISON_LANE/work/review-checkout/.git" >/dev/null 2>&1; then
  fail "clone Git metadata retained the source checkout path"
fi
[ -z "$(git -C "$SOURCE_REPO" status --porcelain)" ] ||
  fail "seat modified the source checkout"
assert_contains 'modified the read-only checkout; failing closed' \
  "$POISON_LANE/evidence/run.log"
assert_file_exists "$POISON_LANE/evidence/manifest.json"
[ "$(wc -l < "$POISON_LANE/findings.jsonl" | tr -d '[:space:]')" -eq 1 ] ||
  fail "infrastructure-failed lane did not retain the pre-failure seat finding"
jq -e '.persona == "seat:codex"' "$POISON_LANE/findings.jsonl" >/dev/null ||
  fail "infrastructure-failed lane published the wrong partial finding"

# A two-second watchdog kills the seat process tree and continues to later seats.
write_success_bins
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'prompt=$(mktemp "${TMPDIR:-/tmp}/review-timeout-prompt.XXXXXX")' \
  'cat > "$prompt"' \
  'out=$(sed -n '\''/\/candidates\.jsonl$/p'\'' "$prompt" | sed -n '\''1p'\'')' \
  'printf "%s\n" "partial transcript before timeout"' \
  'sleep 300 &' \
  'printf "%s\n" "$!" > "$(dirname "$out")/orphan.pid"' \
  'sleep 300' \
  > "$FAKE_BIN/codex"
chmod +x "$FAKE_BIN/codex"
WATCHDOG_LANE="$TEST_TMP/watchdog-lane"
mkdir -p "$WATCHDOG_LANE"
watchdog_started=$(date '+%s')
/usr/bin/env -i \
  PATH="$PATH" \
  HOME="$WATCHDOG_LANE/home" \
  TMPDIR="$WATCHDOG_LANE/tmp" \
  LANG="${LANG:-C}" \
  TERM=dumb \
  LANE_DIR="$WATCHDOG_LANE" \
  NIGHT_ID=watchdog-night \
  REVIEW_TARGET_SOURCE="$SOURCE_REPO" \
  REVIEW_SEAT_ROSTER=codex,kimi,grok \
  REVIEW_SEATS_PER_NIGHT=3 \
  REVIEW_SEAT_TIMEOUT_SEC=2 \
  REVIEW_CODEX_BIN="$FAKE_BIN/codex" \
  REVIEW_KIMI_BIN="$FAKE_BIN/kimi" \
  REVIEW_GROK_BIN="$FAKE_BIN/grok" \
  /bin/bash "$RUN_SH" || fail "watchdog failure prevented successful seats from completing"
watchdog_elapsed=$(( $(date '+%s') - watchdog_started ))
[ "$watchdog_elapsed" -lt 8 ] || fail "two-second watchdog took $watchdog_elapsed seconds"
assert_contains 'timed out after 2s' "$WATCHDOG_LANE/evidence/seat-codex.log"
assert_contains 'partial transcript before timeout' \
  "$WATCHDOG_LANE/evidence/seat-codex.log"
orphan_pid=$(sed -n '1p' "$WATCHDOG_LANE/work/review-seats/codex/orphan.pid")
if kill -0 "$orphan_pid" 2>/dev/null; then
  fail "watchdog seat child survived"
fi
[ "$(wc -l < "$WATCHDOG_LANE/findings.jsonl" | tr -d '[:space:]')" -eq 2 ] ||
  fail "watchdog lane did not continue through the remaining seats"

printf 'test_lane_review_runtime: PASS\n'
