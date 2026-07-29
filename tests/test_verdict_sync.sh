#!/bin/bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
. "$TEST_DIR/helpers.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-verdict.XXXXXX")
cleanup() {
  chmod u+w "$TEST_TMP"/*/ledger 2>/dev/null || true
  chmod u+w "$TEST_TMP"/*/ledger/ledger.jsonl 2>/dev/null || true
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

write_config() {
  verdict_config=$1
  verdict_state=$2
  verdict_gh_bin=${3:-"$TEST_TMP/no-gh"}
  printf '%s\n' \
    "NIGHTSHIFT_STATE_DIR='$verdict_state'" \
    "LANE_CMD_1=':'" \
    "LANE_HOME_LINKS=''" \
    "NIGHT_BOT_LOGIN='night-bot'" \
    "VERDICT_GH_BIN='$verdict_gh_bin'" \
    > "$verdict_config"
}

seed_finding() {
  verdict_state=$1
  verdict_id=$2
  mkdir -p "$verdict_state/ledger"
  jq -n -c \
    --arg id "$verdict_id" \
    '{
      ts: "2026-07-29T00:00:00Z",
      night_id: "2026-07-28",
      type: "finding",
      id: $id,
      repo: "demo",
      target: "screen",
      symptom: ("symptom " + $id),
      interpretation: "retained interpretation",
      evidence: ["evidence/shot.png"],
      kind: "Bug",
      status: "open",
      confirm_cost: "1分",
      date: "2026-07-28"
    }' >> "$verdict_state/ledger/ledger.jsonl"
}

run_manual() {
  verdict_config=$1
  verdict_input=$2
  NIGHTSHIFT_CONFIG="$verdict_config" \
    /bin/bash "$ROOT/bin/verdict-sync" --input "$verdict_input" >/dev/null
}

run_github() {
  verdict_config=$1
  verdict_links=$2
  verdict_scenario=$3
  verdict_log=$4
  FAKE_GH_SCENARIO="$verdict_scenario" \
    FAKE_GH_LOG="$verdict_log" \
    FAKE_GH_FIXTURE_DIR="$TEST_TMP" \
    NIGHTSHIFT_CONFIG="$verdict_config" \
    /bin/bash "$ROOT/bin/verdict-sync" --github-links "$verdict_links" \
    >/dev/null
}

no_gh_marker="$TEST_TMP/no-gh-called"
printf '%s\n' \
  '#!/bin/bash' \
  "printf called > '$no_gh_marker'" \
  'exit 99' \
  > "$TEST_TMP/no-gh"
chmod +x "$TEST_TMP/no-gh"

manual_state="$TEST_TMP/manual-state"
manual_config="$TEST_TMP/manual.conf"
write_config "$manual_config" "$manual_state"
seed_finding "$manual_state" adopted-id
seed_finding "$manual_state" fixed-id
seed_finding "$manual_state" rejected-id
seed_finding "$manual_state" '../traversal/id'
manual_input="$TEST_TMP/manual.jsonl"
printf '%s\n' \
  '{"finding_id":"adopted-id","status":"adopted","actor":"alice","source":"manual-comment","source_ref":"comment:adopted","observed_at":"2026-07-29T01:00:00Z","candidate_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","implementer":"impl","reviewer":"review","identity_check":"human checked","done_when":[{"item":"tests are green","result":"green hint","evidence":"log hint"}],"declared_files":["lib/a.sh"],"diff_stat":"1 file changed"}' \
  '{"finding_id":"fixed-id","status":"fixed","actor":"alice","source":"manual-label","source_ref":"label:fixed","observed_at":"2026-07-29T01:01:00Z"}' \
  '{"finding_id":"rejected-id","status":"rejected","actor":"alice","source":"manual-comment","source_ref":"comment:rejected","observed_at":"2026-07-29T01:02:00Z","rejection_reason":"not safe"}' \
  '{"finding_id":"../traversal/id","status":"adopted","actor":"alice","source":"manual-comment","source_ref":"comment:traversal","observed_at":"2026-07-29T01:03:00Z","declared_files":["safe/path.sh"]}' \
  > "$manual_input"
original_findings="$TEST_TMP/original-findings"
jq -c 'select(.type == "finding")' \
  "$manual_state/ledger/ledger.jsonl" > "$original_findings"
run_manual "$manual_config" "$manual_input"
[ ! -e "$no_gh_marker" ] || fail "manual mode invoked a GitHub binary"
[ -z "$(find "$manual_state" -maxdepth 1 -name '.verdict-sync.*' \
  -print -quit)" ] || fail "manual mode left a staging directory"
ledger="$manual_state/ledger/ledger.jsonl"
[ "$(jq -r 'select(.type == "verdict") | .status' "$ledger" | sort |
  tr '\n' ' ')" = "adopted adopted fixed rejected " ] ||
  fail "manual adopted/fixed/rejected decisions were not appended"
jq -c 'select(.type == "finding")' "$ledger" |
  cmp -s - "$original_findings" ||
  fail "verdict-sync changed an original finding record"
jq -e '
  select(
    .type == "verdict" and
    .status == "rejected" and
    .rejection_reason == "not safe" and
    (.verdict_id | test("^verdict-v1-[0-9a-f]{64}$"))
  )
' "$ledger" >/dev/null ||
  fail "canonical rejected verdict was not recorded"
safe_hash=$(printf '%s' '../traversal/id' | shasum -a 256 | awk '{print $1}')
safe_draft="$manual_state/verdicts/finding-$safe_hash/L1-7-draft.md"
assert_file_exists "$safe_draft"
case "$safe_draft" in
  "$manual_state"/verdicts/finding-*/L1-7-draft.md) ;;
  *) fail "draft escaped its digest-derived directory" ;;
esac
adopted_hash=$(printf '%s' adopted-id | shasum -a 256 | awk '{print $1}')
adopted_draft="$manual_state/verdicts/finding-$adopted_hash/L1-7-draft.md"
assert_contains 'TODO / UNVERIFIED' "$adopted_draft"
assert_contains 'input hint: green hint' "$adopted_draft"
assert_contains 'Declared-vs-diff review' "$adopted_draft"
assert_not_contains PASS "$adopted_draft"

manual_lines_before=$(wc -l < "$ledger" | tr -d ' ')
manual_ids_before=$(jq -r 'select(.type == "verdict") | .verdict_id' "$ledger")
draft_checksum_before=$(cksum "$adopted_draft")
printf '%s\n' 'stale draft sentinel' >> "$adopted_draft"
run_manual "$manual_config" "$manual_input"
manual_lines_after=$(wc -l < "$ledger" | tr -d ' ')
[ "$manual_lines_before" -eq "$manual_lines_after" ] ||
  fail "idempotent rerun appended a second verdict"
[ "$manual_ids_before" = \
  "$(jq -r 'select(.type == "verdict") | .verdict_id' "$ledger")" ] ||
  fail "verdict identity changed on rerun"
[ "$draft_checksum_before" = "$(cksum "$adopted_draft")" ] ||
  fail "idempotent rerun did not deterministically refresh the draft"

assert_rejected_batch() {
  rejected_name=$1
  rejected_line=$2
  rejected_state="$TEST_TMP/$rejected_name-state"
  rejected_config="$TEST_TMP/$rejected_name.conf"
  rejected_input="$TEST_TMP/$rejected_name.jsonl"
  write_config "$rejected_config" "$rejected_state"
  seed_finding "$rejected_state" target
  printf '%s\n' "$rejected_line" > "$rejected_input"
  rejected_before=$(wc -l < "$rejected_state/ledger/ledger.jsonl" |
    tr -d ' ')
  rejected_rc=0
  run_manual "$rejected_config" "$rejected_input" ||
    rejected_rc=$?
  [ "$rejected_rc" -ne 0 ] ||
    fail "$rejected_name decision unexpectedly succeeded"
  rejected_after=$(wc -l < "$rejected_state/ledger/ledger.jsonl" |
    tr -d ' ')
  [ "$rejected_before" -eq "$rejected_after" ] ||
    fail "$rejected_name changed the ledger"
  [ ! -d "$rejected_state/verdicts" ] ||
    [ -z "$(find "$rejected_state/verdicts" -type f -print -quit)" ] ||
    fail "$rejected_name published a draft"
}

assert_rejected_batch missing-reason \
  '{"finding_id":"target","status":"rejected","actor":"alice","source":"manual-comment","source_ref":"c:1","observed_at":"2026-07-29T02:00:00Z"}'
assert_rejected_batch forbidden-reason \
  '{"finding_id":"target","status":"adopted","actor":"alice","source":"manual-comment","source_ref":"c:2","observed_at":"2026-07-29T02:00:00Z","rejection_reason":"no"}'
assert_rejected_batch unknown-field \
  '{"finding_id":"target","status":"adopted","actor":"alice","source":"manual-comment","source_ref":"c:3","observed_at":"2026-07-29T02:00:00Z","extra":"not allowed"}'
assert_rejected_batch invalid-declared-path \
  '{"finding_id":"target","status":"adopted","actor":"alice","source":"manual-comment","source_ref":"c:4","observed_at":"2026-07-29T02:00:00Z","declared_files":["../escape"]}'
assert_rejected_batch invalid-status \
  '{"finding_id":"target","status":"deferred","actor":"alice","source":"manual-comment","source_ref":"c:5","observed_at":"2026-07-29T02:00:00Z"}'
assert_rejected_batch malformed-schema \
  '{"finding_id":"target","status":"adopted","actor":"","source":"manual-comment","source_ref":"c:6","observed_at":"not-a-time"}'
assert_rejected_batch invalid-calendar-time \
  '{"finding_id":"target","status":"adopted","actor":"alice","source":"manual-comment","source_ref":"c:calendar","observed_at":"2026-02-31T02:00:00Z"}'

unknown_state="$TEST_TMP/unknown-state"
unknown_config="$TEST_TMP/unknown.conf"
unknown_input="$TEST_TMP/unknown.jsonl"
write_config "$unknown_config" "$unknown_state"
seed_finding "$unknown_state" known
printf '%s\n' \
  '{"finding_id":"missing","status":"adopted","actor":"alice","source":"manual-comment","source_ref":"c:7","observed_at":"2026-07-29T02:00:00Z"}' \
  > "$unknown_input"
unknown_rc=0
run_manual "$unknown_config" "$unknown_input" || unknown_rc=$?
[ "$unknown_rc" -ne 0 ] || fail "unknown finding was accepted"
[ "$(wc -l < "$unknown_state/ledger/ledger.jsonl" | tr -d ' ')" -eq 1 ] ||
  fail "unknown finding changed the ledger"

duplicate_state="$TEST_TMP/duplicate-state"
duplicate_config="$TEST_TMP/duplicate.conf"
duplicate_input="$TEST_TMP/duplicate.jsonl"
write_config "$duplicate_config" "$duplicate_state"
seed_finding "$duplicate_state" duplicate
printf '%s\n' \
  '{"finding_id":"duplicate","status":"adopted","actor":"alice","source":"manual-comment","source_ref":"c:8","observed_at":"2026-07-29T02:00:00Z"}' \
  '{"finding_id":"duplicate","status":"fixed","actor":"alice","source":"manual-comment","source_ref":"c:9","observed_at":"2026-07-29T03:00:00Z"}' \
  > "$duplicate_input"
duplicate_rc=0
run_manual "$duplicate_config" "$duplicate_input" || duplicate_rc=$?
[ "$duplicate_rc" -ne 0 ] || fail "duplicate finding decision was accepted"
[ "$(wc -l < "$duplicate_state/ledger/ledger.jsonl" | tr -d ' ')" -eq 1 ] ||
  fail "duplicate input partially appended"

batch_state="$TEST_TMP/batch-state"
batch_config="$TEST_TMP/batch.conf"
batch_input="$TEST_TMP/batch.jsonl"
write_config "$batch_config" "$batch_state"
seed_finding "$batch_state" valid
seed_finding "$batch_state" invalid
printf '%s\n' \
  '{"finding_id":"valid","status":"adopted","actor":"alice","source":"manual-comment","source_ref":"batch:1","observed_at":"2026-07-29T02:00:00Z"}' \
  '{"finding_id":"invalid","status":"rejected","actor":"alice","source":"manual-comment","source_ref":"batch:2","observed_at":"2026-07-29T02:00:00Z"}' \
  > "$batch_input"
batch_rc=0
run_manual "$batch_config" "$batch_input" || batch_rc=$?
[ "$batch_rc" -ne 0 ] || fail "mixed valid/invalid batch succeeded"
[ "$(wc -l < "$batch_state/ledger/ledger.jsonl" | tr -d ' ')" -eq 2 ] ||
  fail "mixed valid/invalid batch partially appended"

relative_rc=0
NIGHTSHIFT_CONFIG="$manual_config" \
  /bin/bash "$ROOT/bin/verdict-sync" --input relative.jsonl >/dev/null 2>&1 ||
  relative_rc=$?
[ "$relative_rc" -ne 0 ] || fail "relative input path was accepted"

transition_state="$TEST_TMP/transition-state"
transition_config="$TEST_TMP/transition.conf"
write_config "$transition_config" "$transition_state"
seed_finding "$transition_state" progress
seed_finding "$transition_state" reopen
seed_finding "$transition_state" terminal
transition_input="$TEST_TMP/transition.jsonl"
printf '%s\n' \
  '{"finding_id":"progress","status":"adopted","actor":"alice","source":"manual-comment","source_ref":"t:1","observed_at":"2026-07-29T01:00:00Z"}' \
  '{"finding_id":"reopen","status":"rejected","actor":"alice","source":"manual-comment","source_ref":"t:2","observed_at":"2026-07-29T01:00:00Z","rejection_reason":"later human review"}' \
  '{"finding_id":"terminal","status":"fixed","actor":"alice","source":"manual-comment","source_ref":"t:3","observed_at":"2026-07-29T01:00:00Z"}' \
  > "$transition_input"
run_manual "$transition_config" "$transition_input"
printf '%s\n' \
  '{"finding_id":"progress","status":"fixed","actor":"alice","source":"manual-comment","source_ref":"t:4","observed_at":"2026-07-29T02:00:00Z"}' \
  > "$transition_input"
run_manual "$transition_config" "$transition_input"
printf '%s\n' \
  '{"finding_id":"reopen","status":"adopted","actor":"night-bot","source":"manual-comment","source_ref":"t:5","observed_at":"2026-07-29T02:00:00Z"}' \
  > "$transition_input"
bot_reopen_rc=0
run_manual "$transition_config" "$transition_input" || bot_reopen_rc=$?
[ "$bot_reopen_rc" -ne 0 ] || fail "night bot reopened a rejection"
printf '%s\n' \
  '{"finding_id":"reopen","status":"adopted","actor":"human","source":"manual-comment","source_ref":"t:6","observed_at":"2026-07-29T02:00:01Z"}' \
  > "$transition_input"
run_manual "$transition_config" "$transition_input"
printf '%s\n' \
  '{"finding_id":"terminal","status":"rejected","actor":"human","source":"manual-comment","source_ref":"t:7","observed_at":"2026-07-29T03:00:00Z","rejection_reason":"too late"}' \
  > "$transition_input"
terminal_rc=0
run_manual "$transition_config" "$transition_input" || terminal_rc=$?
[ "$terminal_rc" -ne 0 ] || fail "fixed finding accepted a later verdict"
printf '%s\n' \
  '{"finding_id":"reopen","status":"rejected","actor":"human","source":"manual-comment","source_ref":"t:8","observed_at":"2026-07-29T02:00:01Z","rejection_reason":"equal time"}' \
  > "$transition_input"
equal_rc=0
run_manual "$transition_config" "$transition_input" || equal_rc=$?
[ "$equal_rc" -ne 0 ] || fail "equal-time conflicting verdict was accepted"

lock_state="$TEST_TMP/lock-state"
lock_config="$TEST_TMP/lock.conf"
lock_input="$TEST_TMP/lock.jsonl"
write_config "$lock_config" "$lock_state"
seed_finding "$lock_state" locked
mkdir -p "$lock_state/locks/nightshift.lock"
printf '%s\n' \
  '{"finding_id":"locked","status":"adopted","actor":"alice","source":"manual-comment","source_ref":"lock:1","observed_at":"2026-07-29T02:00:00Z"}' \
  > "$lock_input"
lock_before=$(cksum "$lock_state/ledger/ledger.jsonl")
lock_rc=0
run_manual "$lock_config" "$lock_input" || lock_rc=$?
[ "$lock_rc" -ne 0 ] || fail "verdict-sync succeeded with held lock"
[ "$lock_before" = "$(cksum "$lock_state/ledger/ledger.jsonl")" ] ||
  fail "held-lock run changed the ledger"
[ ! -d "$lock_state/verdicts" ] ||
  fail "held-lock run created verdict drafts"

append_state="$TEST_TMP/append-state"
append_config="$TEST_TMP/append.conf"
append_input="$TEST_TMP/append.jsonl"
write_config "$append_config" "$append_state"
seed_finding "$append_state" append-fail
printf '%s\n' \
  '{"finding_id":"append-fail","status":"adopted","actor":"alice","source":"manual-comment","source_ref":"append:1","observed_at":"2026-07-29T02:00:00Z"}' \
  > "$append_input"
chmod a-w "$append_state/ledger/ledger.jsonl"
chmod a-w "$append_state/ledger"
append_rc=0
run_manual "$append_config" "$append_input" || append_rc=$?
[ "$append_rc" -ne 0 ] || fail "verdict-sync succeeded after append failure"
[ ! -d "$append_state/verdicts" ] ||
  fail "append failure produced a success-looking draft"
chmod u+w "$append_state/ledger" "$append_state/ledger/ledger.jsonl"

jq -n -c '
  [
    range(0; 100) as $index |
    {
      id: (3100 + $index),
      body: ({
        schema: "alpha-nightshift/verdict-marker/v1",
        finding_id: "gh-finding",
        status: "rejected",
        rejection_reason: ("human reason " + ($index | tostring))
      } | tojson),
      user: {login: "human", type: "User"},
      created_at: (
        1785297600 + ($index * 60) |
        strftime("%Y-%m-%dT%H:%M:%SZ")
      )
    }
  ]
' > "$TEST_TMP/pagination-comments.json"
jq -n -c '
  [
    range(0; 100) as $index |
    {
      id: (3200 + $index),
      event: "labeled",
      label: {name: "night:ready"},
      actor: {login: "triager"},
      created_at: (
        1785297600 + ($index * 60) |
        strftime("%Y-%m-%dT%H:%M:%SZ")
      )
    }
  ]
' > "$TEST_TMP/pagination-events.json"

fake_gh="$TEST_TMP/fake-gh"
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'printf "%s\n" "$*" >> "$FAKE_GH_LOG"' \
  '[ "$1" = api ] && [ "$2" = --method ] && [ "$3" = GET ] || exit 91' \
  'endpoint=$4' \
  'case "$FAKE_GH_SCENARIO:$endpoint" in' \
  '  merged:repos/demo/repo/pulls/11)' \
  "    printf '%s\\n' '{\"state\":\"closed\",\"merged\":true,\"merged_at\":\"2026-07-29T04:00:00Z\",\"merged_by\":{\"login\":\"merger\"},\"labels\":[],\"html_url\":\"https://example/pr/11\",\"user\":{\"login\":\"author\"},\"created_at\":\"2026-07-29T03:00:00Z\",\"head\":{\"sha\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}}' ;;" \
  '  open:repos/demo/repo/pulls/12)' \
  "    printf '%s\\n' '{\"state\":\"open\",\"merged\":false,\"merged_at\":null,\"merged_by\":null,\"labels\":[],\"html_url\":\"https://example/pr/12\",\"user\":{\"login\":\"author\"},\"created_at\":\"2026-07-29T03:00:00Z\",\"head\":{\"sha\":\"cccccccccccccccccccccccccccccccccccccccc\"}}' ;;" \
  '  rejected:repos/demo/repo/pulls/13|missing-reason:repos/demo/repo/pulls/13)' \
  "    printf '%s\\n' '{\"state\":\"closed\",\"merged\":false,\"merged_at\":null,\"merged_by\":null,\"labels\":[{\"name\":\"night:rejected\"}],\"html_url\":\"https://example/pr/13\",\"user\":{\"login\":\"author\"},\"created_at\":\"2026-07-29T03:00:00Z\",\"head\":{\"sha\":\"dddddddddddddddddddddddddddddddddddddddd\"}}' ;;" \
  '  rejected:repos/demo/repo/issues/13/comments?per_page=100)' \
  "    printf '%s\\n' '[{\"id\":901,\"body\":\"{\\\"schema\\\":\\\"alpha-nightshift/verdict-marker/v1\\\",\\\"finding_id\\\":\\\"gh-finding\\\",\\\"status\\\":\\\"rejected\\\",\\\"rejection_reason\\\":\\\"human reason\\\"}\",\"user\":{\"login\":\"human\",\"type\":\"User\"},\"created_at\":\"2026-07-29T04:00:00Z\"}]' ;;" \
  '  missing-reason:repos/demo/repo/issues/13/comments?per_page=100)' \
  "    printf '%s\\n' '[]' ;;" \
  '  conflict:repos/demo/repo/pulls/14)' \
  "    printf '%s\\n' '{\"state\":\"open\",\"merged\":false,\"merged_at\":null,\"merged_by\":null,\"labels\":[{\"name\":\"night:done\"},{\"name\":\"night:rejected\"}],\"html_url\":\"https://example/pr/14\",\"user\":{\"login\":\"author\"},\"created_at\":\"2026-07-29T03:00:00Z\",\"head\":{\"sha\":null}}' ;;" \
  '  ready-label:repos/demo/repo/issues/21)' \
  "    printf '%s\\n' '{\"state\":\"open\",\"labels\":[{\"name\":\"night:ready\"}]}' ;;" \
  '  ready-label:repos/demo/repo/issues/21/events?per_page=100)' \
  "    printf '%s\\n' '[{\"id\":2101,\"event\":\"labeled\",\"label\":{\"name\":\"night:ready\"},\"actor\":{\"login\":\"triager\"},\"created_at\":\"2026-07-29T05:00:00Z\"}]' ;;" \
  '  done-label:repos/demo/repo/issues/22)' \
  "    printf '%s\\n' '{\"state\":\"closed\",\"labels\":[{\"name\":\"night:done\"}]}' ;;" \
  '  done-label:repos/demo/repo/issues/22/events?per_page=100)' \
  "    printf '%s\\n' '[{\"id\":2201,\"event\":\"labeled\",\"label\":{\"name\":\"night:done\"},\"actor\":{\"login\":\"triager\"},\"created_at\":\"2026-07-29T05:01:00Z\"}]' ;;" \
  '  pagination-comments:repos/demo/repo/pulls/31)' \
  "    printf '%s\\n' '{\"state\":\"closed\",\"merged\":false,\"merged_at\":null,\"merged_by\":null,\"labels\":[{\"name\":\"night:rejected\"}],\"html_url\":\"https://example/pr/31\",\"user\":{\"login\":\"author\"},\"created_at\":\"2026-07-29T03:00:00Z\",\"head\":{\"sha\":null}}' ;;" \
  '  pagination-comments:repos/demo/repo/issues/31/comments?per_page=100)' \
  '    command cat "$FAKE_GH_FIXTURE_DIR/pagination-comments.json" ;;' \
  '  pagination-events:repos/demo/repo/issues/32)' \
  "    printf '%s\\n' '{\"state\":\"open\",\"labels\":[{\"name\":\"night:ready\"}]}' ;;" \
  '  pagination-events:repos/demo/repo/issues/32/events?per_page=100)' \
  '    command cat "$FAKE_GH_FIXTURE_DIR/pagination-events.json" ;;' \
  '  ready-rejected:repos/demo/repo/issues/33)' \
  "    printf '%s\\n' '{\"state\":\"open\",\"labels\":[{\"name\":\"night:ready\"},{\"name\":\"night:rejected\"}]}' ;;" \
  '  issue-pr-conflict:repos/demo/repo/issues/34)' \
  "    printf '%s\\n' '{\"state\":\"open\",\"labels\":[{\"name\":\"night:ready\"}]}' ;;" \
  '  issue-pr-conflict:repos/demo/repo/issues/34/events?per_page=100)' \
  "    printf '%s\\n' '[{\"id\":3401,\"event\":\"labeled\",\"label\":{\"name\":\"night:ready\"},\"actor\":{\"login\":\"triager\"},\"created_at\":\"2026-07-29T04:00:00Z\"}]' ;;" \
  '  issue-pr-conflict:repos/demo/repo/pulls/35)' \
  "    printf '%s\\n' '{\"state\":\"closed\",\"merged\":false,\"merged_at\":null,\"merged_by\":null,\"labels\":[{\"name\":\"night:rejected\"}],\"html_url\":\"https://example/pr/35\",\"user\":{\"login\":\"author\"},\"created_at\":\"2026-07-29T03:00:00Z\",\"head\":{\"sha\":null}}' ;;" \
  '  issue-pr-conflict:repos/demo/repo/issues/35/comments?per_page=100)' \
  "    printf '%s\\n' '[{\"id\":3501,\"body\":\"{\\\"schema\\\":\\\"alpha-nightshift/verdict-marker/v1\\\",\\\"finding_id\\\":\\\"gh-finding\\\",\\\"status\\\":\\\"rejected\\\",\\\"rejection_reason\\\":\\\"human reason\\\"}\",\"user\":{\"login\":\"human\",\"type\":\"User\"},\"created_at\":\"2026-07-29T05:00:00Z\"}]' ;;" \
  '  newer-fixed:repos/demo/repo/issues/36)' \
  "    printf '%s\\n' '{\"state\":\"closed\",\"labels\":[{\"name\":\"night:done\"}]}' ;;" \
  '  newer-fixed:repos/demo/repo/issues/36/events?per_page=100)' \
  "    printf '%s\\n' '[{\"id\":3601,\"event\":\"labeled\",\"label\":{\"name\":\"night:done\"},\"actor\":{\"login\":\"triager\"},\"created_at\":\"2026-07-29T06:00:00Z\"}]' ;;" \
  '  newer-fixed:repos/demo/repo/pulls/37)' \
  "    printf '%s\\n' '{\"state\":\"closed\",\"merged\":true,\"merged_at\":\"2026-07-29T04:00:00Z\",\"merged_by\":{\"login\":\"merger\"},\"labels\":[],\"html_url\":\"https://example/pr/37\",\"user\":{\"login\":\"author\"},\"created_at\":\"2026-07-29T03:00:00Z\",\"head\":{\"sha\":null}}' ;;" \
  '  equal-fixed:repos/demo/repo/issues/38)' \
  "    printf '%s\\n' '{\"state\":\"closed\",\"labels\":[{\"name\":\"night:done\"}]}' ;;" \
  '  equal-fixed:repos/demo/repo/issues/38/events?per_page=100)' \
  "    printf '%s\\n' '[{\"id\":3801,\"event\":\"labeled\",\"label\":{\"name\":\"night:done\"},\"actor\":{\"login\":\"triager\"},\"created_at\":\"2026-07-29T04:00:00Z\"}]' ;;" \
  '  equal-fixed:repos/demo/repo/pulls/39)' \
  "    printf '%s\\n' '{\"state\":\"closed\",\"merged\":true,\"merged_at\":\"2026-07-29T04:00:00Z\",\"merged_by\":{\"login\":\"merger\"},\"labels\":[],\"html_url\":\"https://example/pr/39\",\"user\":{\"login\":\"author\"},\"created_at\":\"2026-07-29T03:00:00Z\",\"head\":{\"sha\":null}}' ;;" \
  '  malformed:*) printf "%s\n" "{broken" ;;' \
  '  api-failure:*) exit 42 ;;' \
  '  *) exit 92 ;;' \
  'esac' \
  > "$fake_gh"
chmod +x "$fake_gh"

assert_github_case() {
  github_name=$1
  github_pr=$2
  github_expected_status=$3
  github_state="$TEST_TMP/github-$github_name-state"
  github_config="$TEST_TMP/github-$github_name.conf"
  github_links="$TEST_TMP/github-$github_name.jsonl"
  github_log="$TEST_TMP/github-$github_name.log"
  write_config "$github_config" "$github_state" "$fake_gh"
  seed_finding "$github_state" gh-finding
  jq -n -c --argjson pr "$github_pr" \
    '{finding_id:"gh-finding",repo_full_name:"demo/repo",pr:$pr}' \
    > "$github_links"
  run_github "$github_config" "$github_links" "$github_name" "$github_log"
  [ -z "$(find "$github_state" -maxdepth 1 -name '.verdict-sync.*' \
    -print -quit)" ] || fail "GitHub $github_name left a staging directory"
  jq -e --arg status "$github_expected_status" '
    select(
      .type == "verdict" and
      .finding_id == "gh-finding" and
      .source == "github" and
      .status == $status
    )
  ' "$github_state/ledger/ledger.jsonl" >/dev/null ||
    fail "GitHub $github_name did not map to $github_expected_status"
  assert_contains 'api --method GET repos/demo/repo/' "$github_log"
  if grep -E \
    '^((issue|pr) (create|edit|comment|close|merge)|api --method (POST|PUT|PATCH|DELETE))' \
    "$github_log" >/dev/null 2>&1; then
    fail "GitHub $github_name requested a write-shaped command"
  fi
}

assert_github_case merged 11 fixed
assert_github_case open 12 adopted
assert_github_case rejected 13 rejected

assert_github_issue_case() {
  github_name=$1
  github_issue=$2
  github_expected_status=$3
  github_state="$TEST_TMP/github-$github_name-state"
  github_config="$TEST_TMP/github-$github_name.conf"
  github_links="$TEST_TMP/github-$github_name.jsonl"
  github_log="$TEST_TMP/github-$github_name.log"
  write_config "$github_config" "$github_state" "$fake_gh"
  seed_finding "$github_state" gh-finding
  jq -n -c --argjson issue "$github_issue" \
    '{finding_id:"gh-finding",repo_full_name:"demo/repo",issue:$issue}' \
    > "$github_links"
  run_github "$github_config" "$github_links" "$github_name" "$github_log"
  jq -e --arg status "$github_expected_status" '
    select(
      .type == "verdict" and
      .finding_id == "gh-finding" and
      .source == "github" and
      .status == $status
    )
  ' "$github_state/ledger/ledger.jsonl" >/dev/null ||
    fail "GitHub $github_name did not map to $github_expected_status"
  [ "$(wc -l < "$github_log" | tr -d ' ')" -eq 2 ] ||
    fail "GitHub $github_name made an unbounded request set"
}

assert_github_issue_case ready-label 21 adopted
assert_github_issue_case done-label 22 fixed

assert_github_link_failure() {
  github_name=$1
  github_link=$2
  github_state="$TEST_TMP/github-$github_name-state"
  github_config="$TEST_TMP/github-$github_name.conf"
  github_links="$TEST_TMP/github-$github_name.jsonl"
  github_log="$TEST_TMP/github-$github_name.log"
  write_config "$github_config" "$github_state" "$fake_gh"
  seed_finding "$github_state" gh-finding
  printf '%s\n' "$github_link" > "$github_links"
  github_before=$(cksum "$github_state/ledger/ledger.jsonl")
  github_rc=0
  run_github "$github_config" "$github_links" "$github_name" "$github_log" ||
    github_rc=$?
  [ "$github_rc" -ne 0 ] || fail "GitHub $github_name unexpectedly succeeded"
  [ "$github_before" = \
    "$(cksum "$github_state/ledger/ledger.jsonl")" ] ||
    fail "GitHub $github_name partially appended"
  [ ! -d "$github_state/verdicts" ] ||
    fail "GitHub $github_name published a draft"
}

assert_github_failure() {
  github_name=$1
  github_pr=$2
  github_link=$(jq -n -c --argjson pr "$github_pr" \
    '{finding_id:"gh-finding",repo_full_name:"demo/repo",pr:$pr}')
  assert_github_link_failure "$github_name" "$github_link"
}

assert_github_failure missing-reason 13
assert_github_failure conflict 14
assert_github_failure malformed 15
assert_github_failure api-failure 16
assert_github_link_failure pagination-comments \
  '{"finding_id":"gh-finding","repo_full_name":"demo/repo","pr":31}'
assert_github_link_failure pagination-events \
  '{"finding_id":"gh-finding","repo_full_name":"demo/repo","issue":32}'
assert_github_link_failure ready-rejected \
  '{"finding_id":"gh-finding","repo_full_name":"demo/repo","issue":33}'
assert_github_link_failure issue-pr-conflict \
  '{"finding_id":"gh-finding","repo_full_name":"demo/repo","issue":34,"pr":35}'
assert_github_link_failure equal-fixed \
  '{"finding_id":"gh-finding","repo_full_name":"demo/repo","issue":38,"pr":39}'

newer_state="$TEST_TMP/github-newer-fixed-state"
newer_config="$TEST_TMP/github-newer-fixed.conf"
newer_links="$TEST_TMP/github-newer-fixed.jsonl"
newer_log="$TEST_TMP/github-newer-fixed.log"
write_config "$newer_config" "$newer_state" "$fake_gh"
seed_finding "$newer_state" gh-finding
printf '%s\n' \
  '{"finding_id":"gh-finding","repo_full_name":"demo/repo","issue":36,"pr":37}' \
  > "$newer_links"
run_github "$newer_config" "$newer_links" newer-fixed "$newer_log"
jq -e '
  select(
    .type == "verdict" and
    .finding_id == "gh-finding" and
    .status == "fixed" and
    .source_ref == "github:demo/repo:issue:36:label-event:3601" and
    .observed_at == "2026-07-29T06:00:00Z"
  )
' "$newer_state/ledger/ledger.jsonl" >/dev/null ||
  fail "newer same-status GitHub observation was not selected"

printf 'test_verdict_sync: PASS\n'
