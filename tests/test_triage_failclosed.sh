#!/bin/bash
set -euo pipefail
# Runtime-computed repository paths cannot be followed by standalone shellcheck.
# shellcheck disable=SC1091

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
# TEST_DIR is resolved at runtime.
# shellcheck disable=SC1091
. "$TEST_DIR/helpers.sh"
# shellcheck source=../lib/common.sh
# ROOT is resolved at runtime.
# shellcheck disable=SC1091
. "$ROOT/lib/common.sh"
# shellcheck source=../lib/triage.sh
# ROOT is resolved at runtime.
# shellcheck disable=SC1091
. "$ROOT/lib/triage.sh"

[ -f "$ROOT/bin/morning-triage" ] || fail "missing bin/morning-triage"
[ -f "$ROOT/lib/triage.sh" ] || fail "missing lib/triage.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/morning-triage-failclosed.XXXXXX")
cleanup() {
  if [ "${TRIAGE_TEST_KEEP_TMP:-0}" = 1 ]; then
    printf 'preserved triage test directory: %s\n' "$TEST_TMP" >&2
    return
  fi
  chmod -R u+w "$TEST_TMP" 2>/dev/null || true
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

STUB_ADAPTER="$ROOT/tests/fixtures/triage/stub-adapter.sh"
FAKE_GH="$ROOT/tests/fixtures/triage/fake-gh.sh"

make_repo_with_history() {
  repo_dir=$1
  mkdir -p "$repo_dir"
  (
    cd "$repo_dir"
    git init >/dev/null
    git config user.name tests
    git config user.email tests@example.com
    mkdir -p src
    cat > src/good.sh <<'EOF'
#!/bin/bash
echo "modern validation guard remains enabled here"
EOF
    cat > src/short.sh <<'EOF'
#!/bin/bash
echo ok
EOF
    cat > src/removed.sh <<'EOF'
#!/bin/bash
echo "legacy removed pattern still exists in this file"
EOF
    cat > src/unrelated.sh <<'EOF'
#!/bin/bash
echo "modern validation guard remains enabled here"
EOF
    cat > src/duplicate.sh <<'EOF'
#!/bin/bash
echo "this deliberately duplicated evidence anchor is long enough"
echo padding-one
echo padding-two
echo "this deliberately duplicated evidence anchor is long enough"
EOF
    cat > src/symbol.sh <<'EOF'
#!/bin/bash
============================
EOF
    ln -s good.sh src/link.sh
    git add src
    GIT_AUTHOR_DATE='2026-08-15T00:00:00Z' \
      GIT_COMMITTER_DATE='2026-08-15T00:00:00Z' \
      git commit -m init >/dev/null

    cat > src/good.sh <<'EOF'
#!/bin/bash
echo "modern validation guard remains enabled here"
echo "post-fix history marker makes this file eligible"
EOF
    printf '%s\n' '# post-finding history' >> src/duplicate.sh
    printf '%s\n' '# post-finding history' >> src/symbol.sh
    git add src/good.sh src/duplicate.sh src/symbol.sh
    GIT_AUTHOR_DATE='2026-08-17T00:00:00Z' \
      GIT_COMMITTER_DATE='2026-08-17T00:00:00Z' \
      git commit -m update-good >/dev/null
  )
}

assert_verify_line_rejected() {
  verify_json=$1
  verify_label=$2
  if printf '%s\n' "$verify_json" | triage_validate_verify_line >/dev/null 2>&1; then
    fail "verify schema accepted $verify_label"
  fi
}

assert_dedup_line_rejected() {
  dedup_json=$1
  dedup_label=$2
  if printf '%s\n' "$dedup_json" | triage_validate_dedup_line >/dev/null 2>&1; then
    fail "dedup schema accepted $dedup_label"
  fi
}

assert_evidence_rejected() {
  evidence_finding=$1
  evidence_result=$2
  evidence_repo=$3
  evidence_sha=$4
  evidence_label=$5
  if triage_evidence_gate_already_fixed \
    "$evidence_finding" \
    "$evidence_result" \
    "$evidence_repo" \
    "$evidence_sha" \
    "$TEST_TMP/reason-$evidence_label"; then
    fail "ALREADY_FIXED evidence gate accepted $evidence_label"
  fi
}

assert_verify_line_rejected 'not-json' 'non-JSON output'
assert_verify_line_rejected \
  '{"finding_id":"rv-x","verdict":"ALREADY_FIXED","file":"x","line":1,"quoted_line":"long enough quoted evidence","removed_pattern":"old","explanation":"x","extra":true}' \
  'unknown key'
assert_verify_line_rejected \
  '{"finding_id":"rv-x","verdict":"CONFIRMED_CURRENT","file":"x","line":1,"quoted_line":"long enough quoted evidence","explanation":"x"}' \
  'missing removed_pattern key'
printf '%s\n' \
  '{"finding_id":"rv-x","verdict":"CONFIRMED_CURRENT","file":"x","line":1,"quoted_line":"long enough quoted evidence","removed_pattern":"","explanation":"x"}' |
  triage_validate_verify_line >/dev/null ||
  fail 'verify schema rejected the required empty non-fixed removed_pattern'
assert_dedup_line_rejected \
  '{"finding_id":"rv-x","verdict":"DUPLICATE","confidence":"high","shared_defect":"same"}' \
  'duplicate without canonical_id'
assert_dedup_line_rejected \
  '{"finding_id":"rv-x","verdict":"DUPLICATE","canonical_id":"rv-c","confidence":"certain","shared_defect":"same"}' \
  'unknown confidence'

cache_state="$TEST_TMP/cache-state"
cache_work="$TEST_TMP/cache-work"
cache_prompt="$TEST_TMP/cache-prompt.md"
cache_response="$TEST_TMP/cache-response.jsonl"
cache_queue="$TEST_TMP/cache-queue"
mkdir -p "$cache_state" "$cache_work" "$TEST_TMP/cache-out-1" "$TEST_TMP/cache-out-2"
printf '%s\n' 'deterministic prompt' > "$cache_prompt"
printf '%s\n' '{"finding_id":"rv-cache","verdict":"UNCLEAR","file":"x","line":1,"quoted_line":"long enough quoted evidence","removed_pattern":"","explanation":"cached"}' \
  > "$cache_response"
printf '%s\n' "$cache_response" > "$cache_queue"
# These globals configure triage_adapter_run from the sourced library.
# shellcheck disable=SC2034
STATE_DIR="$cache_state"
# shellcheck disable=SC2034
TRIAGE_ADAPTER="$STUB_ADAPTER"
# shellcheck disable=SC2034
TRIAGE_LLM_CACHE_DIR="$cache_state/llm-cache"
TRIAGE_STUB_QUEUE_FILE="$cache_queue" \
  triage_adapter_run verify "$cache_prompt" "$cache_work" \
  "$TEST_TMP/cache-out-1" >/dev/null || fail 'cache record call failed'
TRIAGE_STUB_FAIL=1 TRIAGE_STUB_QUEUE_FILE="$cache_queue" \
  triage_adapter_run verify "$cache_prompt" "$cache_work" \
  "$TEST_TMP/cache-out-2" >/dev/null ||
  fail 'cache replay called the deliberately failing adapter'
cmp "$TEST_TMP/cache-out-1/candidates.jsonl" \
  "$TEST_TMP/cache-out-2/candidates.jsonl" >/dev/null ||
  fail 'cache replay changed the recorded adapter response'

seed_finding() {
  state_dir=$1
  finding_id=$2
  target=$3
  symptom=$4
  date_value=${5:-2026-08-16}
  mkdir -p "$state_dir/ledger"
  jq -n -c \
    --arg id "$finding_id" \
    --arg target "$target" \
    --arg symptom "$symptom" \
    --arg date "$date_value" '
      {
        ts: "2026-08-17T00:00:00Z",
        night_id: "2026-08-16",
        type: "finding",
        id: $id,
        repo: "demo",
        target: $target,
        symptom: $symptom,
        kind: "Bug",
        status: "open",
        confirm_cost: "1分",
        date: $date
      }
    ' >> "$state_dir/ledger/ledger.jsonl"
}

write_config() {
  config_path=$1
  state_dir=$2
  printf '%s\n' \
    "NIGHTSHIFT_STATE_DIR='$state_dir'" \
    "LANE_CMD_1=':'" \
    "LANE_HOME_LINKS=''" \
    "VERDICT_GH_BIN='$FAKE_GH'" \
    "TRIAGE_ENABLED=1" \
    "TRIAGE_ALREADY_FIXED_MODE='reject'" \
    "TRIAGE_ADAPTER='$STUB_ADAPTER'" \
    "TRIAGE_REPORT_ISSUE='123'" \
    "TRIAGE_TARGET_REPOS='demo=owner/demo'" \
    "TRIAGE_MAX_NEW_FOR_DEDUP=0" \
    "TRIAGE_MAX_VERIFY_PER_RUN=20" \
    "TRIAGE_VERIFY_BATCH=20" \
    "TRIAGE_DEDUP_BATCH=5" \
    "TRIAGE_CONCURRENCY=1" \
    "TRIAGE_HARD_WALL='23:59'" \
    > "$config_path"
}

run_triage() {
  config_path=$1
  shift
  FAKE_GH_FIXTURE_DIR="$TEST_TMP" \
    NIGHTSHIFT_CONFIG="$config_path" \
    /bin/bash "$ROOT/bin/morning-triage" "$@"
}

window_state="$TEST_TMP/window-state"
window_config="$TEST_TMP/window.conf"
fake_bin="$TEST_TMP/fake-bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/date" <<'EOF'
#!/bin/bash
set -euo pipefail
case "${*: -1}" in
  +%F) printf '%s\n' '2026-08-17' ;;
  +%H:%M) printf '%s\n' '05:59' ;;
  -u) /bin/date "$@" ;;
  *) printf '%s\n' '2026-08-17T05:59:00Z' ;;
esac
EOF
chmod +x "$fake_bin/date"
write_config "$window_config" "$window_state"
PATH="$fake_bin:/usr/bin:/bin" run_triage "$window_config" --dry-run >/dev/null
[ ! -d "$window_state/ledger" ] ||
  [ ! -f "$window_state/ledger/ledger.jsonl" ] ||
  [ "$(wc -l < "$window_state/ledger/ledger.jsonl" | tr -d ' ')" -eq 0 ] ||
  fail "window guard unexpectedly mutated state"

lock_state="$TEST_TMP/lock-state"
lock_config="$TEST_TMP/lock.conf"
mkdir -p "$lock_state/locks/nightshift.lock"
printf 'pid=999999\nstarted_at=2000-01-01T00:00:00Z\n' \
  > "$lock_state/locks/nightshift.lock/meta"
write_config "$lock_config" "$lock_state"
lock_rc=0
run_triage "$lock_config" --dry-run --force >/dev/null 2>&1 || lock_rc=$?
[ "$lock_rc" -eq 1 ] || fail "held triage lock returned $lock_rc instead of 1"

actor_state="$TEST_TMP/actor-state"
actor_config="$TEST_TMP/actor.conf"
seed_finding "$actor_state" "rv-preexisting-actor" "src/good.sh:2" \
  "preexisting actor collision"
printf '%s\n' \
  '{"type":"verdict","verdict_id":"preexisting-auto-triage","ts":"2026-08-17T01:00:00Z","finding_id":"rv-preexisting-actor","status":"rejected","actor":"auto-triage","source":"manual-comment","source_ref":"comment:collision","observed_at":"2026-08-17T01:00:00Z","rejection_reason":"prior unowned identity"}' \
  >> "$actor_state/ledger/ledger.jsonl"
write_config "$actor_config" "$actor_state"
actor_rc=0
run_triage "$actor_config" --dry-run --force >/dev/null 2>&1 || actor_rc=$?
[ "$actor_rc" -eq 1 ] ||
  fail "preexisting auto-triage actor collision returned $actor_rc instead of 1"

dry_state="$TEST_TMP/dry-state"
dry_repo="$TEST_TMP/dry-repo"
dry_config="$TEST_TMP/dry.conf"
dry_table="$TEST_TMP/dry-table.tsv"
make_repo_with_history "$dry_repo"
dry_sha=$(cd "$dry_repo" && git rev-parse HEAD)
gate_finding='{"id":"rv-gate","target":"src/good.sh:2","date":"2026-08-16"}'
gate_good='{"finding_id":"rv-gate","verdict":"ALREADY_FIXED","file":"src/good.sh","line":2,"quoted_line":"echo \"modern validation guard remains enabled here\"","removed_pattern":"legacy_removed_guard","explanation":"safe replacement is present"}'
gate_reason="$TEST_TMP/reason-good"
triage_evidence_gate_already_fixed \
  "$gate_finding" "$gate_good" "$dry_repo" "$dry_sha" "$gate_reason" ||
  fail "valid ALREADY_FIXED evidence did not pass all six gates"
assert_contains "already fixed on main $dry_sha" "$gate_reason"
assert_contains '(src/good.sh:2); not a false positive' "$gate_reason"

assert_evidence_rejected "$gate_finding" \
  '{"file":"../outside.sh","line":2,"quoted_line":"echo \"modern validation guard remains enabled here\"","removed_pattern":"legacy","explanation":"bad path"}' \
  "$dry_repo" "$dry_sha" unsafe-path
assert_evidence_rejected "$gate_finding" \
  '{"file":"src/link.sh","line":2,"quoted_line":"echo \"modern validation guard remains enabled here\"","removed_pattern":"legacy","explanation":"link"}' \
  "$dry_repo" "$dry_sha" symlink
assert_evidence_rejected "$gate_finding" \
  '{"file":"src/good.sh","line":999,"quoted_line":"echo \"modern validation guard remains enabled here\"","removed_pattern":"legacy","explanation":"range"}' \
  "$dry_repo" "$dry_sha" line-range
assert_evidence_rejected "$gate_finding" \
  '{"file":"src/good.sh","line":2,"quoted_line":"echo \"a different existing-looking line entirely\"","removed_pattern":"legacy","explanation":"mismatch"}' \
  "$dry_repo" "$dry_sha" exact-line
assert_evidence_rejected \
  '{"id":"rv-gate","target":"src/unrelated.sh:2","date":"2026-08-16"}' \
  "$gate_good" "$dry_repo" "$dry_sha" unrelated-existing-line
assert_evidence_rejected \
  '{"id":"rv-gate","target":"src/short.sh:2","date":"2026-08-16"}' \
  '{"file":"src/short.sh","line":2,"quoted_line":"echo ok","removed_pattern":"legacy","explanation":"short"}' \
  "$dry_repo" "$dry_sha" short-line
assert_evidence_rejected \
  '{"id":"rv-gate","target":"src/symbol.sh:2","date":"2026-08-16"}' \
  '{"file":"src/symbol.sh","line":2,"quoted_line":"============================","removed_pattern":"legacy","explanation":"symbols"}' \
  "$dry_repo" "$dry_sha" symbol-only
assert_evidence_rejected \
  '{"id":"rv-gate","target":"src/duplicate.sh:2","date":"2026-08-16"}' \
  '{"file":"src/duplicate.sh","line":2,"quoted_line":"echo \"this deliberately duplicated evidence anchor is long enough\"","removed_pattern":"legacy","explanation":"duplicate"}' \
  "$dry_repo" "$dry_sha" duplicate-window
assert_evidence_rejected \
  '{"id":"rv-gate","target":"src/removed.sh:2","date":"2026-08-16"}' \
  '{"file":"src/removed.sh","line":2,"quoted_line":"echo \"legacy removed pattern still exists in this file\"","removed_pattern":"legacy removed pattern","explanation":"present"}' \
  "$dry_repo" "$dry_sha" removed-pattern-present
assert_evidence_rejected "$gate_finding" \
  '{"file":"src/good.sh","line":2,"quoted_line":"echo \"modern validation guard remains enabled here\"","removed_pattern":"[","explanation":"invalid regex"}' \
  "$dry_repo" "$dry_sha" invalid-extended-regex
assert_evidence_rejected \
  '{"id":"rv-gate","target":"src/unrelated.sh:2","date":"2026-08-16"}' \
  '{"file":"src/unrelated.sh","line":2,"quoted_line":"echo \"modern validation guard remains enabled here\"","removed_pattern":"legacy","explanation":"history"}' \
  "$dry_repo" "$dry_sha" no-post-finding-history

long_explanation=$(printf '%0260d' 0 | tr '0' x)
sanitized_result=$(printf '%s\n' "$gate_good" | jq -c \
  --arg explanation "$long_explanation | injected" \
  '.explanation = $explanation')
sanitized_reason="$TEST_TMP/reason-sanitized"
triage_evidence_gate_already_fixed \
  "$gate_finding" "$sanitized_result" "$dry_repo" "$dry_sha" "$sanitized_reason" ||
  fail 'sanitization fixture unexpectedly failed the physical evidence gates'
assert_not_contains '|' "$sanitized_reason"
[ "$(wc -c < "$sanitized_reason" | tr -d ' ')" -le 350 ] ||
  fail 'LLM explanation was not capped before entering rejection_reason'
seed_finding "$dry_state" "rv-bug-seat-good-aaaa1111" "src/good.sh:2" \
  "good verify candidate"
seed_finding "$dry_state" "rv-bug-seat-short-bbbb2222" "src/short.sh:2" \
  "short quoted line candidate"
seed_finding "$dry_state" "rv-bug-seat-removed-cccc3333" "src/removed.sh:2" \
  "removed pattern still present"
seed_finding "$dry_state" "rv-bug-seat-history-dddd4444" "src/unrelated.sh:2" \
  "no history after finding date" "2026-08-18"
seed_finding "$dry_state" "rv-bug-seat-badjson-eeee5555" "src/good.sh:2" \
  "malformed adapter line"
seed_finding "$dry_state" "rv-bug-seat-wrongid-ffff6666" "src/good.sh:2" \
  "schema-valid response names a different finding"
cat > "$dry_table" <<'EOF'
verify	rv-bug-seat-good-aaaa1111	{"finding_id":"rv-bug-seat-good-aaaa1111","verdict":"ALREADY_FIXED","file":"src/good.sh","line":2,"quoted_line":"echo \"modern validation guard remains enabled here\"","removed_pattern":"legacy_removed_guard","explanation":"good evidence chain"}
verify	rv-bug-seat-short-bbbb2222	{"finding_id":"rv-bug-seat-short-bbbb2222","verdict":"ALREADY_FIXED","file":"src/short.sh","line":2,"quoted_line":"echo ok","removed_pattern":"legacy_short_guard","explanation":"too short must fail"}
verify	rv-bug-seat-removed-cccc3333	{"finding_id":"rv-bug-seat-removed-cccc3333","verdict":"ALREADY_FIXED","file":"src/removed.sh","line":2,"quoted_line":"echo \"legacy removed pattern still exists in this file\"","removed_pattern":"legacy removed pattern still exists","explanation":"removed pattern remains"}
verify	rv-bug-seat-history-dddd4444	{"finding_id":"rv-bug-seat-history-dddd4444","verdict":"ALREADY_FIXED","file":"src/unrelated.sh","line":2,"quoted_line":"echo \"modern validation guard remains enabled here\"","removed_pattern":"legacy_unrelated_guard","explanation":"history gate must fail"}
verify	rv-bug-seat-badjson-eeee5555	not-json
verify	rv-bug-seat-wrongid-ffff6666	{"finding_id":"rv-not-in-this-batch","verdict":"UNCLEAR","file":"src/good.sh","line":2,"quoted_line":"echo \"modern validation guard remains enabled here\"","removed_pattern":"","explanation":"wrong finding id"}
EOF
write_config "$dry_config" "$dry_state"
TRIAGE_STUB_RESPONSE_TABLE="$dry_table" \
  run_triage "$dry_config" --dry-run --force \
  --repo-pin "demo=$dry_sha@$dry_repo" >/dev/null
dry_draft=$(find "$dry_state" -name 'decisions.draft.jsonl' -print | sed -n '1p')
[ -n "$dry_draft" ] || fail "fail-closed dry-run did not write decisions.draft.jsonl"
[ "$(wc -l < "$dry_draft" | tr -d ' ')" -eq 1 ] ||
  fail "fail-closed dry-run expected exactly one accepted verify decision"
[ "$(jq -r '.finding_id' "$dry_draft")" = "rv-bug-seat-good-aaaa1111" ] ||
  fail "fail-closed dry-run let a bad verify decision through"

gh_state="$TEST_TMP/gh-state"
gh_repo="$TEST_TMP/gh-repo"
gh_config="$TEST_TMP/gh.conf"
gh_table="$TEST_TMP/gh-table.tsv"
make_repo_with_history "$gh_repo"
gh_sha=$(cd "$gh_repo" && git rev-parse HEAD)
seed_finding "$gh_state" "rv-bug-seat-gh-ffff6666" "src/good.sh:2" \
  "good verify candidate"
cat > "$gh_table" <<'EOF'
verify	rv-bug-seat-gh-ffff6666	{"finding_id":"rv-bug-seat-gh-ffff6666","verdict":"ALREADY_FIXED","file":"src/good.sh","line":2,"quoted_line":"echo \"modern validation guard remains enabled here\"","removed_pattern":"legacy_removed_guard","explanation":"good evidence chain"}
EOF
write_config "$gh_config" "$gh_state"
gh_rc=0
FAKE_GH_FAIL_POST=1 TRIAGE_STUB_RESPONSE_TABLE="$gh_table" \
  run_triage "$gh_config" --force --repo-pin "demo=$gh_sha@$gh_repo" \
  >/dev/null 2>&1 || gh_rc=$?
[ "$gh_rc" -ne 0 ] || fail "GitHub failure did not fail closed"
[ "$(jq -r 'select(.type == "verdict" and .actor == "auto-triage") | .finding_id' \
  "$gh_state/ledger/ledger.jsonl" | wc -l | tr -d ' ')" -eq 0 ] ||
  fail "GitHub failure still appended an auto-triage verdict"

deadline_state="$TEST_TMP/deadline-state"
deadline_config="$TEST_TMP/deadline.conf"
deadline_table="$TEST_TMP/deadline-table.tsv"
deadline_log="$TEST_TMP/deadline-adapter.log"
seed_finding "$deadline_state" "rv-bug-seat-deadline-11112222" \
  "src/good.sh:2" "deadline candidate"
cat > "$deadline_table" <<'EOF'
verify	rv-bug-seat-deadline-11112222	{"finding_id":"rv-bug-seat-deadline-11112222","verdict":"ALREADY_FIXED","file":"src/good.sh","line":2,"quoted_line":"echo \"modern validation guard remains enabled here\"","removed_pattern":"legacy_removed_guard","explanation":"would pass without deadline"}
EOF
write_config "$deadline_config" "$deadline_state"
printf '%s\n' "TRIAGE_PHASE_A_DEADLINE_SEC=0" >> "$deadline_config"
TRIAGE_STUB_LOG_FILE="$deadline_log" \
  TRIAGE_STUB_RESPONSE_TABLE="$deadline_table" \
  run_triage "$deadline_config" --dry-run --force \
  --repo-pin "demo=$dry_sha@$dry_repo" >/dev/null
[ ! -s "$deadline_log" ] ||
  fail 'Phase A deadline still allowed an adapter invocation'
deadline_draft=$(find "$deadline_state" -name decisions.draft.jsonl -print |
  sed -n '1p')
[ -n "$deadline_draft" ] && [ ! -s "$deadline_draft" ] ||
  fail 'Phase A deadline leaked a decision'

wall_state="$TEST_TMP/wall-state"
wall_config="$TEST_TMP/wall.conf"
wall_table="$TEST_TMP/wall-table.tsv"
wall_gh_log="$TEST_TMP/wall-gh.log"
wall_bin="$TEST_TMP/wall-bin"
mkdir -p "$wall_bin"
cat > "$wall_bin/date" <<'EOF'
#!/bin/bash
set -euo pipefail
if [ "${*: -1}" = '+%H:%M' ]; then
  printf '%s\n' '23:59'
else
  /bin/date "$@"
fi
EOF
chmod +x "$wall_bin/date"
seed_finding "$wall_state" "rv-bug-seat-wall-33334444" \
  "src/good.sh:2" "hard wall candidate"
cat > "$wall_table" <<'EOF'
verify	rv-bug-seat-wall-33334444	{"finding_id":"rv-bug-seat-wall-33334444","verdict":"ALREADY_FIXED","file":"src/good.sh","line":2,"quoted_line":"echo \"modern validation guard remains enabled here\"","removed_pattern":"legacy_removed_guard","explanation":"must remain local after hard wall"}
EOF
write_config "$wall_config" "$wall_state"
printf '%s\n' "TRIAGE_HARD_WALL='00:00'" >> "$wall_config"
wall_rc=0
PATH="$wall_bin:/usr/bin:/bin" FAKE_GH_LOG="$wall_gh_log" \
  TRIAGE_STUB_RESPONSE_TABLE="$wall_table" \
  run_triage "$wall_config" --force \
  --repo-pin "demo=$dry_sha@$dry_repo" >/dev/null 2>&1 || wall_rc=$?
[ "$wall_rc" -ne 0 ] || fail 'hard wall overrun reported success'
[ ! -s "$wall_gh_log" ] || fail 'hard wall overrun contacted GitHub'
[ "$(jq -r 'select(.type == "verdict" and .actor == "auto-triage") | .finding_id' \
  "$wall_state/ledger/ledger.jsonl" | wc -l | tr -d ' ')" -eq 0 ] ||
  fail 'hard wall overrun appended an auto-triage verdict'

printf 'test_triage_failclosed: PASS\n'
