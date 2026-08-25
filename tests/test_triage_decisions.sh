#!/bin/bash
set -euo pipefail
# Runtime-computed sources and globals consumed by sourced triage/ledger
# functions are intentionally invisible to standalone shellcheck.
# shellcheck disable=SC1091,SC2034

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
# TEST_DIR is resolved at runtime.
# shellcheck disable=SC1091
. "$TEST_DIR/helpers.sh"
# TEST_DIR is resolved at runtime.
# shellcheck disable=SC1091
. "$TEST_DIR/fixtures/triage/lib.sh"
# shellcheck source=../lib/triage.sh
# ROOT is resolved at runtime.
# shellcheck disable=SC1091
. "$ROOT/lib/triage.sh"
# shellcheck source=../lib/common.sh
# ROOT is resolved at runtime.
# shellcheck disable=SC1091
. "$ROOT/lib/common.sh"
# shellcheck source=../lib/ledger.sh
# ROOT is resolved at runtime.
# shellcheck disable=SC1091
. "$ROOT/lib/ledger.sh"

[ -f "$ROOT/bin/morning-triage" ] || fail "missing bin/morning-triage"

sanitized_anchor=$(triage_sanitize_anchor \
  $'app/unsafe`anchor|name.sh:\t12\nignored-abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz')
case "$sanitized_anchor" in
  *'`'*|*'|'*|*$'\t'*|*$'\n'*) fail 'decision anchor retained unsafe delimiters' ;;
esac
[ "${#sanitized_anchor}" -le 60 ] || fail 'decision anchor exceeded 60 characters'

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-triage-decisions.XXXXXX")
cleanup() {
  if [ "${TRIAGE_TEST_KEEP_TMP:-0}" = 1 ]; then
    printf 'preserved triage test directory: %s\n' "$TEST_TMP" >&2
    return
  fi
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

b25_dir="$TEST_TMP/b25"
mkdir -p "$b25_dir"
# This global configures triage_assert_all_rejected from the sourced library.
# shellcheck disable=SC2034
TRIAGE_WORK_DIR="$b25_dir"
printf '%s\n' '{"status":"adopted"}' > "$b25_dir/decisions.jsonl"
if triage_assert_all_rejected; then
  fail 'B2.5 accepted a non-rejected automatic decision'
fi
printf '%s\n' '{"status":"rejected"}' > "$b25_dir/decisions.jsonl"
triage_assert_all_rejected || fail 'B2.5 rejected an all-rejected decision batch'

b1_state="$TEST_TMP/b1-state"
b1_work="$TEST_TMP/b1-work"
STATE_DIR="$b1_state"
# This global configures triage_revalidate_drafts from the sourced library.
# shellcheck disable=SC2034
TRIAGE_WORK_DIR="$b1_work"
mkdir -p "$b1_work"
triage_seed_finding \
  "$b1_state" target-settled demo app/render.sh:5 settled Bug 2026-08-10
triage_seed_verdict \
  "$b1_state" target-settled adopted 2026-08-11T00:00:00Z human comment:settled
triage_seed_finding \
  "$b1_state" canonical-became-open demo app/render.sh:5 canonical Bug 2026-08-10
triage_seed_finding \
  "$b1_state" duplicate-target demo app/render.sh:5 duplicate Bug 2026-08-10
cat > "$b1_work/decisions.draft.jsonl" <<'EOF'
{"finding_id":"target-settled","status":"rejected","actor":"auto-triage","source":"manual-comment","observed_at":"2026-08-18T00:00:00Z","rejection_reason":"already fixed on main abc: evidence (app/render.sh:5); not a false positive"}
{"finding_id":"duplicate-target","status":"rejected","actor":"auto-triage","source":"manual-comment","observed_at":"2026-08-18T00:00:00Z","rejection_reason":"duplicate of canonical-became-open (same defect; evidence app/render.sh:5); not a false positive"}
EOF
triage_stats_init
triage_revalidate_drafts
[ ! -s "$b1_work/decisions.draft.jsonl" ] ||
  fail 'B1 retained a settled target or open canonical decision'
jq -e '
  .decision_drops_target == 1 and .decision_drops_canonical == 1
' "$b1_work/stats.json" >/dev/null ||
  fail 'B1 did not separately count target and canonical drops'

repo_src="$TEST_TMP/repo-src"
triage_copy_repo_fixture "$repo_src"
triage_init_git_repo "$repo_src"
triage_git_commit_all "$repo_src" "2026-08-01T00:00:00Z" "seed fixture repo"
repo_sha=$(git -C "$repo_src" rev-parse HEAD)

state="$TEST_TMP/state"
gh_dir="$TEST_TMP/fake-gh"
config="$TEST_TMP/nightshift.conf"
queue="$TEST_TMP/adapter.queue"
adapter_log="$TEST_TMP/adapter.log"
gh_log="$TEST_TMP/gh.log"
lock_log="$TEST_TMP/lock-at-post.log"
mkdir -p "$state" "$gh_dir"
triage_write_config \
  "$config" \
  "$state" \
  "$TEST_DIR/fixtures/triage/fake-gh.sh"
triage_seed_report_issue "$gh_dir" demo/repo 201

malicious_marker="$TEST_TMP/command-substitution-ran"
backtick_marker="$TEST_TMP/backtick-ran"
malicious_symptom=$(cat <<EOF
same underlying guard issue; \$(touch $malicious_marker) and \`touch $backtick_marker\` must stay inert
EOF
)

triage_seed_finding \
  "$state" \
  canon-adopted \
  demo \
  app/render.sh:5 \
  "canonical adopted finding" \
  Bug \
  2026-08-10
triage_seed_verdict \
  "$state" \
  canon-adopted \
  adopted \
  2026-08-11T00:00:00Z \
  human \
  comment:canon-adopted
triage_seed_finding \
  "$state" \
  canon-deferred \
  demo \
  app/render.sh:5 \
  "canonical deferred finding" \
  Bug \
  2026-08-10
triage_seed_verdict \
  "$state" \
  canon-deferred \
  rejected \
  2026-08-11T00:00:01Z \
  human \
  comment:canon-deferred \
  "deferred pending owner decision"
triage_seed_finding \
  "$state" \
  dup-adopted \
  demo \
  'app/render`tick.sh:5' \
  "$malicious_symptom" \
  Bug \
  2026-08-12
triage_seed_finding \
  "$state" \
  dup-deferred \
  demo \
  app/render.sh:5 \
  "shares the deferred canonical defect" \
  Bug \
  2026-08-12

resp_adopted="$TEST_TMP/dedup-adopted.jsonl"
resp_deferred="$TEST_TMP/dedup-deferred.jsonl"
verify_adopted="$TEST_TMP/verify-adopted.jsonl"
verify_deferred="$TEST_TMP/verify-deferred.jsonl"
printf '%s\n' \
  '{"finding_id":"dup-adopted","verdict":"DUPLICATE","canonical_id":"canon-adopted","confidence":"high","shared_defect":"same guard removal"}' \
  > "$resp_adopted"
printf '%s\n' \
  '{"finding_id":"dup-deferred","verdict":"DUPLICATE","canonical_id":"canon-deferred","confidence":"high","shared_defect":"same deferred defect"}' \
  > "$resp_deferred"
printf '%s\n' \
  '{"finding_id":"dup-adopted","verdict":"CONFIRMED_CURRENT","file":"app/render.sh","line":5,"quoted_line":"current evidence","removed_pattern":"","explanation":"still current"}' \
  > "$verify_adopted"
printf '%s\n' \
  '{"finding_id":"dup-deferred","verdict":"CONFIRMED_CURRENT","file":"app/render.sh","line":5,"quoted_line":"current evidence","removed_pattern":"","explanation":"still current"}' \
  > "$verify_deferred"
printf '%s\n' \
  "$resp_adopted" \
  "$resp_deferred" \
  "$verify_adopted" \
  "$verify_deferred" > "$queue"

export TRIAGE_FAKE_GH_DIR="$gh_dir"
export TRIAGE_FAKE_GH_LOG="$gh_log"
export TRIAGE_STUB_QUEUE_FILE="$queue"
export TRIAGE_STUB_LOG_FILE="$adapter_log"
export NIGHTSHIFT_CONFIG="$config"
# Pin the report-issue repo instead of letting morning-triage derive it from
# this checkout's ambient `git remote.origin.url` (lib/triage.sh
# triage_current_repo_full_name), which varies by machine/clone and made this
# assertion pass or fail depending on where the repo was checked out from.
export TRIAGE_REPORT_REPO_FULL_NAME="caty-ai/alpha-nightshift"

mkdir -p "$state/triage/state"
printf '%s\n' '2026-08-01T00:00:00Z' > "$state/triage/last-run-watermark"
printf '%s\n' '"carry-sentinel"' > \
  "$state/triage/state/dedup-carryover.jsonl"

/bin/bash "$ROOT/bin/morning-triage" \
  --dry-run \
  --force \
  --repo-pin "demo=$repo_sha@$repo_src" >/dev/null

draft="$state/triage/decisions.draft.jsonl"
report="$state/triage/report.md"
watermark_file="$state/triage/last-run-watermark"
[ -f "$draft" ] || fail "dry-run did not write decisions.draft.jsonl"
[ -f "$report" ] || fail "dry-run did not write report.md"
[ "$(wc -c < "$report" | tr -d ' ')" -le 61440 ] ||
  fail 'report exceeded the 60KB comment budget'
[ "$(cat "$watermark_file")" = '2026-08-01T00:00:00Z' ] ||
  fail 'dry-run polluted last-run-watermark'
[ "$(cat "$state/triage/state/dedup-carryover.jsonl")" = '"carry-sentinel"' ] ||
  fail 'dry-run polluted dedup carryover state'
[ ! -f "$state/triage/decisions.jsonl" ] ||
  fail "dry-run unexpectedly wrote decisions.jsonl"
[ "$(wc -l < "$draft" | tr -d ' ')" -eq 2 ] ||
  fail "dry-run did not emit both rejected decisions"
for required_section in \
  '自動却下' \
  'fixed 推奨' \
  '採用候補' \
  'regression 疑い' \
  '既知修正済み同型疑い' \
  'クラスタ提示' \
  'dup 疑い' \
  '要人裁定' \
  '残差' \
  '再発見回数'; do
  assert_contains "$required_section" "$report"
done
if [ -e "$malicious_marker" ] || [ -e "$backtick_marker" ]; then
  fail "template/rendering executed shell content from findings"
fi

jq -e -s '
  all(
    .actor == "auto-triage" and
    .source == "manual-comment" and
    .status == "rejected" and
    (has("source_ref") | not)
  )
' "$draft" >/dev/null || fail "draft decisions do not use the fixed triage identity"

observed_count=$(jq -r '.observed_at' "$draft" | sort -u | wc -l | tr -d ' ')
[ "$observed_count" -eq 1 ] || fail "draft decisions do not share a single watermark"

assert_contains 'duplicate of canon-adopted' "$draft"
assert_contains 'duplicate of canon-deferred' "$draft"
assert_contains 'canonical is deferred' "$draft"
assert_contains 'evidence app/render.sh:5' "$draft"
jq -e '
  select(.finding_id == "dup-adopted") |
  (.rejection_reason | contains("evidence app/rendertick.sh:5")) and
  (.rejection_reason | contains("`") | not)
' "$draft" >/dev/null ||
  fail 'file:line-shaped decision anchor bypassed sanitization'
triage_decisions_validate_with_dummy_source "$draft" "$ROOT" ||
  fail "draft decisions do not pass verdict_validate_decision once source_ref is injected"

printf '%s\n' \
  "$resp_adopted" \
  "$resp_deferred" \
  "$verify_adopted" \
  "$verify_deferred" > "$queue"
TRIAGE_FAKE_GH_LOCK_PATH="$state/locks/nightshift.lock" \
  TRIAGE_FAKE_GH_LOCK_LOG="$lock_log" \
  /bin/bash "$ROOT/bin/morning-triage" \
  --force \
  --repo-pin "demo=$repo_sha@$repo_src" >/dev/null

final_decisions="$state/triage/decisions.jsonl"
[ -f "$final_decisions" ] || fail "full run did not write decisions.jsonl"
[ "$(wc -l < "$final_decisions" | tr -d ' ')" -eq 2 ] ||
  fail "full run did not preserve the rejected decision count"
jq -e -s 'all(.[]; .source_ref == "https://github.com/caty-ai/alpha-nightshift/issues/201#issuecomment-1")' \
  "$final_decisions" >/dev/null ||
  fail "final decisions did not backfill the verified report comment URL"
report_post_body=$(jq -r \
  'select(.method == "POST") | .body' "$gh_log" | sed -n '1,/^$/p')
printf '%s\n' "$report_post_body" | grep -F '# morning-triage report' >/dev/null ||
  fail 'GitHub report comment body was not Markdown'
if printf '%s\n' "$report_post_body" | jq -e . >/dev/null 2>&1; then
  fail 'GitHub report comment body was parseable as standalone JSON'
fi
[ "$(sed -n '1p' "$lock_log")" = present ] ||
  fail 'B2 report POST did not observe nightshift.lock as held'
[ "$(sed -n '2p' "$lock_log")" = absent ] ||
  fail 'B4 result POST unexpectedly observed nightshift.lock as held'
jq -e '.verified | length == 2' "$state/triage/state/triage-state.json" >/dev/null ||
  fail 'successful full run did not persist verification timestamps'
[ "$(wc -l < "$state/triage/verified.jsonl" | tr -d ' ')" -eq 2 ] ||
  fail 'successful full run did not republish current verified state'

# This global configures the sourced ledger projector.
# shellcheck disable=SC2034
STATE_DIR="$state"
[ "$(ledger_get_current_finding dup-adopted | jq -r '.current_status')" = rejected ] ||
  fail "full run did not append the dup-adopted verdict"
[ "$(ledger_get_current_finding dup-deferred | jq -r '.current_status')" = rejected ] ||
  fail "full run did not append the dup-deferred verdict"

auto_verdict_count=$(jq -r \
  'select(.type == "verdict" and .actor == "auto-triage") | .finding_id' \
  "$state/ledger/ledger.jsonl" | wc -l | tr -d ' ')
/bin/bash "$ROOT/bin/morning-triage" \
  --force \
  --repo-pin "demo=$repo_sha@$repo_src" >/dev/null ||
  fail 'a successful run was blocked by its own prior auto-triage verdicts'
[ "$(jq -r 'select(.type == "verdict" and .actor == "auto-triage") | .finding_id' \
  "$state/ledger/ledger.jsonl" | wc -l | tr -d ' ')" -eq "$auto_verdict_count" ] ||
  fail 'no-decision rerun unexpectedly appended another auto-triage verdict'

carry_state="$TEST_TMP/carry-state"
carry_gh="$TEST_TMP/carry-gh"
carry_config="$TEST_TMP/carry.conf"
carry_extra="$TEST_TMP/carry-extra.conf"
carry_table="$TEST_TMP/carry-table.tsv"
carry_adapter_log="$TEST_TMP/carry-adapter.log"
mkdir -p "$carry_state" "$carry_gh"
printf '%s\n' \
  "TRIAGE_MAX_NEW_FOR_DEDUP='1'" \
  "TRIAGE_MAX_VERIFY_PER_RUN='0'" \
  "TRIAGE_DEDUP_BATCH='1'" > "$carry_extra"
triage_write_config \
  "$carry_config" \
  "$carry_state" \
  "$TEST_DIR/fixtures/triage/fake-gh.sh" \
  "$carry_extra"
triage_seed_report_issue "$carry_gh" caty-ai/alpha-nightshift 201
triage_seed_finding \
  "$carry_state" carry-canonical demo app/render.sh:5 \
  'canonical comparison finding' Bug 2026-08-10
triage_seed_verdict \
  "$carry_state" carry-canonical adopted 2026-08-11T00:00:00Z human \
  comment:carry-canonical
triage_seed_finding \
  "$carry_state" carry-a demo app/render.sh:6 \
  'first distinct carryover candidate' Bug 2026-08-12
triage_seed_finding \
  "$carry_state" carry-b demo app/render.sh:7 \
  'second distinct carryover candidate' Bug 2026-08-12
cat > "$carry_table" <<'EOF'
dedup	carry-a	{"finding_id":"carry-a","verdict":"DISTINCT","confidence":"high"}
dedup	carry-b	{"finding_id":"carry-b","verdict":"DISTINCT","confidence":"high"}
EOF
env -u TRIAGE_STUB_QUEUE_FILE \
  TRIAGE_FAKE_GH_DIR="$carry_gh" \
  TRIAGE_STUB_RESPONSE_TABLE="$carry_table" \
  TRIAGE_STUB_LOG_FILE="$carry_adapter_log" \
  NIGHTSHIFT_CONFIG="$carry_config" \
  /bin/bash "$ROOT/bin/morning-triage" --force \
  --repo-pin "demo=$repo_sha@$repo_src" >/dev/null
carry_state_file="$carry_state/triage/state/dedup-carryover.jsonl"
[ "$(cat "$carry_state_file")" = '"carry-b"' ] ||
  fail 'first bounded run did not persist the overflow finding as carryover'
[ "$(wc -l < "$carry_adapter_log" | tr -d ' ')" -eq 1 ] ||
  fail 'first bounded run did not process exactly one dedup candidate'
env -u TRIAGE_STUB_QUEUE_FILE \
  TRIAGE_FAKE_GH_DIR="$carry_gh" \
  TRIAGE_STUB_RESPONSE_TABLE="$carry_table" \
  TRIAGE_STUB_LOG_FILE="$carry_adapter_log" \
  NIGHTSHIFT_CONFIG="$carry_config" \
  /bin/bash "$ROOT/bin/morning-triage" --force \
  --repo-pin "demo=$repo_sha@$repo_src" >/dev/null
[ ! -s "$carry_state_file" ] ||
  fail 'second run did not consume the mandatory carryover finding'
[ "$(wc -l < "$carry_adapter_log" | tr -d ' ')" -eq 2 ] ||
  fail 'second run reprocessed a completed dedup candidate'

b1_state="$TEST_TMP/b1-e2e-state"
b1_gh="$TEST_TMP/b1-e2e-gh"
b1_config="$TEST_TMP/b1-e2e.conf"
b1_extra="$TEST_TMP/b1-e2e-extra.conf"
b1_date_bin="$TEST_TMP/b1-date-bin"
b1_settled="$TEST_TMP/b1-settled"
mkdir -p "$b1_state" "$b1_gh" "$b1_date_bin"
printf '%s\n' "TRIAGE_MAX_VERIFY_PER_RUN='0'" > "$b1_extra"
triage_write_config \
  "$b1_config" \
  "$b1_state" \
  "$TEST_DIR/fixtures/triage/fake-gh.sh" \
  "$b1_extra"
triage_seed_report_issue "$b1_gh" demo/repo 201
triage_seed_finding \
  "$b1_state" b1-canonical demo app/render.sh:5 "same settled symptom" Bug \
  2026-08-10
triage_seed_verdict \
  "$b1_state" b1-canonical adopted 2026-08-11T00:00:00Z human \
  comment:b1-adopted
triage_seed_finding \
  "$b1_state" b1-duplicate demo app/render.sh:5 "same settled symptom" Bug \
  2026-08-12
cat > "$b1_date_bin/date" <<'EOF'
#!/bin/bash
set -euo pipefail
if [ "${*: -1}" = '+%H:%M' ] && [ -n "${B1_SETTLED_SENTINEL:-}" ]; then
  while [ ! -f "$B1_SETTLED_SENTINEL" ]; do
    sleep 0.01
  done
fi
/bin/date "$@"
EOF
chmod +x "$b1_date_bin/date"
(
  while [ ! -s "$b1_state/triage/decisions.draft.jsonl" ]; do
    sleep 0.01
  done
  triage_seed_verdict \
    "$b1_state" b1-canonical fixed 2026-08-12T00:00:00Z human \
    comment:b1-fixed
  : > "$b1_settled"
) &
b1_watcher_pid=$!
TRIAGE_FAKE_GH_DIR="$b1_gh" \
  TRIAGE_STUB_FAIL=1 \
  NIGHTSHIFT_CONFIG="$b1_config" \
  B1_SETTLED_SENTINEL="$b1_settled" \
  PATH="$b1_date_bin:/usr/bin:/bin" \
  /bin/bash "$ROOT/bin/morning-triage" \
  --force \
  --repo-pin "demo=$repo_sha@$repo_src" >/dev/null
wait "$b1_watcher_pid"
[ -f "$b1_settled" ] ||
  fail 'B1 e2e fixture did not settle the canonical after draft publication'
[ ! -s "$b1_state/triage/decisions.jsonl" ] ||
  fail 'B1 full-run wiring retained a decision after its canonical settled'
assert_contains 'decision_drops_canonical: 1' "$b1_state/triage/report.md"

org_excluded_state="$TEST_TMP/org-excluded-state"
org_excluded_gh="$TEST_TMP/org-excluded-gh"
org_excluded_config="$TEST_TMP/org-excluded.conf"
org_excluded_adapter_log="$TEST_TMP/org-excluded-adapter.log"
mkdir -p "$org_excluded_state" "$org_excluded_gh"
triage_write_config \
  "$org_excluded_config" \
  "$org_excluded_state" \
  "$TEST_DIR/fixtures/triage/fake-gh.sh"
triage_seed_report_issue "$org_excluded_gh" demo/repo 201
triage_seed_finding \
  "$org_excluded_state" \
  org-consistency-observation \
  outside-org-only \
  app/render.sh:5 \
  'org consistency observation should stay triage-inert' \
  org-consistency/self-health \
  2026-08-12
env -u TRIAGE_STUB_QUEUE_FILE -u TRIAGE_STUB_RESPONSE_TABLE \
  TRIAGE_FAKE_GH_DIR="$org_excluded_gh" \
  TRIAGE_STUB_LOG_FILE="$org_excluded_adapter_log" \
  NIGHTSHIFT_CONFIG="$org_excluded_config" \
  /bin/bash "$ROOT/bin/morning-triage" \
  --dry-run \
  --force \
  --repo-pin "demo=$repo_sha@$repo_src" >/dev/null
[ ! -s "$org_excluded_state/triage/decisions.draft.jsonl" ] ||
  fail 'org-consistency findings unexpectedly entered triage decisions'
assert_contains 'new_findings_total: 0' "$org_excluded_state/triage/report.md"
assert_contains 'verify_total: 0' "$org_excluded_state/triage/report.md"
assert_contains 'outside_repo_count: 0' "$org_excluded_state/triage/report.md"
[ ! -s "$org_excluded_state/triage/verify-results.jsonl" ] ||
  fail 'org-consistency findings unexpectedly entered verify processing'
[ ! -s "$org_excluded_adapter_log" ] ||
  fail 'org-consistency findings unexpectedly invoked the triage adapter'

org_included_state="$TEST_TMP/org-included-state"
org_included_gh="$TEST_TMP/org-included-gh"
org_included_config="$TEST_TMP/org-included.conf"
org_included_adapter_log="$TEST_TMP/org-included-adapter.log"
org_included_response="$TEST_TMP/org-included-verify.jsonl"
mkdir -p "$org_included_state" "$org_included_gh"
triage_write_config \
  "$org_included_config" \
  "$org_included_state" \
  "$TEST_DIR/fixtures/triage/fake-gh.sh"
triage_seed_report_issue "$org_included_gh" demo/repo 201
triage_seed_finding \
  "$org_included_state" \
  normal-triage-finding \
  demo \
  app/render.sh:5 \
  'normal finding should still flow through triage' \
  Bug \
  2026-08-12
printf '%s\n' \
  '{"finding_id":"normal-triage-finding","verdict":"CONFIRMED_CURRENT","file":"app/render.sh","line":5,"quoted_line":"current evidence","removed_pattern":"","explanation":"still current"}' \
  > "$org_included_response"
env -u TRIAGE_STUB_QUEUE_FILE -u TRIAGE_STUB_RESPONSE_TABLE \
  TRIAGE_FAKE_GH_DIR="$org_included_gh" \
  TRIAGE_STUB_DEFAULT_RESPONSE="$org_included_response" \
  TRIAGE_STUB_LOG_FILE="$org_included_adapter_log" \
  NIGHTSHIFT_CONFIG="$org_included_config" \
  /bin/bash "$ROOT/bin/morning-triage" \
  --dry-run \
  --force \
  --repo-pin "demo=$repo_sha@$repo_src" >/dev/null
assert_contains 'new_findings_total: 1' "$org_included_state/triage/report.md"
assert_contains 'verify_total: 1' "$org_included_state/triage/report.md"
assert_contains 'dedup_pool_empty: 1' "$org_included_state/triage/report.md"
jq -e 'select(.finding_id == "normal-triage-finding" and .verdict == "CONFIRMED_CURRENT")' \
  "$org_included_state/triage/verify-results.jsonl" >/dev/null ||
  fail 'non-org-consistency findings stopped flowing through verify'
[ "$(wc -l < "$org_included_adapter_log" | tr -d ' ')" -eq 1 ] ||
  fail 'non-org-consistency findings did not continue invoking the triage adapter'

printf 'test_triage_decisions: PASS\n'
