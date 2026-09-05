#!/bin/bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
# shellcheck source=tests/helpers.sh
# shellcheck disable=SC1091
. "$TEST_DIR/helpers.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-review-rotation.XXXXXX")
TEST_TMP=$(cd -P "$TEST_TMP" && pwd -P)
trap 'rm -rf "$TEST_TMP"' EXIT
ROTATE_SH=${ROTATE_SH:-"$ROOT/lanes/review/rotate.sh"}
STUB_RUN="$TEST_TMP/stub-run.sh"
HANDOFF_RUN="$TEST_TMP/handoff-run.sh"
SURVIVAL_RUN="$TEST_TMP/survival-run.sh"
MIRRORS="$TEST_TMP/mirrors"
mkdir -p "$MIRRORS"

# The single-quoted line below is the literal stub program.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'target_name=$(basename "$REVIEW_TARGET_SOURCE")' \
  'jq -e --arg name "$target_name" --arg night_id "$NIGHT_ID" ".targets[\$name].last_attempt == \$night_id" "$REVIEW_ROTATION_STATE" >/dev/null' \
  'printf "%s\n" "$REVIEW_TARGET_SOURCE" > "$STUB_OUTPUT"' \
  > "$STUB_RUN"
chmod +x "$STUB_RUN"

# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'printf "%s\\n" "$REVIEW_TARGET_SOURCE" > "$STUB_OUTPUT"' \
  'exit 17' \
  > "$HANDOFF_RUN"
chmod +x "$HANDOFF_RUN"

# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'rm -rf "$LANE_DIR/evidence"' \
  'jq -e . "$LANE_DIR/rotation.json" >/dev/null' \
  'exit 0' \
  > "$SURVIVAL_RUN"
chmod +x "$SURVIVAL_RUN"

init_mirror() {
  mirror_name=$1
  mirror_path="$MIRRORS/$mirror_name"
  mkdir -p "$mirror_path"
  git -C "$mirror_path" init -q
  git -C "$mirror_path" config user.name 'Rotation Test'
  git -C "$mirror_path" config user.email 'rotation@example.invalid'
  printf '%s\n' "$mirror_name" > "$mirror_path/tracked.txt"
  git -C "$mirror_path" add tracked.txt
  git -C "$mirror_path" -c core.hooksPath=/dev/null commit -q -m 'Initialize mirror'
  printf '%s\n' "$mirror_path"
}

file_inode() {
  if stat -f %i "$1" >/dev/null 2>&1; then
    stat -f %i "$1"
  else
    stat -c %i "$1"
  fi
}

run_rotation() {
  run_lane=$1
  run_state=$2
  run_targets=$3
  run_night=$4
  run_refresh=${5:-0}
  run_script=${6:-"$STUB_RUN"}
  mkdir -p "$run_lane"
  LANE_DIR="$run_lane" \
    NIGHT_ID="$run_night" \
    REVIEW_ROTATION_STATE="$run_state" \
    REVIEW_ROTATION_TARGETS="$run_targets" \
    REVIEW_ROTATION_REFRESH="$run_refresh" \
    REVIEW_ROTATION_RUN="$run_script" \
    STUB_OUTPUT="$run_lane/stub-output" \
    /bin/bash "$ROTATE_SH"
}

A=$(init_mirror a)
B=$(init_mirror b)
C=$(init_mirror c)

# 1. Fresh state selects the first entry and records a never-attempted run.
case_one="$TEST_TMP/case-one"
mkdir -p "$case_one/state"
run_rotation "$case_one/lane" "$case_one/state/rotation.json" \
  "a=$A b=$B c=$C" 2026-09-05 > "$case_one/stdout" 2> "$case_one/stderr"
[ "$(<"$case_one/lane/stub-output")" = "$A" ] || fail 'fresh state did not select first target'
jq -e '
  .schema_version == 1 and
  .targets.a.last_attempt == "2026-09-05" and
  .targets.a.last_result == "run"
' "$case_one/state/rotation.json" >/dev/null || fail 'fresh state result was not recorded'
jq -e '
  .reason == "never-attempted" and
  .previous_last_attempt == null and
  .refresh == "skipped" and
  .candidates == [
    {"name":"a","last_attempt":null},
    {"name":"b","last_attempt":null},
    {"name":"c","last_attempt":null}
  ]
' "$case_one/lane/rotation.json" >/dev/null || fail 'fresh evidence is incorrect'

# 2. The oldest recorded attempt wins.
case_two="$TEST_TMP/case-two"
mkdir -p "$case_two/state"
printf '%s\n' '{"schema_version":1,"targets":{"a":{"last_attempt":"2026-09-01","last_result":"run"},"b":{"last_attempt":"2026-09-03","last_result":"run"},"c":{"last_attempt":"2026-09-02","last_result":"run"}}}' > "$case_two/state/rotation.json"
state_inode_before=$(file_inode "$case_two/state/rotation.json")
run_rotation "$case_two/lane" "$case_two/state/rotation.json" \
  "a=$A b=$B c=$C" 2026-09-05 >/dev/null 2> "$case_two/stderr"
[ "$(<"$case_two/lane/stub-output")" = "$A" ] || fail 'LRU did not select a'
state_inode_after=$(file_inode "$case_two/state/rotation.json")
[ "$state_inode_before" != "$state_inode_after" ] || fail 'atomic state replacement preserved the old inode'
jq -e '.reason == "oldest-last-attempt" and .previous_last_attempt == "2026-09-01"' \
  "$case_two/lane/rotation.json" >/dev/null || fail 'LRU evidence is incorrect'

# 3. Equal attempts retain configured list order.
case_three="$TEST_TMP/case-three"
mkdir -p "$case_three/state"
printf '%s\n' '{"schema_version":1,"targets":{"a":{"last_attempt":"2026-09-01","last_result":"run"},"b":{"last_attempt":"2026-09-01","last_result":"run"}}}' > "$case_three/state/rotation.json"
run_rotation "$case_three/lane" "$case_three/state/rotation.json" \
  "b=$B a=$A" 2026-09-05 >/dev/null 2> "$case_three/stderr"
[ "$(<"$case_three/lane/stub-output")" = "$B" ] || fail 'tie did not preserve list order'

# 4. A never-attempted target wins, then older recorded nights resume in order.
case_four="$TEST_TMP/case-four"
mkdir -p "$case_four/state"
printf '%s\n' '{"schema_version":1,"targets":{"a":{"last_attempt":"2026-09-01","last_result":"run"},"b":{"last_attempt":"2026-09-02","last_result":"run"}}}' > "$case_four/state/rotation.json"
run_rotation "$case_four/lane-1" "$case_four/state/rotation.json" \
  "a=$A b=$B c=$C" 2026-09-05 >/dev/null 2> "$case_four/stderr-1"
[ "$(<"$case_four/lane-1/stub-output")" = "$C" ] || fail 'never-attempted c was not selected'
run_rotation "$case_four/lane-2" "$case_four/state/rotation.json" \
  "a=$A b=$B c=$C" 2026-09-06 >/dev/null 2> "$case_four/stderr-2"
[ "$(<"$case_four/lane-2/stub-output")" = "$A" ] || fail 'a was not selected second'
run_rotation "$case_four/lane-3" "$case_four/state/rotation.json" \
  "a=$A b=$B c=$C" 2026-09-07 >/dev/null 2> "$case_four/stderr-3"
[ "$(<"$case_four/lane-3/stub-output")" = "$B" ] || fail 'b was not selected third'

# 5. A missing selected mirror burns its turn and never invokes the lane.
case_five="$TEST_TMP/case-five"
mkdir -p "$case_five/state"
missing_path="$MIRRORS/missing"
if run_rotation "$case_five/lane" "$case_five/state/rotation.json" \
  "missing=$missing_path a=$A" 2026-09-05 > "$case_five/stdout" 2> "$case_five/stderr"; then
  fail 'missing mirror returned success'
fi
[ ! -e "$case_five/lane/stub-output" ] || fail 'missing mirror invoked the lane stub'
jq -e '.targets.missing.last_attempt == "2026-09-05" and .targets.missing.last_result == "missing-mirror"' \
  "$case_five/state/rotation.json" >/dev/null || fail 'missing mirror state was not recorded'
jq -e '.selected == "missing" and .refresh == "skipped"' \
  "$case_five/lane/rotation.json" >/dev/null || fail 'missing mirror evidence was not written'
assert_contains 'rotation: NOT-RUN reason=missing-mirror target=missing' "$case_five/stderr"

# 6. Malformed target entries fail before an existing state file is touched.
case_six="$TEST_TMP/case-six"
mkdir -p "$case_six/state"
printf '%s\n' '{"schema_version":1,"targets":{"a":{"last_attempt":"2026-09-01","last_result":"run"}}}' > "$case_six/state/rotation.json"
state_sha_before=$(shasum -a 256 "$case_six/state/rotation.json" | awk '{print $1}')
if run_rotation "$case_six/lane-name" "$case_six/state/rotation.json" \
  "wrong=$A" 2026-09-05 > "$case_six/stdout-name" 2> "$case_six/stderr-name"; then
  fail 'name mismatch was accepted'
fi
state_sha_after=$(shasum -a 256 "$case_six/state/rotation.json" | awk '{print $1}')
[ "$state_sha_before" = "$state_sha_after" ] || fail 'name mismatch touched state'
assert_contains 'rotation: invalid REVIEW_ROTATION_TARGETS entry:' "$case_six/stderr-name"
if run_rotation "$case_six/lane-relative" "$case_six/state/rotation.json" \
  'relative=relative' 2026-09-05 > "$case_six/stdout-relative" 2> "$case_six/stderr-relative"; then
  fail 'relative target path was accepted'
fi
state_sha_after=$(shasum -a 256 "$case_six/state/rotation.json" | awk '{print $1}')
[ "$state_sha_before" = "$state_sha_after" ] || fail 'relative target touched state'
if run_rotation "$case_six/lane-empty-name" "$case_six/state/rotation.json" \
  "=$A" 2026-09-05 > "$case_six/stdout-empty-name" 2> "$case_six/stderr-empty-name"; then
  fail 'empty target name was accepted'
else
  empty_name_rc=$?
fi
[ "$empty_name_rc" -eq 1 ] || fail "empty target name returned $empty_name_rc, not 1"
state_sha_after=$(shasum -a 256 "$case_six/state/rotation.json" | awk '{print $1}')
[ "$state_sha_before" = "$state_sha_after" ] || fail 'empty target name touched state'
if run_rotation "$case_six/lane-empty-path" "$case_six/state/rotation.json" \
  'a=' 2026-09-05 > "$case_six/stdout-empty-path" 2> "$case_six/stderr-empty-path"; then
  fail 'empty target path was accepted'
else
  empty_path_rc=$?
fi
[ "$empty_path_rc" -eq 1 ] || fail "empty target path returned $empty_path_rc, not 1"
state_sha_after=$(shasum -a 256 "$case_six/state/rotation.json" | awk '{print $1}')
[ "$state_sha_before" = "$state_sha_after" ] || fail 'empty target path touched state'
if run_rotation "$case_six/lane-duplicate" "$case_six/state/rotation.json" \
  'a=/missing-one/a a=/missing-two/a' 2026-09-05 > "$case_six/stdout-duplicate" 2> "$case_six/stderr-duplicate"; then
  fail 'duplicate target name was accepted'
else
  duplicate_rc=$?
fi
[ "$duplicate_rc" -eq 1 ] || fail "duplicate target name returned $duplicate_rc, not 1"
state_sha_after=$(shasum -a 256 "$case_six/state/rotation.json" | awk '{print $1}')
[ "$state_sha_before" = "$state_sha_after" ] || fail 'duplicate target name touched state'

# 7. State replacement leaves only parseable final JSON in its directory.
case_seven="$TEST_TMP/case-seven"
mkdir -p "$case_seven/state"
printf '%s\n' '{"schema_version":1,"targets":{"a":{"last_attempt":"2026-09-01","last_result":"run"}}}' > "$case_seven/state/rotation.json"
state_inode_before=$(file_inode "$case_seven/state/rotation.json")
run_rotation "$case_seven/lane" "$case_seven/state/rotation.json" \
  "a=$A" 2026-09-05 >/dev/null 2> "$case_seven/stderr"
jq -e . "$case_seven/state/rotation.json" >/dev/null || fail 'atomic state is not parseable JSON'
state_inode_after=$(file_inode "$case_seven/state/rotation.json")
[ "$state_inode_before" != "$state_inode_after" ] || fail 'atomic state write preserved the old inode'
[ "$(find "$case_seven/state" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d '[:space:]')" -eq 1 ] ||
  fail 'atomic state write left a temporary file'

# 7b. A failed jq update preserves bytes and removes its state temp file.
mkdir -p "$case_seven/jq-shim"
cp "$case_seven/state/rotation.json" "$case_seven/state-before-failed-update.json"
real_jq=$(command -v jq)
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'for jq_arg in "$@"; do' \
  '  case "$jq_arg" in' \
  "    *'.targets[\$name]'*) printf '{\"schema'; exit 1 ;;" \
  '  esac' \
  'done' \
  'exec "$REAL_JQ" "$@"' \
  > "$case_seven/jq-shim/jq"
chmod +x "$case_seven/jq-shim/jq"
if PATH="$case_seven/jq-shim:$PATH" REAL_JQ="$real_jq" \
  run_rotation "$case_seven/lane-failed-update" "$case_seven/state/rotation.json" \
    "a=$A" 2026-09-06 >/dev/null 2> "$case_seven/stderr-failed-update"; then
  fail 'failed jq state update returned success'
fi
cmp -s "$case_seven/state-before-failed-update.json" "$case_seven/state/rotation.json" ||
  fail 'failed jq update changed state bytes'
[ "$(find "$case_seven/state" -name '.review-rotation-state.*' -type f | wc -l | tr -d '[:space:]')" -eq 0 ] ||
  fail 'failed jq update left a state temporary file'

# 8. Refresh can be disabled; a failed enabled refresh still hands off.
case_eight="$TEST_TMP/case-eight"
mkdir -p "$case_eight/state"
run_rotation "$case_eight/lane-disabled" "$case_eight/state/disabled.json" \
  "a=$A" 2026-09-05 0 >/dev/null 2> "$case_eight/stderr-disabled"
jq -e '.refresh == "skipped"' "$case_eight/lane-disabled/rotation.json" >/dev/null ||
  fail 'disabled refresh was not recorded as skipped'
run_rotation "$case_eight/lane-enabled" "$case_eight/state/enabled.json" \
  "a=$A" 2026-09-05 1 >/dev/null 2> "$case_eight/stderr-enabled"
[ "$(<"$case_eight/lane-enabled/stub-output")" = "$A" ] || fail 'failed refresh blocked lane handoff'
jq -e '.refresh == "failed"' "$case_eight/lane-enabled/rotation.json" >/dev/null ||
  fail 'failed refresh was not recorded in evidence'
jq -e '.targets.a.last_result == "refresh-failed"' "$case_eight/state/enabled.json" >/dev/null ||
  fail 'failed refresh was not recorded in state'
assert_contains 'rotation: refresh failed target=a' "$case_eight/stderr-enabled"

# 9. A successful lane may remove evidence, but the rotation record survives at the lane root.
case_nine="$TEST_TMP/case-nine"
mkdir -p "$case_nine/state" "$case_nine/lane/evidence"
printf '%s\n' old > "$case_nine/lane/evidence/disposable"
run_rotation "$case_nine/lane" "$case_nine/state/rotation.json" \
  "a=$A" 2026-09-05 0 "$SURVIVAL_RUN" >/dev/null 2> "$case_nine/stderr"
[ ! -e "$case_nine/lane/evidence" ] || fail 'survival stub did not wipe evidence'
jq -e '.selected == "a" and .night_id == "2026-09-05"' "$case_nine/lane/rotation.json" >/dev/null ||
  fail 'root rotation record did not survive the lane handoff'

# 10. The exec handoff preserves both REVIEW_TARGET_SOURCE and the lane exit code.
case_ten="$TEST_TMP/case-ten"
mkdir -p "$case_ten/state"
if run_rotation "$case_ten/lane" "$case_ten/state/rotation.json" \
  "a=$A" 2026-09-05 0 "$HANDOFF_RUN" >/dev/null 2> "$case_ten/stderr"; then
  fail 'handoff exit 17 was converted to success'
else
  handoff_rc=$?
fi
[ "$handoff_rc" -eq 17 ] || fail "handoff exit code was $handoff_rc, not 17"
[ "$(<"$case_ten/lane/stub-output")" = "$A" ] || fail 'handoff lost REVIEW_TARGET_SOURCE'

# 11. lane-failed is no longer an accepted persisted result.
case_eleven="$TEST_TMP/case-eleven"
mkdir -p "$case_eleven/state"
printf '%s\n' '{"schema_version":1,"targets":{"a":{"last_attempt":"2026-09-01","last_result":"lane-failed"}}}' > "$case_eleven/state/rotation.json"
state_sha_before=$(shasum -a 256 "$case_eleven/state/rotation.json" | awk '{print $1}')
if run_rotation "$case_eleven/lane" "$case_eleven/state/rotation.json" \
  "a=$A" 2026-09-05 >/dev/null 2> "$case_eleven/stderr"; then
  fail 'lane-failed state was accepted'
fi
state_sha_after=$(shasum -a 256 "$case_eleven/state/rotation.json" | awk '{print $1}')
[ "$state_sha_before" = "$state_sha_after" ] || fail 'invalid state was changed'

# 12. Lexicographic nights are locale-independent even with LC_ALL unset.
case_twelve="$TEST_TMP/case-twelve"
mkdir -p "$case_twelve/state" "$case_twelve/lane"
printf '%s\n' '{"schema_version":1,"targets":{"a":{"last_attempt":"2026-09-10","last_result":"run"},"b":{"last_attempt":"2026-09-01","last_result":"run"}}}' > "$case_twelve/state/rotation.json"
env -u LC_ALL LANG=en_US.UTF-8 \
  LANE_DIR="$case_twelve/lane" \
  NIGHT_ID=2026-09-11 \
  REVIEW_ROTATION_STATE="$case_twelve/state/rotation.json" \
  REVIEW_ROTATION_TARGETS="a=$A b=$B" \
  REVIEW_ROTATION_REFRESH=0 \
  REVIEW_ROTATION_RUN="$STUB_RUN" \
  STUB_OUTPUT="$case_twelve/lane/stub-output" \
  /bin/bash "$ROTATE_SH" >/dev/null 2> "$case_twelve/stderr"
[ "$(<"$case_twelve/lane/stub-output")" = "$B" ] || fail 'locale changed lexicographic LRU order'

# 13. A bare repository is a missing mirror and never reaches the review lane.
case_thirteen="$TEST_TMP/case-thirteen"
mkdir -p "$case_thirteen/state"
git -c core.hooksPath=/dev/null init --bare -q "$MIRRORS/bare-c"
if run_rotation "$case_thirteen/lane" "$case_thirteen/state/rotation.json" \
  "bare-c=$MIRRORS/bare-c" 2026-09-12 > "$case_thirteen/stdout" 2> "$case_thirteen/stderr"; then
  fail 'bare mirror returned success'
else
  bare_rc=$?
fi
[ "$bare_rc" -eq 1 ] || fail "bare mirror returned $bare_rc, not 1"
assert_contains 'NOT-RUN reason=missing-mirror target=bare-c' "$case_thirteen/stderr"
jq -e '.targets["bare-c"].last_result == "missing-mirror" and .targets["bare-c"].last_attempt == "2026-09-12"' \
  "$case_thirteen/state/rotation.json" >/dev/null || fail 'bare mirror state was not recorded'
jq -e '.selected == "bare-c" and .night_id == "2026-09-12" and .refresh == "skipped"' \
  "$case_thirteen/lane/rotation.json" >/dev/null || fail 'bare mirror evidence is incorrect'
[ ! -e "$case_thirteen/lane/stub-output" ] || fail 'bare mirror invoked the lane stub'

printf 'test_lane_review_rotation: PASS\n'
