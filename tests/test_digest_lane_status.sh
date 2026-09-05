#!/bin/bash
# shellcheck disable=SC1091,SC2016
set -euo pipefail
umask 022

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
. "$TEST_DIR/helpers.sh"
. "$ROOT/lib/common.sh"
. "$ROOT/lib/digest.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-lane-status.XXXXXX")
cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT
NIGHT_ID=$(date -v-8H '+%F' 2>/dev/null || date -d '-8 hours' '+%F')
FIXTURES="$TEST_DIR/fixtures/lane-status"

process_ok_bin="$TEST_TMP/process-ok-bin"
mkdir -p "$process_ok_bin"
for process_command in ps pgrep; do
  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'exit 1'
  } > "$process_ok_bin/$process_command"
  chmod 0700 "$process_ok_bin/$process_command"
done

write_digest_config() {
  config_path=$1
  state_path=$2
  lane_status_cmd=${3-__UNSET__}
  lane_status_timeout=${4:-2}
  lane_status_max_rows=${5:-10}
  {
    printf 'NIGHTSHIFT_STATE_DIR=%q\n' "$state_path"
    printf '%s\n' "LANE_CMD_1=':'" "LANE_HOME_LINKS=''"
    if [ "$lane_status_cmd" != __UNSET__ ]; then
      printf 'LANE_STATUS_CMD=%q\n' "$lane_status_cmd"
    fi
    printf 'LANE_STATUS_TIMEOUT_SEC=%q\n' "$lane_status_timeout"
    printf 'LANE_STATUS_MAX_ROWS=%q\n' "$lane_status_max_rows"
  } > "$config_path"
}

write_fixture_reporter() {
  reporter_path=$1
  fixture_path=$2
  stderr_text=${3-}
  {
    printf '%s\n' '#!/bin/bash'
    if [ -n "$stderr_text" ]; then
      printf 'printf '\''%%s\\n'\'' %q >&2\n' "$stderr_text"
    fi
    printf 'exec /bin/cat %q\n' "$fixture_path"
  } > "$reporter_path"
  chmod 0700 "$reporter_path"
}

write_inline_reporter() {
  reporter_path=$1
  json_text=$2
  {
    printf '%s\n' '#!/bin/bash'
    printf 'printf '\''%%s\\n'\'' %q\n' "$json_text"
  } > "$reporter_path"
  chmod 0700 "$reporter_path"
}

run_digest() {
  config_path=$1
  PATH="$process_ok_bin:$PATH" NIGHTSHIFT_CONFIG="$config_path" \
    /bin/bash "$ROOT/bin/nightshift-dispatch" digest >/dev/null
}

digest_path_for() {
  printf '%s/digests/%s.md\n' "$1" "$NIGHT_ID"
}

night_dir_for() {
  printf '%s/digests/%s\n' "$1" "$NIGHT_ID"
}

assert_mode() {
  expected_mode=$1
  file=$2
  if actual_mode=$(stat -f '%Lp' "$file" 2>/dev/null); then
    :
  elif actual_mode=$(stat -c '%a' "$file" 2>/dev/null); then
    :
  else
    fail "[mode mutation] could not inspect mode for $file"
  fi
  [ "$actual_mode" = "$expected_mode" ] ||
    fail "[mode mutation] expected mode $expected_mode for $file, got $actual_mode"
}

assert_no_run_dirs() {
  night_dir=$1
  set -- "$night_dir"/.run.*
  [ ! -e "$1" ] || fail "scratch run directory remained under $night_dir"
}

assert_digest_written_shape() {
  ledger=$1
  jq -e --arg night_id "$NIGHT_ID" '
    select(.night_id == $night_id and .type == "digest_written")
    | keys == ["dead_man", "mode", "night_id", "path", "ts", "type"]
  ' "$ledger" >/dev/null ||
    fail 'digest_written did not retain the pre-existing exact key set'
}

assert_no_meter_error() {
  ledger=$1
  if jq -e 'select(.type == "meter_error")' "$ledger" >/dev/null; then
    fail 'lane-status runtime failure emitted a meter_error ledger row'
  fi
}

assert_before() {
  first=$1
  second=$2
  file=$3
  first_line=$(grep -n -F -- "$first" "$file" | head -n 1 | cut -d: -f1)
  second_line=$(grep -n -F -- "$second" "$file" | head -n 1 | cut -d: -f1)
  [ -n "$first_line" ] && [ -n "$second_line" ] &&
    [ "$first_line" -lt "$second_line" ] ||
    fail "expected '$first' before '$second' in $file"
}

assert_unavailable() {
  state_path=$1
  expected_reason=$2
  expect_stderr=${3:-yes}
  digest_path=$(digest_path_for "$state_path")
  night_dir=$(night_dir_for "$state_path")
  assert_contains '## Lane status' "$digest_path"
  assert_contains "lane status: unavailable ($expected_reason)" "$digest_path"
  unavailable_count=$(grep -F -c \
    "lane status: unavailable ($expected_reason)" "$digest_path")
  [ "$unavailable_count" -eq 2 ] ||
    fail "[unavailable-line mutation] expected section and footer for $expected_reason"
  [ ! -e "$night_dir/lane-status.json" ] ||
    fail "[raw-before-validation mutation] unexpected raw file for $expected_reason"
  if [ "$expect_stderr" = yes ]; then
    assert_file_exists "$night_dir/lane-status.stderr"
    assert_mode 600 "$night_dir/lane-status.stderr"
  fi
  assert_digest_written_shape "$state_path/ledger/ledger.jsonl"
  assert_no_meter_error "$state_path/ledger/ledger.jsonl"
}

happy_reporter="$TEST_TMP/happy-reporter"
write_fixture_reporter "$happy_reporter" "$FIXTURES/happy.json" 'happy diagnostic'
happy_state="$TEST_TMP/happy-state"
happy_config="$TEST_TMP/happy.conf"
write_digest_config "$happy_config" "$happy_state" "$happy_reporter"
run_digest "$happy_config"
happy_digest=$(digest_path_for "$happy_state")
happy_night_dir=$(night_dir_for "$happy_state")
happy_raw="$happy_night_dir/lane-status.json"
happy_stderr="$happy_night_dir/lane-status.stderr"
assert_contains '## Lane status' "$happy_digest"
assert_contains 'repos 3 · ci red 2 · human-owned lanes 3 · stale lanes 2 · errors 1 · truncated 1 · malformed rows 2' "$happy_digest"
assert_contains 'example/alpha · build · trunk · 2026-09-04T01:00:00Z' "$happy_digest"
assert_contains 'example/beta · verify · stable · 2026-09-04T03:00:00Z' "$happy_digest"
assert_before '- example/alpha · build' '- example/beta · verify' "$happy_digest"
assert_not_contains 'feature/demo' "$happy_digest"
assert_not_contains 'example/gamma · test' "$happy_digest"
assert_contains 'example/alpha#2 · Choose rollout · approval needed' "$happy_digest"
assert_contains 'example/alpha#12 · Update parser · no activity' "$happy_digest"
assert_contains 'example/beta#20 · Waiting for review · decision needed' "$happy_digest"
assert_before '- example/alpha#2' '- example/alpha#12' "$happy_digest"
assert_contains 'example/gamma#4 · Refresh fixtures · age threshold' "$happy_digest"
assert_contains "raw: digests/$NIGHT_ID/lane-status.json" "$happy_digest"
assert_contains 'lane status: ok (repos 3 · ci red 2 · human-owned lanes 3 · stale lanes 2)' "$happy_digest"
assert_file_exists "$happy_raw"
assert_file_exists "$happy_stderr"
cmp "$FIXTURES/happy.json" "$happy_raw" >/dev/null ||
  fail 'successful raw JSON was not byte-identical to reporter stdout'
assert_mode 600 "$happy_raw"
assert_mode 600 "$happy_stderr"
assert_mode 700 "$happy_night_dir"
assert_no_run_dirs "$happy_night_dir"
assert_contains 'happy diagnostic' "$happy_stderr"
assert_contains 'lane-status stderr: happy diagnostic' "$happy_state/logs/digest-$NIGHT_ID.log"
assert_not_contains 'happy diagnostic' "$happy_digest"
assert_digest_written_shape "$happy_state/ledger/ledger.jsonl"
assert_no_meter_error "$happy_state/ledger/ledger.jsonl"

optional_reporter="$TEST_TMP/optional-reporter"
write_fixture_reporter "$optional_reporter" "$FIXTURES/no-errors-key.json"
optional_state="$TEST_TMP/optional-state"
optional_config="$TEST_TMP/optional.conf"
write_digest_config "$optional_config" "$optional_state" "$optional_reporter" 2 1
run_digest "$optional_config"
optional_digest=$(digest_path_for "$optional_state")
assert_contains 'repos 1 · ci red 1 · human-owned lanes 1 · stale lanes 1 · errors 0 · truncated 0' "$optional_digest"
assert_not_contains '… +' "$optional_digest"

zero_reporter="$TEST_TMP/zero-reporter"
write_inline_reporter "$zero_reporter" \
  '{"ci_red":[],"lanes":[],"roster":{"repos":[]}}'
zero_state="$TEST_TMP/zero-state"
zero_config="$TEST_TMP/zero.conf"
write_digest_config "$zero_config" "$zero_state" "$zero_reporter" 2 1
run_digest "$zero_config"
zero_digest=$(digest_path_for "$zero_state")
[ "$(grep -F -c 'none' "$zero_digest")" -eq 3 ] ||
  fail 'zero-row lists did not render exactly three none markers'
assert_not_contains '… +' "$zero_digest"

overflow_reporter="$TEST_TMP/overflow-reporter"
write_fixture_reporter "$overflow_reporter" "$FIXTURES/overflow.json"
overflow_state="$TEST_TMP/overflow-state"
overflow_config="$TEST_TMP/overflow.conf"
write_digest_config "$overflow_config" "$overflow_state" "$overflow_reporter" 2 10
run_digest "$overflow_config"
overflow_digest=$(digest_path_for "$overflow_state")
assert_contains 'repos 12 · ci red 12 · human-owned lanes 12 · stale lanes 12 · errors 0 · truncated 0' "$overflow_digest"
[ "$(grep -F -c '… +2 more (see lane-status.json)' "$overflow_digest")" -eq 3 ] ||
  fail '[cap mutation] expected +2 overflow marker for each capped list'
assert_contains 'example/repo-10' "$overflow_digest"
assert_not_contains 'example/repo-11' "$overflow_digest"

cap_one_state="$TEST_TMP/cap-one-state"
cap_one_config="$TEST_TMP/cap-one.conf"
write_digest_config "$cap_one_config" "$cap_one_state" "$overflow_reporter" 2 1
run_digest "$cap_one_config"
cap_one_digest=$(digest_path_for "$cap_one_state")
[ "$(grep -F -c '… +11 more (see lane-status.json)' "$cap_one_digest")" -eq 3 ] ||
  fail '[cap mutation] expected +11 overflow marker for each one-row list'
assert_contains 'example/repo-01' "$cap_one_digest"
assert_not_contains 'example/repo-02' "$cap_one_digest"
assert_contains 'repos 12 · ci red 12 · human-owned lanes 12 · stale lanes 12 · errors 0 · truncated 0' "$cap_one_digest"

unset_state="$TEST_TMP/unset-state"
unset_config="$TEST_TMP/unset.conf"
write_digest_config "$unset_config" "$unset_state"
run_digest "$unset_config"
unset_digest=$(digest_path_for "$unset_state")
assert_not_contains '## Lane status' "$unset_digest"
assert_contains 'lane status: not configured' "$unset_digest"
[ ! -e "$(night_dir_for "$unset_state")" ] ||
  fail 'not-configured digest created a lane-status night directory'

empty_command_state="$TEST_TMP/empty-command-state"
empty_command_config="$TEST_TMP/empty-command.conf"
write_digest_config "$empty_command_config" "$empty_command_state" ''
run_digest "$empty_command_config"
empty_command_digest=$(digest_path_for "$empty_command_state")
assert_not_contains '## Lane status' "$empty_command_digest"
assert_contains 'lane status: not configured' "$empty_command_digest"
[ ! -e "$(night_dir_for "$empty_command_state")" ] ||
  fail 'empty command created a lane-status night directory'

missing_command_state="$TEST_TMP/missing-command-state"
missing_command_config="$TEST_TMP/missing-command.conf"
write_digest_config "$missing_command_config" "$missing_command_state" \
  "$TEST_TMP/does-not-exist"
run_digest "$missing_command_config"
assert_unavailable "$missing_command_state" 'command not found'
assert_contains 'lane-status stderr:' \
  "$missing_command_state/logs/digest-$NIGHT_ID.log"

timeout_reporter="$TEST_TMP/timeout-reporter"
{
  printf '%s\n' '#!/bin/bash'
  printf '%s\n' '/bin/sleep 30 &'
  printf '%s\n' 'child=$!'
  printf '%s\n' 'printf '\''timeout-child=%s\n'\'' "$child" >&2'
  printf '%s\n' 'while kill -0 "$child" 2>/dev/null; do /bin/sleep 1; done'
  printf 'exec /bin/cat %q\n' "$FIXTURES/happy.json"
} > "$timeout_reporter"
chmod 0700 "$timeout_reporter"
timeout_state="$TEST_TMP/timeout-state"
timeout_config="$TEST_TMP/timeout.conf"
write_digest_config "$timeout_config" "$timeout_state" "$timeout_reporter" 1 10
timeout_started=$(/bin/date '+%s')
PATH="$process_ok_bin:$PATH" NIGHTSHIFT_CONFIG="$timeout_config" \
  /bin/bash "$ROOT/bin/nightshift-dispatch" digest >/dev/null
timeout_elapsed=$(( $(/bin/date '+%s') - timeout_started ))
[ "$timeout_elapsed" -lt 20 ] ||
  fail "[set-m timeout mutation] timeout exceeded the bounded deadline: ${timeout_elapsed}s"
assert_unavailable "$timeout_state" 'timeout after 1s'
assert_contains 'lane-status stderr: timeout-child=' \
  "$timeout_state/logs/digest-$NIGHT_ID.log"
timeout_child=$(sed -n 's/.*timeout-child=\([0-9][0-9]*\).*/\1/p' \
  "$timeout_state/logs/digest-$NIGHT_ID.log" | head -n 1)
case "$timeout_child" in
  ''|*[!0-9]*) fail '[set-m timeout mutation] could not read reporter child pid' ;;
esac
if kill -0 "$timeout_child" 2>/dev/null; then
  fail "[set-m timeout mutation] reporter child remained alive: $timeout_child"
fi
assert_not_contains 'timeout-child=' "$(digest_path_for "$timeout_state")"
assert_no_run_dirs "$(night_dir_for "$timeout_state")"

nonzero_reporter="$TEST_TMP/nonzero-reporter"
{
  printf '%s\n' '#!/bin/bash'
  printf '%s\n' 'printf '\''first\tline\nsecond line\nthird-%0210d-END\nfourth line\n'\'' 0 >&2'
  printf '%s\n' 'exit 42'
} > "$nonzero_reporter"
chmod 0700 "$nonzero_reporter"
nonzero_state="$TEST_TMP/nonzero-state"
nonzero_config="$TEST_TMP/nonzero.conf"
write_digest_config "$nonzero_config" "$nonzero_state" "$nonzero_reporter"
run_digest "$nonzero_config"
assert_unavailable "$nonzero_state" 'exit 42'
nonzero_log="$nonzero_state/logs/digest-$NIGHT_ID.log"
assert_contains 'lane-status stderr: firstline' "$nonzero_log"
assert_contains 'lane-status stderr: second line' "$nonzero_log"
assert_contains 'lane-status stderr: third-' "$nonzero_log"
assert_not_contains 'END' "$nonzero_log" "$(digest_path_for "$nonzero_state")"
assert_not_contains 'fourth line' "$nonzero_log" "$(digest_path_for "$nonzero_state")"

nonjson_reporter="$TEST_TMP/nonjson-reporter"
{
  printf '%s\n' '#!/bin/bash' "printf '%s\\n' 'not json'" \
    "printf '%s\\n' 'non-json sentinel' >&2"
} > "$nonjson_reporter"
chmod 0700 "$nonjson_reporter"
nonjson_state="$TEST_TMP/nonjson-state"
nonjson_config="$TEST_TMP/nonjson.conf"
write_digest_config "$nonjson_config" "$nonjson_state" "$nonjson_reporter"
run_digest "$nonjson_config"
assert_unavailable "$nonjson_state" 'contract: not JSON'
assert_contains 'lane-status stderr: non-json sentinel' \
  "$nonjson_state/logs/digest-$NIGHT_ID.log"
assert_not_contains 'non-json sentinel' "$(digest_path_for "$nonjson_state")"

empty_reporter="$TEST_TMP/empty-reporter"
{
  printf '%s\n' '#!/bin/bash' "printf '%s\\n' 'empty sentinel' >&2" 'exit 0'
} > "$empty_reporter"
chmod 0700 "$empty_reporter"
empty_state="$TEST_TMP/empty-state"
empty_config="$TEST_TMP/empty.conf"
write_digest_config "$empty_config" "$empty_state" "$empty_reporter"
run_digest "$empty_config"
assert_unavailable "$empty_state" 'empty output'

whitespace_reporter="$TEST_TMP/whitespace-reporter"
{
  printf '%s\n' '#!/bin/bash' "printf ' \\n\\t \\n'"
} > "$whitespace_reporter"
chmod 0700 "$whitespace_reporter"
whitespace_state="$TEST_TMP/whitespace-state"
whitespace_config="$TEST_TMP/whitespace.conf"
write_digest_config "$whitespace_config" "$whitespace_state" "$whitespace_reporter"
run_digest "$whitespace_config"
assert_unavailable "$whitespace_state" 'empty output'

multiple_reporter="$TEST_TMP/multiple-reporter"
{
  printf '%s\n' '#!/bin/bash' "printf '%s\\n' '{}' '{}'"
} > "$multiple_reporter"
chmod 0700 "$multiple_reporter"
multiple_state="$TEST_TMP/multiple-state"
multiple_config="$TEST_TMP/multiple.conf"
write_digest_config "$multiple_config" "$multiple_state" "$multiple_reporter"
run_digest "$multiple_config"
assert_unavailable "$multiple_state" 'contract: not a single JSON value'

not_object_reporter="$TEST_TMP/not-object-reporter"
write_fixture_reporter "$not_object_reporter" "$FIXTURES/not-object.json"
not_object_state="$TEST_TMP/not-object-state"
not_object_config="$TEST_TMP/not-object.conf"
write_digest_config "$not_object_config" "$not_object_state" "$not_object_reporter"
run_digest "$not_object_config"
assert_unavailable "$not_object_state" 'contract: not an object'

missing_lanes_reporter="$TEST_TMP/missing-lanes-reporter"
write_fixture_reporter "$missing_lanes_reporter" "$FIXTURES/missing-lanes.json"
missing_lanes_state="$TEST_TMP/missing-lanes-state"
missing_lanes_config="$TEST_TMP/missing-lanes.conf"
write_digest_config "$missing_lanes_config" "$missing_lanes_state" \
  "$missing_lanes_reporter"
run_digest "$missing_lanes_config"
assert_unavailable "$missing_lanes_state" 'contract: lanes missing'

run_digest "$happy_config"
assert_file_exists "$happy_raw"
write_digest_config "$happy_config" "$happy_state" "$nonjson_reporter"
run_digest "$happy_config"
assert_unavailable "$happy_state" 'contract: not JSON'

large_reporter="$TEST_TMP/large-reporter"
{
  printf '%s\n' '#!/bin/bash'
  printf '%s\n' '/bin/dd if=/dev/zero bs=1048576 count=3 2>/dev/null'
} > "$large_reporter"
chmod 0700 "$large_reporter"
large_direct_dir="$TEST_TMP/large-direct/$NIGHT_ID"
if ! PATH="$process_ok_bin:$PATH" \
  digest_lane_status_run "$large_reporter" 3 "$large_direct_dir"; then
  fail "large-output direct run setup failed: $DIGEST_LANE_STATUS_RUN_ERROR"
fi
large_size=$(wc -c < "$DIGEST_LANE_STATUS_STDOUT" | tr -d '[:space:]')
[ "$large_size" -le 2097152 ] ||
  fail "write-time output bound exceeded 2 MiB: $large_size"
rm -rf "$DIGEST_LANE_STATUS_RUN_DIR"
large_state="$TEST_TMP/large-state"
large_config="$TEST_TMP/large.conf"
write_digest_config "$large_config" "$large_state" "$large_reporter" 3 10
run_digest "$large_config"
assert_unavailable "$large_state" 'output too large'
assert_not_contains 'lane status: unavailable (exit 153)' \
  "$(digest_path_for "$large_state")"

inspection_bin="$TEST_TMP/inspection-bin"
mkdir -p "$inspection_bin"
for process_command in ps pgrep; do
  {
    printf '%s\n' '#!/bin/bash'
    case "$process_command" in
      ps) printf '%s\n' 'exit 1' ;;
      pgrep) printf '%s\n' 'exit 2' ;;
    esac
  } > "$inspection_bin/$process_command"
  chmod 0700 "$inspection_bin/$process_command"
done
inspection_state="$TEST_TMP/inspection-state"
inspection_config="$TEST_TMP/inspection.conf"
write_digest_config "$inspection_config" "$inspection_state" "$happy_reporter"
PATH="$inspection_bin:$PATH" NIGHTSHIFT_CONFIG="$inspection_config" \
  /bin/bash "$ROOT/bin/nightshift-dispatch" digest >/dev/null
assert_unavailable "$inspection_state" 'process inspection unavailable'
assert_contains 'ERROR] Lane status unavailable: process inspection unavailable' \
  "$inspection_state/logs/digest-$NIGHT_ID.log"

state_error_state="$TEST_TMP/state-error-state"
state_error_config="$TEST_TMP/state-error.conf"
write_digest_config "$state_error_config" "$state_error_state" "$happy_reporter"
mkdir -p "$state_error_state/digests"
: > "$state_error_state/digests/$NIGHT_ID"
run_digest "$state_error_config"
assert_unavailable "$state_error_state" 'state: mkdir failed' no
assert_contains 'ERROR] Lane status unavailable: state: mkdir failed' \
  "$state_error_state/logs/digest-$NIGHT_ID.log"

isolation_reporter="$TEST_TMP/isolation-reporter"
{
  printf '%s\n' '#!/bin/bash'
  printf '%s\n' 'printf '\''HOME=%s\nPWD=%s\nTMPDIR=%s\nGIT_CEILING_DIRECTORIES=%s\nGH_CONFIG_DIR=%s\nSENTINEL_ENV=%s\n'\'' "$HOME" "$PWD" "$TMPDIR" "$GIT_CEILING_DIRECTORIES" "$GH_CONFIG_DIR" "${SENTINEL_ENV:-}" >&2'
  printf '%s\n' ': > "$HOME/x"'
  printf 'exec /bin/cat %q\n' "$FIXTURES/no-errors-key.json"
} > "$isolation_reporter"
chmod 0700 "$isolation_reporter"
isolation_state="$TEST_TMP/isolation-state"
isolation_config="$TEST_TMP/isolation.conf"
isolation_gh="$TEST_TMP/gh-config"
write_digest_config "$isolation_config" "$isolation_state" "$isolation_reporter"
GH_CONFIG_DIR="$isolation_gh" SENTINEL_ENV=must-not-pass \
  NIGHTSHIFT_CONFIG="$isolation_config" \
  /bin/bash "$ROOT/bin/nightshift-dispatch" digest >/dev/null
isolation_stderr="$(night_dir_for "$isolation_state")/lane-status.stderr"
isolation_night_dir=$(night_dir_for "$isolation_state")
isolation_night_real=$(cd -P "$isolation_night_dir" && pwd -P)
assert_contains "HOME=$isolation_night_dir/.run." "$isolation_stderr"
assert_contains "PWD=$isolation_night_real/.run." "$isolation_stderr"
assert_contains "TMPDIR=$isolation_night_dir/.run." "$isolation_stderr"
assert_contains "GIT_CEILING_DIRECTORIES=$isolation_night_dir/.run." "$isolation_stderr"
assert_contains "GH_CONFIG_DIR=$isolation_gh" "$isolation_stderr"
assert_contains 'SENTINEL_ENV=' "$isolation_stderr"
assert_not_contains 'SENTINEL_ENV=must-not-pass' "$isolation_stderr"
assert_no_run_dirs "$isolation_night_dir"

long_title=
long_expected=
long_index=0
while [ "$long_index" -lt 121 ]; do
  long_title="${long_title}界"
  if [ "$long_index" -lt 120 ]; then
    long_expected="${long_expected}界"
  fi
  long_index=$((long_index + 1))
done
sanitized_json="$TEST_TMP/sanitized.json"
jq -n \
  --arg newline_title "line one
line two" \
  --arg long_title "$long_title" \
  --arg control_title "$(printf 'escape\033[31m bell\007 del\177 end')" \
  '{
    ci_red: [],
    lanes: [
      {repo:"example/alpha",kind:"issue",number:1,title:$newline_title,owner:"human",stale:false,reason:"needs\taction"},
      {repo:"example/alpha",kind:"issue",number:2,title:$long_title,owner:"human",stale:false,reason:"long"},
      {repo:"example/alpha",kind:"issue",number:3,title:"{{FINDINGS_BLOCK}}",owner:"human",stale:false,reason:"literal"},
      {repo:"example/alpha",kind:"issue",number:4,title:$control_title,owner:"human",stale:false,reason:"controls"},
      {repo:"example/alpha",kind:"issue",number:"5\n",title:"bad number",owner:"human",stale:false,reason:"invalid"}
    ],
    roster: {repos:["example/alpha"]},
    errors: [],
    truncated: []
  }' > "$sanitized_json"
sanitized_reporter="$TEST_TMP/sanitized-reporter"
write_fixture_reporter "$sanitized_reporter" "$sanitized_json"
sanitized_state="$TEST_TMP/sanitized-state"
sanitized_config="$TEST_TMP/sanitized.conf"
write_digest_config "$sanitized_config" "$sanitized_state" "$sanitized_reporter"
run_digest "$sanitized_config"
sanitized_digest=$(digest_path_for "$sanitized_state")
assert_contains 'malformed rows 1' "$sanitized_digest"
assert_contains 'example/alpha#1 · line one line two · needs action' "$sanitized_digest"
assert_contains "example/alpha#2 · ${long_expected}… · long" "$sanitized_digest"
assert_contains 'example/alpha#3 · {{FINDINGS_BLOCK}} · literal' "$sanitized_digest"
assert_contains 'example/alpha#4 · escape[31m bell del end · controls' "$sanitized_digest"
assert_not_contains 'bad number' "$sanitized_digest"
assert_not_contains "$(printf '\033')" "$sanitized_digest"
assert_not_contains "$(printf '\007')" "$sanitized_digest"
assert_not_contains "$(printf '\177')" "$sanitized_digest"
iconv -f UTF-8 -t UTF-8 "$sanitized_digest" > "$TEST_TMP/sanitized-utf8-check" ||
  fail 'multibyte sanitizer emitted invalid UTF-8'

contract_file="$TEST_TMP/contract.json"
printf '%s\n' '{"lanes":[],"roster":{"repos":[]}}' > "$contract_file"
if digest_lane_status_check "$contract_file"; then
  fail 'contract checker accepted missing ci_red'
fi
[ "$DIGEST_LANE_STATUS_REASON" = 'contract: ci_red missing' ] ||
  fail 'contract checks did not preserve top-level precedence'
printf '%s\n' '{"ci_red":[],"lanes":[],"roster":{"repos":[1]}}' > "$contract_file"
if digest_lane_status_check "$contract_file"; then
  fail 'contract checker accepted non-string roster entry'
fi
[ "$DIGEST_LANE_STATUS_REASON" = 'contract: roster.repos not an array of strings' ] ||
  fail 'contract checker reported the wrong roster type failure'
printf '%s\n' '{"ci_red":[],"lanes":[],"roster":{"repos":[]},"errors":{}}' > "$contract_file"
if digest_lane_status_check "$contract_file"; then
  fail 'contract checker accepted non-array errors'
fi
[ "$DIGEST_LANE_STATUS_REASON" = 'contract: errors not an array' ] ||
  fail 'contract checker reported the wrong optional-key failure'

bad_timeout_state="$TEST_TMP/bad-timeout-state"
bad_timeout_config="$TEST_TMP/bad-timeout.conf"
write_digest_config "$bad_timeout_config" "$bad_timeout_state" "$happy_reporter" abc 10
if run_digest "$bad_timeout_config"; then
  fail 'digest accepted LANE_STATUS_TIMEOUT_SEC=abc'
fi
assert_contains 'LANE_STATUS_TIMEOUT_SEC must be a positive integer' \
  "$bad_timeout_state/logs/digest-$NIGHT_ID.log"
PATH="$process_ok_bin:$PATH" NIGHTSHIFT_CONFIG="$bad_timeout_config" \
  /bin/bash "$ROOT/bin/nightshift-dispatch" run >/dev/null ||
  fail 'run was affected by an unused invalid lane-status timeout'

bad_cap_state="$TEST_TMP/bad-cap-state"
bad_cap_config="$TEST_TMP/bad-cap.conf"
write_digest_config "$bad_cap_config" "$bad_cap_state" "$happy_reporter" 2 0
if run_digest "$bad_cap_config"; then
  fail 'digest accepted LANE_STATUS_MAX_ROWS=0'
fi
assert_contains 'LANE_STATUS_MAX_ROWS must be a positive integer' \
  "$bad_cap_state/logs/digest-$NIGHT_ID.log"
PATH="$process_ok_bin:$PATH" NIGHTSHIFT_CONFIG="$bad_cap_config" \
  /bin/bash "$ROOT/bin/nightshift-dispatch" run >/dev/null ||
  fail 'run was affected by an unused invalid lane-status cap'
if digest_lane_status_validate_config 12345678 10 2>/dev/null; then
  fail 'config validator accepted an eight-digit timeout'
fi
if digest_lane_status_validate_config 10 12345678 2>/dev/null; then
  fail 'config validator accepted an eight-digit row cap'
fi

for docs_file in \
  "$ROOT/config/nightshift.conf.example" \
  "$ROOT/docs/reference.md" \
  "$ROOT/docs/reference.ja.md"; do
  assert_contains 'LANE_STATUS_CMD' "$docs_file"
  assert_contains 'LANE_STATUS_TIMEOUT_SEC' "$docs_file"
  assert_contains 'LANE_STATUS_MAX_ROWS' "$docs_file"
done
assert_contains 'LANE_STATUS_CMD' "$ROOT/docs/engineering.md"
assert_contains 'LANE_STATUS_CMD' "$ROOT/docs/engineering.ja.md"

printf 'test_digest_lane_status: PASS\n'
