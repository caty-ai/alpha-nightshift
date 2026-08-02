#!/bin/bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
# shellcheck source=tests/helpers.sh
. "$TEST_DIR/helpers.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-review-selection.XXXXXX")
TEST_TMP=$(cd -P "$TEST_TMP" && pwd -P)
trap 'rm -rf "$TEST_TMP"' EXIT
RUN_SH="$ROOT/lanes/review/run.sh"
SELECT_LANE="$TEST_TMP/select-lane"
mkdir -p "$SELECT_LANE"

select_review() {
  LANE_DIR="$SELECT_LANE" /bin/bash "$RUN_SH" select "$@"
}

select_review stable-night codex,kimi,glm,grok,opus 3 1 \
  > "$TEST_TMP/selection-a.json"
select_review stable-night opus,grok,glm,kimi,codex 3 1 \
  > "$TEST_TMP/selection-b.json"
cmp -s "$TEST_TMP/selection-a.json" "$TEST_TMP/selection-b.json" ||
  fail "same night and roster set did not produce the same assignment"

: > "$TEST_TMP/lenses.txt"
: > "$TEST_TMP/seats.txt"
: > "$TEST_TMP/pairs.txt"
night_number=1
while [ "$night_number" -le 100 ]; do
  select_review "synthetic-night-$night_number" \
    codex,kimi,glm,grok,opus 3 1 > "$TEST_TMP/selection.json"
  jq -r '.lens' "$TEST_TMP/selection.json" >> "$TEST_TMP/lenses.txt"
  jq -r '.seats[]' "$TEST_TMP/selection.json" >> "$TEST_TMP/seats.txt"
  jq -r '[.lens, (.seats | join(","))] | join("|")' \
    "$TEST_TMP/selection.json" >> "$TEST_TMP/pairs.txt"
  night_number=$((night_number + 1))
done

cat > "$TEST_TMP/expected-lenses.txt" <<'EOF'
Bug
Demo Device・UT
Dependency
Documentation Drift
External Issue Triage(受け口のみ)
Feature Improvement
Performance
Refactor
Security
UI・UX・Accessibility
EOF
LC_ALL=C sort -u "$TEST_TMP/lenses.txt" > "$TEST_TMP/actual-lenses.txt"
cmp -s "$TEST_TMP/expected-lenses.txt" "$TEST_TMP/actual-lenses.txt" ||
  fail "100 synthetic nights did not cover the exact ten DESIGN lenses"
printf '%s\n' codex glm grok kimi opus | LC_ALL=C sort > "$TEST_TMP/expected-seats.txt"
LC_ALL=C sort -u "$TEST_TMP/seats.txt" > "$TEST_TMP/actual-seats.txt"
cmp -s "$TEST_TMP/expected-seats.txt" "$TEST_TMP/actual-seats.txt" ||
  fail "synthetic nights did not rotate through every configured seat"
distinct_pair_count=$(LC_ALL=C sort -u "$TEST_TMP/pairs.txt" | wc -l | tr -d '[:space:]')
[ "$distinct_pair_count" -gt 10 ] ||
  fail "lens and seat-set selection remained lockstep ($distinct_pair_count distinct pairs)"

if select_review zero-seat-night codex,kimi,glm 0 0 >/dev/null 2>&1; then
  fail "select mode accepted a zero seat count"
fi
select_review clamp-night codex,kimi,glm 9 0 \
  > "$TEST_TMP/clamped.json" 2> "$TEST_TMP/clamped.log"
[ "$(jq '.seats | length' "$TEST_TMP/clamped.json")" -eq 3 ] ||
  fail "select mode did not clamp the seat count to the roster size"
assert_contains 'WARN REVIEW_SEATS_PER_NIGHT=9 exceeds roster size=3; clamping' \
  "$TEST_TMP/clamped.log"

valid='{"id":"forged-id","repo":"forged-repo","target":"lib/example.sh","symptom":"The error path drops the exit status","kind":"bug","confirm_cost":"1分","date":"forged-date","interpretation":"Callers can report success after failure","persona":"forged-persona","evidence":["safe/proof.txt"]}'
printf '%s\n' "$valid" | /bin/bash "$RUN_SH" validate-candidate \
  codex bug a1b2c3d repo-name 2026-08-02 1 > "$TEST_TMP/normalized.json"
expected_digest=$(printf '%s\n%s' 'lib/example.sh' \
  'The error path drops the exit status' | /usr/bin/shasum -a 256 |
  awk '{print substr($1, 1, 8)}')
jq -e --arg digest "$expected_digest" '
  .id == "rv-bug-codex-a1b2c3d-" + $digest and
  .repo == "repo-name" and
  .date == "2026-08-02" and
  .target == "lib/example.sh" and
  .symptom == "The error path drops the exit status" and
  .kind == "bug" and
  .confirm_cost == "1分" and
  .interpretation == "Callers can report success after failure" and
  .persona == "seat:codex" and
  .evidence == ["evidence/seat-codex.log"]
' "$TEST_TMP/normalized.json" >/dev/null ||
  fail "valid candidate fields were not preserved and normalized"

printf '%s\n' "$valid" | /bin/bash "$RUN_SH" validate-candidate \
  codex bug a1b2c3d repo-name 2026-08-03 2 > "$TEST_TMP/same-observation.json"
same_id=$(jq -r '.id' "$TEST_TMP/same-observation.json")
[ "$same_id" = "$(jq -r '.id' "$TEST_TMP/normalized.json")" ] ||
  fail "the same observation at the same commit changed ID across nights"
different_symptom=$(printf '%s\n' "$valid" |
  jq -c '.symptom = "The README omits all recovery instructions"')
printf '%s\n' "$different_symptom" | /bin/bash "$RUN_SH" validate-candidate \
  codex bug a1b2c3d repo-name 2026-08-03 2 > "$TEST_TMP/different-observation.json"
[ "$(jq -r '.id' "$TEST_TMP/different-observation.json")" != "$same_id" ] ||
  fail "different observations at the same seat/lens/commit collided"

expect_rejected() {
  rejected=$1
  if printf '%s\n' "$rejected" | /bin/bash "$RUN_SH" validate-candidate \
    codex bug a1b2c3d repo-name 2026-08-02 1 >/dev/null 2>&1; then
    fail "unsafe candidate was accepted: $rejected"
  fi
}

expect_rejected '{malformed'
expect_rejected '{"id":"x","repo":"r","target":"t","symptom":"s","kind":"k","confirm_cost":"5分","date":"d"}'
expect_rejected '{"id":"x","repo":"r","target":"t","symptom":"s","kind":"k","confirm_cost":"即断","date":"d","evidence":["/absolute/proof"]}'
expect_rejected '{"id":"x","repo":"r","target":"t","symptom":"s","kind":"k","confirm_cost":"即断","date":"d","extra":"unknown"}'
expect_rejected '{"id":"x","repo":"r","target":"t","symptom":"s","kind":"k","confirm_cost":"即断","date":"d","evidence":["safe/../proof"]}'

assert_contains '    --ignore-user-config' "$ROOT/lanes/review/adapters/codex.sh"
assert_contains '    --disable multi_agent' "$ROOT/lanes/review/adapters/codex.sh"
assert_contains '    -m kimi-code/k3' "$ROOT/lanes/review/adapters/kimi.sh"
assert_contains '    --output-format text' "$ROOT/lanes/review/adapters/kimi.sh"
assert_contains '    -m grok-4.5' "$ROOT/lanes/review/adapters/grok.sh"
assert_contains '    --no-subagents' "$ROOT/lanes/review/adapters/grok.sh"
assert_contains '      --permission-mode dontAsk' "$ROOT/lanes/review/adapters/opus.sh"
assert_contains '      --allowedTools Read,Glob,Grep' "$ROOT/lanes/review/adapters/opus.sh"
# This is a literal source-string assertion, not an expansion.
# shellcheck disable=SC2016
assert_contains 'curl_bin=${REVIEW_CURL_BIN:-/usr/bin/curl}' \
  "$ROOT/lanes/review/adapters/glm.sh"
# This is a literal source-string assertion, not an expansion.
# shellcheck disable=SC2016
assert_contains '    "$curl_bin" -q --config -' "$ROOT/lanes/review/adapters/glm.sh"
assert_contains 'api_url=https://api.z.ai/api/anthropic/v1/messages' \
  "$ROOT/lanes/review/adapters/glm.sh"
assert_not_contains 'GLM_KEY_FILE=' "$ROOT/lanes/review/adapters/glm.sh"

glm_work="$TEST_TMP/glm-work"
glm_out="$TEST_TMP/glm-out"
glm_prompt="$TEST_TMP/glm-prompt"
glm_key="$TEST_TMP/glm-key"
mkdir -p "$glm_work" "$glm_out"
printf '%s\n' 'prompt' > "$glm_prompt"
printf '%s\n' 'PLANTED_GLM_SECRET' > "$glm_key"
chmod 0640 "$glm_key"
if GLM_KEY_FILE="$glm_key" /bin/bash "$ROOT/lanes/review/adapters/glm.sh" \
  "$glm_prompt" "$glm_work" "$glm_out" > "$TEST_TMP/glm-readable.log" 2>&1; then
  fail "GLM adapter accepted a group-readable key file"
fi
assert_contains 'must not be group- or world-readable' "$TEST_TMP/glm-readable.log"
assert_not_contains PLANTED_GLM_SECRET "$TEST_TMP/glm-readable.log"

dangling_work="$TEST_TMP/dangling-work"
dangling_out="$TEST_TMP/dangling-out"
dangling_target="$TEST_TMP/dangling-target"
dangling_bin="$TEST_TMP/dangling-kimi"
mkdir -p "$dangling_work" "$dangling_out"
# The quoted line below is a literal test-double program.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'ln -s "$DANGLING_TARGET" "$CANDIDATE_PATH"' \
  > "$dangling_bin"
chmod +x "$dangling_bin"
if REVIEW_KIMI_BIN="$dangling_bin" \
  DANGLING_TARGET="$dangling_target" \
  CANDIDATE_PATH="$dangling_out/candidates.jsonl" \
  /bin/bash "$ROOT/lanes/review/adapters/kimi.sh" \
    "$glm_prompt" "$dangling_work" "$dangling_out" >/dev/null 2>&1; then
  fail "Kimi adapter followed a dangling candidate symlink during fallback"
fi
[ ! -e "$dangling_target" ] || fail "adapter fallback wrote through a dangling symlink"

printf 'test_lane_review_selection: PASS\n'
