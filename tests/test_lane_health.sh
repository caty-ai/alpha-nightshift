#!/bin/bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
# shellcheck source=tests/helpers.sh
# shellcheck disable=SC1091
. "$TEST_DIR/helpers.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-health.XXXXXX")
TEST_TMP=$(cd -P "$TEST_TMP" && pwd -P)
trap 'rm -rf "$TEST_TMP"' EXIT
HEALTH_SH="$ROOT/lanes/health/run.sh"
TEST_NIGHT=2026-09-05
mkdir -p "$TEST_TMP/repos" "$TEST_TMP/home"

init_source() {
  local path="$TEST_TMP/repos/$1"
  mkdir -p "$path"
  git -C "$path" init -q
  git -C "$path" config user.name 'Health Test'
  git -C "$path" config user.email 'health@example.invalid'
  printf '%s\n' "$1" > "$path/tracked.txt"
  git -C "$path" add tracked.txt
  git -C "$path" -c core.hooksPath=/dev/null commit -q -m 'Initialize fixture'
  printf '%s\n' "$path"
}

commit_source() {
  git -C "$1" add -A
  git -C "$1" -c core.hooksPath=/dev/null commit -q -m 'Set fixture runners'
}

run_health() {
  local lane=$1 expected_rc=$2 rc=0
  shift 2
  mkdir -p "$lane"
  env -i PATH="$PATH" HOME="$TEST_TMP/home" TMPDIR="$TEST_TMP" LANG=C TERM=dumb \
    NIGHT_ID="$TEST_NIGHT" LANE_DIR="$lane" GIT_CEILING_DIRECTORIES="$TEST_TMP" \
    "$@" /bin/bash "$HEALTH_SH" > "$lane/stdout" 2> "$lane/stderr" || rc=$?
  [ "$rc" -eq "$expected_rc" ] || {
    cat "$lane/stdout" "$lane/stderr" >&2
    fail "$lane returned $rc, expected $expected_rc"
  }
  assert_file_exists "$lane/findings.jsonl"
  jq -e 'keys == ["commands","commit","elapsed_sec","failures","night_id","reason","refresh","repo","result","runner","selection","source","suites"] and (.elapsed_sec >= 0) and (.commands | type == "array")' \
    "$lane/health.json" >/dev/null || fail "$lane has invalid health.json"
}

assert_result() {
  local lane=$1 result=$2 suites=$3 failures=$4
  jq -e --arg result "$result" --argjson suites "$suites" --argjson failures "$failures" \
    '.result == $result and .suites == $suites and .failures == $failures' \
    "$lane/health.json" >/dev/null || fail "$lane has incorrect result/counts"
  [ "$(wc -l < "$lane/findings.jsonl" | tr -d '[:space:]')" -eq "$failures" ] || fail "$lane findings count"
}

assert_no_input() {
  assert_result "$1" no-input 0 0
  assert_contains "health: NO-INPUT reason=$2" "$1/stdout"
  jq -e --arg reason "$2" '.reason == $reason' "$1/health.json" >/dev/null || fail 'incorrect NO-INPUT reason'
}

# 1. Detection prioritizes make, then tests/run.sh, then tests/run_tests.sh.
source_repo=$(init_source detection)
mkdir -p "$source_repo/tests"
printf 'test:\n\t@touch made-marker; exit 0\n' > "$source_repo/Makefile"
printf 'touch run-marker\n' > "$source_repo/tests/run.sh"
printf 'touch run-tests-marker\n' > "$source_repo/tests/run_tests.sh"
commit_source "$source_repo"
for runner in make-test tests-run tests-run_tests; do
  lane="$TEST_TMP/detection-$runner"
  run_health "$lane" 0 "HEALTH_TARGET_SOURCE=$source_repo"
  assert_result "$lane" ran 1 0
  jq -e --arg runner "$runner" --arg source "$source_repo" \
    '.runner == $runner and .selection == "explicit" and .source == $source and .repo == "detection" and (.commit | length > 0) and (.commands[0].exit_code == 0)' \
    "$lane/health.json" >/dev/null || fail "wrong detection for $runner"
  assert_contains "health: runner=$runner" "$lane/stdout"
  assert_contains 'health: target=detection ' "$lane/stdout"
  assert_contains 'health: 0/1 suites failed at commit ' "$lane/stdout"
  case "$runner" in
    make-test)
      assert_file_exists "$lane/work/health-checkout/made-marker"
      [ ! -e "$lane/work/health-checkout/run-marker" ] || fail 'make ran fallback'
      [ ! -e "$lane/work/health-checkout/run-tests-marker" ] || fail 'make ran second fallback'
      rm "$source_repo/Makefile"; commit_source "$source_repo" ;;
    tests-run)
      assert_file_exists "$lane/work/health-checkout/run-marker"
      [ ! -e "$lane/work/health-checkout/run-tests-marker" ] || fail 'run.sh ran fallback'
      rm "$source_repo/tests/run.sh"; commit_source "$source_repo" ;;
    tests-run_tests) assert_file_exists "$lane/work/health-checkout/run-tests-marker" ;;
  esac
done

# 2. Missing runners are explicit NO-INPUT, with empty findings.
empty_repo=$(init_source empty)
lane="$TEST_TMP/no-runner"
run_health "$lane" 3 "HEALTH_TARGET_SOURCE=$empty_repo"
assert_no_input "$lane" no-test-runner
jq -e '.runner == null' "$lane/health.json" >/dev/null || fail 'missing runner was invented'

# 3. Independent failures retain the exact ledger schema and hashed evidence.
suites_repo=$(init_source suite-fixture)
mkdir -p "$suites_repo/tests"
printf 'printf "pass-suite\\n"; exit 0\n' > "$suites_repo/tests/pass.test.sh"
printf 'printf "first-suite-stderr\\n" >&2; exit 1\n' > "$suites_repo/tests/first.test.sh"
printf 'printf "second-suite-stderr\\n" >&2; exit 2\n' > "$suites_repo/tests/second.test.sh"
commit_source "$suites_repo"
lane="$TEST_TMP/suites"
run_health "$lane" 0 "HEALTH_TARGET_SOURCE=$suites_repo" 'HEALTH_SUITE_GLOB=tests/*.test.sh'
assert_result "$lane" ran 3 2
assert_contains 'health: runner=suite-glob' "$lane/stdout"
assert_contains 'health: suite=tests/first.test.sh exit=1 ' "$lane/stdout"
assert_contains 'health: 2/3 suites failed at commit ' "$lane/stdout"
jq -es --arg night "$TEST_NIGHT" '
  length == 2 and ([.[].id] | unique | length == 2) and
  all(.[]; keys == ["confirm_cost","date","evidence","id","kind","repo","symptom","target"] and
    .repo == "suite-fixture" and .kind == "test-failure" and .confirm_cost == "3分" and .date == $night and
    (.id | startswith("health-suite-fixture-")) and (.evidence | length == 1))
' "$lane/findings.jsonl" >/dev/null || fail 'finding schema/identity mismatch'
for name in first second; do
  log=$(jq -r --arg target "tests/$name.test.sh" 'select(.target == $target) | .evidence[0]' "$lane/findings.jsonl")
  assert_file_exists "$lane/$log"
  assert_contains "$name-suite-stderr" "$lane/$log"
done
log_count=0
for log in "$lane"/evidence/*.log; do
  log_count=$((log_count + 1))
  relative="evidence/$(basename "$log")"
  sha=$(shasum -a 256 "$log" | awk '{print $1}')
  bytes=$(wc -c < "$log" | tr -d '[:space:]')
  jq -e --arg file "$relative" --arg sha "$sha" --argjson bytes "$bytes" \
    '.files[$file] == {sha256:$sha,bytes:$bytes}' "$lane/evidence/manifest.json" >/dev/null || fail "bad manifest entry $relative"
done
jq -e --argjson count "$log_count" '.files | length == $count' "$lane/evidence/manifest.json" >/dev/null || fail 'manifest omitted or invented logs'
# Rerunning the same lane replaces findings instead of duplicating them.
run_health "$lane" 0 "HEALTH_TARGET_SOURCE=$suites_repo" 'HEALTH_SUITE_GLOB=tests/*.test.sh'
assert_result "$lane" ran 3 2
lane="$TEST_TMP/explicit-command"
run_health "$lane" 0 "HEALTH_TARGET_SOURCE=$empty_repo" 'HEALTH_TEST_CMD=exit 7'
assert_result "$lane" ran 1 1
assert_contains 'health: runner=explicit-cmd cmd=exit 7' "$lane/stdout"
jq -e '.runner == "explicit-cmd" and .commands[0].exit_code == 7' "$lane/health.json" >/dev/null || fail 'explicit command status'
jq -e '.symptom | contains("exited 7")' "$lane/findings.jsonl" >/dev/null || fail 'explicit failure symptom'

# 4. Commands only modify the committed clone, including with dirty source files.
mutation_repo=$(init_source mutation)
mkdir -p "$mutation_repo/tests"
printf 'touch pwned.txt\n' > "$mutation_repo/tests/run.sh"
commit_source "$mutation_repo"
printf 'uncommitted\n' > "$mutation_repo/dirty.txt"
status_before=$(GIT_OPTIONAL_LOCKS=0 git -C "$mutation_repo" status --porcelain)
tree_before=$(tar -cf - -C "$mutation_repo" . | shasum -a 256 | awk '{print $1}')
lane="$TEST_TMP/immutable-source"
run_health "$lane" 0 "HEALTH_TARGET_SOURCE=$mutation_repo"
assert_result "$lane" ran 1 0
assert_contains 'health: runner=tests-run' "$lane/stdout"
assert_file_exists "$lane/work/health-checkout/pwned.txt"
[ ! -e "$mutation_repo/pwned.txt" ] || fail 'source was modified'
[ ! -e "$lane/work/health-checkout/dirty.txt" ] || fail 'clone included uncommitted files'
status_after=$(GIT_OPTIONAL_LOCKS=0 git -C "$mutation_repo" status --porcelain)
tree_after=$(tar -cf - -C "$mutation_repo" . | shasum -a 256 | awk '{print $1}')
[ "$status_before" = "$status_after" ] || fail 'source status changed'
[ "$tree_before" = "$tree_after" ] || fail 'source tree bytes changed'

# 5. Rotation evidence and optional state must belong to this night; both are read-only.
# refresh=skipped is also what rotate.sh writes for REVIEW_ROTATION_REFRESH=0,
# so it must run normally; missing-mirror comes from state or from the path.
bare_mirror="$TEST_TMP/bare-mirror"
git -c core.hooksPath=/dev/null init --bare -q "$bare_mirror"
for scenario in valid stale skipped state-mismatch state-missing-mirror bare-path absent-path missing invalid; do
  parent="$TEST_TMP/rotation-$scenario"
  mkdir -p "$parent/lane_1"
  evidence_night=$TEST_NIGHT
  state_night=$TEST_NIGHT
  state_result=run
  refresh=ok
  evidence_path=$source_repo
  case "$scenario" in
    stale) evidence_night=2026-09-04 ;;
    skipped) refresh=skipped ;;
    state-mismatch) state_night=2026-09-04 ;;
    state-missing-mirror) state_result=missing-mirror; refresh=skipped ;;
    bare-path) evidence_path=$bare_mirror; refresh=skipped ;;
    absent-path) evidence_path="$TEST_TMP/does-not-exist"; refresh=skipped ;;
  esac
  jq -n --arg night "$evidence_night" --arg source "$evidence_path" --arg refresh "$refresh" \
    '{night_id:$night,selected:"detection",path:$source,refresh:$refresh}' > "$parent/lane_1/rotation.json"
  jq -n --arg night "$state_night" --arg result "$state_result" \
    '{schema_version:1,targets:{detection:{last_attempt:$night,last_result:$result}}}' > "$parent/state.json"
  cp "$parent/state.json" "$parent/state-before.json"
  case "$scenario" in
    missing) rm "$parent/lane_1/rotation.json" ;;
    invalid) printf '{invalid\n' > "$parent/lane_1/rotation.json" ;;
  esac
  lane="$parent/lane_2"
  expected_rc=3
  case "$scenario" in valid|skipped) expected_rc=0 ;; esac
  run_health "$lane" "$expected_rc" 'HEALTH_ROTATION_LANE=lane_1' "HEALTH_ROTATION_STATE=$parent/state.json"
  cmp -s "$parent/state.json" "$parent/state-before.json" || fail 'health modified rotation state'
  case "$scenario" in
    valid|skipped)
      assert_result "$lane" ran 1 0
      jq -e --arg refresh "$refresh" '.selection == "rotation" and .repo == "detection" and .runner == "tests-run_tests" and .refresh == $refresh' "$lane/health.json" >/dev/null || fail "rotation handoff fields ($scenario)"
      assert_contains 'selection=rotation' "$lane/stdout" ;;
    state-mismatch) assert_no_input "$lane" rotation-state-mismatch ;;
    state-missing-mirror|bare-path|absent-path)
      assert_no_input "$lane" rotation-missing-mirror
      [ ! -e "$lane/work/health-checkout" ] || fail "missing mirror was cloned ($scenario)" ;;
    *) assert_no_input "$lane" rotation-evidence-missing ;;
  esac
done

# 5b. Rotation selection works without a state file (state is optional).
parent="$TEST_TMP/rotation-no-state"
mkdir -p "$parent/lane_1"
jq -n --arg night "$TEST_NIGHT" --arg source "$source_repo" \
  '{night_id:$night,selected:"detection",path:$source,refresh:"skipped"}' > "$parent/lane_1/rotation.json"
lane="$parent/lane_2"
run_health "$lane" 0 'HEALTH_ROTATION_LANE=lane_1'
assert_result "$lane" ran 1 0
jq -e '.selection == "rotation" and .repo == "detection" and .refresh == "skipped"' "$lane/health.json" >/dev/null || fail 'rotation without state'

# 5c. A very long command must still run (evidence filename is capped) and a
# finding is emitted only for a command that really ran.
long_cmd="exit 9 # $(printf 'x%.0s' $(seq 1 300))"
lane="$TEST_TMP/long-command"
run_health "$lane" 0 "HEALTH_TARGET_SOURCE=$empty_repo" "HEALTH_TEST_CMD=$long_cmd"
assert_result "$lane" ran 1 1
long_log=$(jq -r '.commands[0].log' "$lane/health.json")
assert_file_exists "$lane/$long_log"
[ "${#long_log}" -lt 160 ] || fail "evidence log name not capped: ${#long_log}"
jq -e --arg log "$long_log" '.evidence[0] == $log' "$lane/findings.jsonl" >/dev/null || fail 'long-command finding evidence'
jq -e --arg log "$long_log" '.files[$log].bytes >= 0' "$lane/evidence/manifest.json" >/dev/null || fail 'long-command log missing from manifest'

# 6. A timebox kills the background child, records evidence, and emits no finding.
lane="$TEST_TMP/timebox"
run_health "$lane" 1 "HEALTH_TARGET_SOURCE=$empty_repo" HEALTH_TIMEBOX_SEC=2 \
  'HEALTH_TEST_CMD=sleep 300 & echo $! > orphan.pid; sleep 300'
assert_result "$lane" timeout 1 0
assert_contains 'health: TIMEBOX' "$lane/stdout"
jq -e '.runner == "explicit-cmd" and .elapsed_sec >= 2 and .commands[0].elapsed_sec >= 2' "$lane/health.json" >/dev/null || fail 'timeout timing/status'
log=$(jq -r '.commands[0].log' "$lane/health.json")
assert_contains 'health: timed out after 2s' "$lane/$log"
assert_file_exists "$lane/work/health-checkout/orphan.pid"
orphan_pid=$(cat "$lane/work/health-checkout/orphan.pid")
if kill -0 "$orphan_pid" 2>/dev/null; then
  kill -KILL "$orphan_pid" 2>/dev/null || true
  fail 'timeout left its descendant alive'
fi

# 7. Bare sources fail validation before a clone is created.
bare="$TEST_TMP/repos/bare"
git init --bare -q "$bare"
lane="$TEST_TMP/bare-source"
run_health "$lane" 1 "HEALTH_TARGET_SOURCE=$bare"
assert_result "$lane" error 0 0
assert_contains 'health: invalid source' "$lane/stderr"
[ ! -e "$lane/work/health-checkout" ] || fail 'bare source was cloned'

# A previous clone (or a source beneath it) must not be deleted during reset.
for overlap in exact nested; do
  lane="$TEST_TMP/source-overlap-$overlap"
  overlap_source="$lane/work/health-checkout"
  [ "$overlap" != nested ] || overlap_source="$overlap_source/source"
  mkdir -p "$(dirname "$overlap_source")"
  git clone --quiet --no-hardlinks "$empty_repo" "$overlap_source"
  source_sha_before=$(tar -cf - -C "$overlap_source" . | shasum -a 256 | awk '{print $1}')
  run_health "$lane" 1 "HEALTH_TARGET_SOURCE=$overlap_source" 'HEALTH_TEST_CMD=exit 0'
  assert_result "$lane" error 0 0
  assert_contains 'health: ' "$lane/stderr"
  assert_file_exists "$overlap_source/tracked.txt"
  source_sha_after=$(tar -cf - -C "$overlap_source" . | shasum -a 256 | awk '{print $1}')
  [ "$source_sha_before" = "$source_sha_after" ] || fail "$overlap source overlap changed source bytes"
done

# Configuration errors and empty globs remain observable.
lane="$TEST_TMP/no-matching-suites"
run_health "$lane" 3 "HEALTH_TARGET_SOURCE=$empty_repo" 'HEALTH_SUITE_GLOB=tests/*.test.sh'
assert_no_input "$lane" no-suites-matched
for scenario in no-target both-runners invalid-timebox missing-night relative-source invalid-lane; do
  lane="$TEST_TMP/config-$scenario"
  case "$scenario" in
    no-target) run_health "$lane" 1 ;;
    both-runners) run_health "$lane" 1 "HEALTH_TARGET_SOURCE=$empty_repo" 'HEALTH_TEST_CMD=true' 'HEALTH_SUITE_GLOB=tests/*' ;;
    invalid-timebox) run_health "$lane" 1 "HEALTH_TARGET_SOURCE=$empty_repo" HEALTH_TIMEBOX_SEC=0 ;;
    missing-night) run_health "$lane" 1 "HEALTH_TARGET_SOURCE=$empty_repo" NIGHT_ID= ;;
    relative-source) run_health "$lane" 1 HEALTH_TARGET_SOURCE=relative ;;
    invalid-lane) run_health "$lane" 1 HEALTH_ROTATION_LANE=../lane_1 ;;
  esac
  assert_result "$lane" error 0 0
  assert_contains 'health: ' "$lane/stderr"
done

# Explicit selection wins even when an unused rotation setting is invalid.
lane="$TEST_TMP/explicit-precedence"
run_health "$lane" 0 "HEALTH_TARGET_SOURCE=$empty_repo" \
  HEALTH_ROTATION_LANE=../invalid "HEALTH_ROTATION_STATE=$TEST_TMP/missing-state" 'HEALTH_TEST_CMD=exit 0'
assert_result "$lane" ran 1 0
jq -e '.selection == "explicit" and .repo == "empty"' "$lane/health.json" >/dev/null || fail 'rotation overrode explicit source'
assert_contains 'selection=explicit' "$lane/stdout"

# Glob expansion preserves spaces in both the repository and suite paths.
space_repo=$(init_source 'space fixture')
mkdir -p "$space_repo/tests with spaces"
printf 'printf "space-suite-stderr\\n" >&2; exit 2\n' > "$space_repo/tests with spaces/a suite.test.sh"
commit_source "$space_repo"
lane="$TEST_TMP/space-glob"
run_health "$lane" 0 "HEALTH_TARGET_SOURCE=$space_repo" 'HEALTH_SUITE_GLOB=tests with spaces/*.test.sh'
assert_result "$lane" ran 1 1
jq -e '.runner == "suite-glob" and .commands[0].target == "tests with spaces/a suite.test.sh"' "$lane/health.json" >/dev/null || fail 'glob split a suite path'
assert_contains 'health: suite=tests with spaces/a suite.test.sh exit=2 ' "$lane/stdout"

# Missing LANE_DIR cannot write artifacts, but still diagnoses the configuration.
missing_lane_rc=0
env -i PATH="$PATH" HOME="$TEST_TMP/home" NIGHT_ID="$TEST_NIGHT" \
  /bin/bash "$HEALTH_SH" > "$TEST_TMP/missing-lane.stdout" 2> "$TEST_TMP/missing-lane.stderr" || missing_lane_rc=$?
[ "$missing_lane_rc" -eq 1 ] || fail 'missing LANE_DIR did not return 1'
assert_contains 'health: ' "$TEST_TMP/missing-lane.stderr"
assert_contains 'LANE_DIR' "$TEST_TMP/missing-lane.stderr"

printf 'test_lane_health: PASS\n'
