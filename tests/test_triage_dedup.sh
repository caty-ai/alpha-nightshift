#!/bin/bash
set -euo pipefail
# Runtime-computed sources and globals consumed by sourced triage functions are
# intentionally invisible to standalone shellcheck.
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

[ -f "$ROOT/bin/morning-triage" ] || fail "missing bin/morning-triage"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-triage-dedup.XXXXXX")
cleanup() {
  if [ "${TRIAGE_TEST_KEEP_TMP:-0}" = 1 ]; then
    printf 'preserved triage test directory: %s\n' "$TEST_TMP" >&2
    return
  fi
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

canonical_projection="$TEST_TMP/canonical-projection.jsonl"
canonical_ids="$TEST_TMP/canonical-ids.txt"
cat > "$canonical_projection" <<'EOF'
{"id":"rv-root-canon-abc12345","current_status":"adopted","latest_verdict":{"rejection_reason":""}}
{"id":"rv-leaf-full-11111111","current_status":"rejected","latest_verdict":{"rejection_reason":"duplicate of rv-root-canon-abc12345"}}
{"id":"rv-leaf-embedded-22222222","current_status":"rejected","latest_verdict":{"rejection_reason":"duplicate/absorbed after review: rv-root-canon-abc12345 is the root"}}
{"id":"rv-leaf-suffix-33333333","current_status":"rejected","latest_verdict":{"rejection_reason":"duplicate of abc12345"}}
{"id":"rv-ambiguous-one-deadbeef","current_status":"adopted","latest_verdict":{"rejection_reason":""}}
{"id":"rv-ambiguous-two-deadbeef","current_status":"adopted","latest_verdict":{"rejection_reason":""}}
{"id":"rv-leaf-ambiguous-44444444","current_status":"rejected","latest_verdict":{"rejection_reason":"duplicate of deadbeef"}}
{"id":"rv-leaf-multiple-55555555","current_status":"rejected","latest_verdict":{"rejection_reason":"duplicate of rv-root-canon-abc12345 and rv-ambiguous-one-deadbeef"}}
{"id":"rv-leaf-ellipsis-66666666","current_status":"rejected","latest_verdict":{"rejection_reason":"duplicate of rv-root-…abc12345"}}
{"id":"rv-loop-a-77777777","current_status":"rejected","latest_verdict":{"rejection_reason":"duplicate of rv-loop-b-88888888"}}
{"id":"rv-loop-b-88888888","current_status":"rejected","latest_verdict":{"rejection_reason":"duplicate/absorbed rv-loop-a-77777777"}}
{"id":"rv-leaf-empty-99999999","current_status":"rejected","latest_verdict":{"rejection_reason":"duplicate of"}}
EOF
jq -r '.id' "$canonical_projection" > "$canonical_ids"

assert_canonical_root() {
  canonical_subject=$1
  canonical_expected=$2
  canonical_actual=$(triage_resolve_canonical_root \
    "$canonical_subject" "$canonical_projection" "$canonical_ids") ||
    fail "canonical parser rejected supported format for $canonical_subject"
  [ "$(printf '%s\n' "$canonical_actual" | jq -r '.root_id')" = \
    "$canonical_expected" ] ||
    fail "canonical parser resolved $canonical_subject to the wrong root"
}

assert_canonical_rejected() {
  canonical_subject=$1
  canonical_label=$2
  if triage_resolve_canonical_root \
    "$canonical_subject" "$canonical_projection" "$canonical_ids" \
    >/dev/null 2>&1; then
    fail "canonical parser accepted $canonical_label"
  fi
}

assert_canonical_root rv-leaf-full-11111111 rv-root-canon-abc12345
assert_canonical_root rv-leaf-embedded-22222222 rv-root-canon-abc12345
assert_canonical_root rv-leaf-suffix-33333333 rv-root-canon-abc12345
assert_canonical_rejected rv-leaf-ambiguous-44444444 'ambiguous 8hex suffix'
assert_canonical_rejected rv-leaf-multiple-55555555 'multiple full references'
assert_canonical_rejected rv-leaf-ellipsis-66666666 'unrecoverable ellipsis id'
assert_canonical_rejected rv-loop-a-77777777 'canonical loop'
assert_canonical_rejected rv-leaf-empty-99999999 'empty duplicate reference'

depth_projection="$TEST_TMP/depth-projection.jsonl"
depth_ids="$TEST_TMP/depth-ids.txt"
cat > "$depth_projection" <<'EOF'
{"id":"rv-depth-root","current_status":"adopted","latest_verdict":{"rejection_reason":""}}
{"id":"rv-depth-01","current_status":"rejected","latest_verdict":{"rejection_reason":"duplicate of rv-depth-root"}}
{"id":"rv-depth-02","current_status":"rejected","latest_verdict":{"rejection_reason":"duplicate of rv-depth-01"}}
{"id":"rv-depth-03","current_status":"rejected","latest_verdict":{"rejection_reason":"duplicate of rv-depth-02"}}
{"id":"rv-depth-04","current_status":"rejected","latest_verdict":{"rejection_reason":"duplicate of rv-depth-03"}}
{"id":"rv-depth-05","current_status":"rejected","latest_verdict":{"rejection_reason":"duplicate of rv-depth-04"}}
{"id":"rv-depth-06","current_status":"rejected","latest_verdict":{"rejection_reason":"duplicate of rv-depth-05"}}
{"id":"rv-depth-07","current_status":"rejected","latest_verdict":{"rejection_reason":"duplicate of rv-depth-06"}}
{"id":"rv-depth-08","current_status":"rejected","latest_verdict":{"rejection_reason":"duplicate of rv-depth-07"}}
{"id":"rv-depth-09","current_status":"rejected","latest_verdict":{"rejection_reason":"duplicate of rv-depth-08"}}
{"id":"rv-depth-10","current_status":"rejected","latest_verdict":{"rejection_reason":"duplicate of rv-depth-09"}}
{"id":"rv-depth-11","current_status":"rejected","latest_verdict":{"rejection_reason":"duplicate of rv-depth-10"}}
EOF
jq -r '.id' "$depth_projection" > "$depth_ids"
canonical_projection="$depth_projection"
canonical_ids="$depth_ids"
assert_canonical_rejected rv-depth-11 'transition depth boundary'
canonical_projection="$TEST_TMP/canonical-projection.jsonl"
canonical_ids="$TEST_TMP/canonical-ids.txt"
[ "$(triage_reason_prefix_class 'already fixed on main abc')" = fixed ] ||
  fail 'already-fixed origin classification changed'
[ "$(triage_reason_prefix_class 'deferred pending owner')" = deferred ] ||
  fail 'deferred origin classification changed'
[ "$(triage_reason_prefix_class 'duplicate of rv-x')" = duplicate ] ||
  fail 'duplicate origin classification changed'
[ "$(triage_reason_prefix_class 'intended design')" = other ] ||
  fail 'other origin classification changed'

synthesis_dir="$TEST_TMP/synthesis"
# These globals configure functions sourced from lib/triage.sh.
# shellcheck disable=SC2034
TRIAGE_WORK_DIR="$synthesis_dir"
# shellcheck disable=SC2034
TRIAGE_ACTOR=auto-triage
# shellcheck disable=SC2034
TRIAGE_ALREADY_FIXED_MODE=suggest
mkdir -p \
  "$synthesis_dir/dedup/demo" \
  "$synthesis_dir/verify/demo" \
  "$synthesis_dir/clones"
printf '%s\n' '{}' > "$synthesis_dir/clones/demo.json"
cat > "$synthesis_dir/current.jsonl" <<'EOF'
{"id":"synth-root","repo":"demo","target":"app/render.sh:5","current_status":"adopted","latest_verdict":null}
{"id":"synth-root-other","repo":"demo","target":"app/render.sh:5","current_status":"rejected","latest_verdict":{"rejection_reason":"intended design"}}
{"id":"synth-root-already-fixed","repo":"demo","target":"app/render.sh:5","current_status":"rejected","latest_verdict":{"rejection_reason":"already fixed on main abc: gone"}}
{"id":"synth-medium","repo":"demo","target":"app/render.sh:5","current_status":"open","latest_verdict":null}
{"id":"synth-distinct","repo":"demo","target":"app/render.sh:5","current_status":"open","latest_verdict":null}
{"id":"synth-high","repo":"demo","target":"app/render.sh:5","current_status":"open","latest_verdict":null}
{"id":"synth-other","repo":"demo","target":"app/render.sh:5","current_status":"open","latest_verdict":null}
{"id":"synth-fixed-shape","repo":"demo","target":"app/render.sh:5","current_status":"open","latest_verdict":null}
EOF
jq -r '.id' "$synthesis_dir/current.jsonl" > "$synthesis_dir/current-ids.txt"
cat > "$synthesis_dir/dedup/demo/final.jsonl" <<'EOF'
{"finding_id":"synth-medium","verdict":"DUPLICATE","canonical_id":"synth-root","confidence":"medium","shared_defect":"not certain"}
{"finding_id":"synth-distinct","verdict":"DISTINCT","canonical_id":"synth-root","confidence":"high","shared_defect":"must be ignored"}
{"finding_id":"synth-high","verdict":"DUPLICATE","canonical_id":"synth-root","confidence":"high","shared_defect":"same one-place fix"}
{"finding_id":"synth-high","verdict":"DUPLICATE","canonical_id":"synth-root","confidence":"high","shared_defect":"same one-place fix"}
{"finding_id":"synth-other","verdict":"DUPLICATE","canonical_id":"synth-root-other","confidence":"high","shared_defect":"same intended behavior"}
{"finding_id":"synth-fixed-shape","verdict":"DUPLICATE","canonical_id":"synth-root-already-fixed","confidence":"high","shared_defect":"same historical shape"}
EOF
: > "$synthesis_dir/verify/demo/validated.jsonl"
triage_stats_init
triage_synthesize_decisions '2026-08-18T00:00:00Z'
synthesis_draft="$synthesis_dir/decisions.draft.jsonl"
[ "$(wc -l < "$synthesis_draft" | tr -d ' ')" -eq 2 ] ||
  fail 'medium/DISTINCT filtering or duplicate decision suppression failed'
[ "$(jq -r '.finding_id' "$synthesis_draft" | sort | tr '\n' ' ')" = \
  'synth-high synth-other ' ] ||
  fail 'non-high duplicate generated the synthesized decision'
[ "$(jq -r '.decision_deduped' "$synthesis_dir/stats.json")" -eq 1 ] ||
  fail 'duplicate decision was not counted as mechanically deduplicated'
assert_contains 'evidence app/render.sh:5' "$synthesis_draft"
jq -e '
  select(.finding_id == "synth-other")
  | .rejection_reason
  | contains("起因 その他")
' "$synthesis_draft" >/dev/null ||
  fail 'other-origin duplicate reason omitted the required origin label'

cluster_dir="$TEST_TMP/clusters"
# This global configures triage_build_clusters from the sourced library.
# shellcheck disable=SC2034
TRIAGE_WORK_DIR="$cluster_dir"
mkdir -p "$cluster_dir/dedup/demo"
cat > "$cluster_dir/current.jsonl" <<'EOF'
{"id":"cluster-adopted","repo":"demo","night_id":"2026-08-10","ts":"2026-08-10T00:00:00Z","current_status":"adopted","latest_verdict":null}
{"id":"cluster-open-old","repo":"demo","night_id":"2026-08-11","ts":"2026-08-11T00:00:00Z","current_status":"open","latest_verdict":null}
{"id":"cluster-open-new","repo":"demo","night_id":"2026-08-12","ts":"2026-08-12T00:00:00Z","current_status":"open","latest_verdict":null}
EOF
printf '%s\n' '{"closure_incomplete_count":0}' > "$cluster_dir/stats.json"
cat > "$cluster_dir/dedup/demo/final.jsonl" <<'EOF'
{"finding_id":"cluster-open-new","verdict":"DUPLICATE","canonical_id":"cluster-open-old","confidence":"high","shared_defect":"one component"}
{"finding_id":"cluster-open-old","verdict":"DUPLICATE","canonical_id":"cluster-adopted","confidence":"high","shared_defect":"one component"}
EOF
triage_build_clusters
jq -e -s '
  length == 1 and
  .[0].canonical_id == "cluster-adopted" and
  .[0].complete == true
' "$cluster_dir/clusters.jsonl" >/dev/null ||
  fail 'cluster canonical did not prioritize its single adopted member'

printf '%s\n' '{"closure_incomplete_count":1}' > "$cluster_dir/stats.json"
triage_build_clusters
jq -e -s 'length >= 1 and all(.[]; .complete == false)' \
  "$cluster_dir/clusters.jsonl" >/dev/null ||
  fail 'closure-incomplete cluster remained eligible for presentation'

cat >> "$cluster_dir/current.jsonl" <<'EOF'
{"id":"cluster-adopted-two","repo":"demo","night_id":"2026-08-09","ts":"2026-08-09T00:00:00Z","current_status":"adopted","latest_verdict":null}
EOF
cat >> "$cluster_dir/dedup/demo/final.jsonl" <<'EOF'
{"finding_id":"cluster-open-new","verdict":"DUPLICATE","canonical_id":"cluster-adopted-two","confidence":"high","shared_defect":"ambiguous adopted roots"}
EOF
printf '%s\n' '{"closure_incomplete_count":0}' > "$cluster_dir/stats.json"
triage_build_clusters
jq -e -s 'length == 1 and .[0].canonical_id == null and .[0].complete == false' \
  "$cluster_dir/clusters.jsonl" >/dev/null ||
  fail 'multiple adopted cluster members did not fail closed'

sibling_dir="$TEST_TMP/sibling-cluster"
TRIAGE_WORK_DIR="$sibling_dir"
mkdir -p \
  "$sibling_dir/dedup/demo" \
  "$sibling_dir/verify/demo" \
  "$sibling_dir/clones"
printf '%s\n' '{}' > "$sibling_dir/clones/demo.json"
cat > "$sibling_dir/current.jsonl" <<'EOF'
{"id":"sibling-adopted","repo":"demo","target":"app/render.sh:5","night_id":"2026-08-10","ts":"2026-08-10T00:00:00Z","current_status":"adopted","latest_verdict":null}
{"id":"sibling-open","repo":"demo","target":"app/render.sh:5","night_id":"2026-08-11","ts":"2026-08-11T00:00:00Z","current_status":"open","latest_verdict":null}
{"id":"sibling-new","repo":"demo","target":"app/render.sh:5","night_id":"2026-08-12","ts":"2026-08-12T00:00:00Z","current_status":"open","latest_verdict":null}
EOF
jq -r '.id' "$sibling_dir/current.jsonl" > "$sibling_dir/current-ids.txt"
cat > "$sibling_dir/dedup/demo/final.jsonl" <<'EOF'
{"finding_id":"sibling-new","verdict":"DUPLICATE","canonical_id":"sibling-open","confidence":"high","shared_defect":"`one component`"}
{"finding_id":"sibling-open","verdict":"DUPLICATE","canonical_id":"sibling-adopted","confidence":"high","shared_defect":"one component"}
EOF
: > "$sibling_dir/verify/demo/validated.jsonl"
triage_stats_init
triage_build_clusters
triage_synthesize_decisions '2026-08-18T00:00:00Z'
jq -e '
  select(.finding_id == "sibling-new") |
  .rejection_reason | startswith("duplicate of sibling-adopted ")
' "$sibling_dir/decisions.draft.jsonl" >/dev/null ||
  fail 'open sibling did not fall back through the complete cluster canonical'
jq -e '
  select(.finding_id == "sibling-new") |
  .canonical_id == "sibling-adopted" and
  .root_id == "sibling-adopted" and .root_status == "adopted"
' "$sibling_dir/decision-branches.jsonl" >/dev/null ||
  fail 'cluster fallback branch metadata did not record the adopted canonical'
if jq -e --arg id sibling-new '
  select(.finding_id == $id and (.rejection_reason | contains("`")))
' "$sibling_dir/decisions.draft.jsonl" >/dev/null; then
  fail 'shared_defect sanitizer retained a backtick'
fi

open_cluster_dir="$TEST_TMP/open-only-cluster"
# This global configures triage_build_clusters and triage_synthesize_decisions.
# shellcheck disable=SC2034
TRIAGE_WORK_DIR="$open_cluster_dir"
mkdir -p \
  "$open_cluster_dir/dedup/demo" \
  "$open_cluster_dir/verify/demo" \
  "$open_cluster_dir/clones"
printf '%s\n' '{}' > "$open_cluster_dir/clones/demo.json"
cat > "$open_cluster_dir/current.jsonl" <<'EOF'
{"id":"open-cluster-old","repo":"demo","target":"app/render.sh:5","night_id":"2026-08-10","ts":"2026-08-10T00:00:00Z","current_status":"open","latest_verdict":null}
{"id":"open-cluster-new","repo":"demo","target":"app/render.sh:5","night_id":"2026-08-11","ts":"2026-08-11T00:00:00Z","current_status":"open","latest_verdict":null}
EOF
jq -r '.id' "$open_cluster_dir/current.jsonl" > \
  "$open_cluster_dir/current-ids.txt"
cat > "$open_cluster_dir/dedup/demo/final.jsonl" <<'EOF'
{"finding_id":"open-cluster-new","verdict":"DUPLICATE","canonical_id":"open-cluster-old","confidence":"high","shared_defect":"one component"}
EOF
: > "$open_cluster_dir/verify/demo/validated.jsonl"
triage_stats_init
triage_build_clusters
jq -e -s '
  length == 1 and
  .[0].canonical_id == "open-cluster-old" and
  .[0].complete == true
' "$open_cluster_dir/clusters.jsonl" >/dev/null ||
  fail 'open-only cluster did not keep the oldest open finding as canonical'
triage_synthesize_decisions '2026-08-18T00:00:00Z'
[ ! -s "$open_cluster_dir/decisions.draft.jsonl" ] ||
  fail 'cluster without an adopted canonical emitted an automatic decision'

make_repo_pin() {
  pin_repo_dir=$1
  triage_copy_repo_fixture "$pin_repo_dir"
  triage_init_git_repo "$pin_repo_dir"
  triage_git_commit_all "$pin_repo_dir" "2026-08-01T00:00:00Z" "seed fixture repo"
  printf 'demo=%s@%s\n' "$(git -C "$pin_repo_dir" rev-parse HEAD)" "$pin_repo_dir"
}

run_triage_dry() {
  dry_config=$1
  dry_repo_pin=$2
  export NIGHTSHIFT_CONFIG="$dry_config"
  /bin/bash "$ROOT/bin/morning-triage" \
    --dry-run \
    --force \
    --repo-pin "$dry_repo_pin" >/dev/null
}

l0_state="$TEST_TMP/l0-state"
l0_gh="$TEST_TMP/l0-gh"
l0_config="$TEST_TMP/l0.conf"
mkdir -p "$l0_state" "$l0_gh"
triage_write_config \
  "$l0_config" \
  "$l0_state" \
  "$TEST_DIR/fixtures/triage/fake-gh.sh"
triage_seed_report_issue "$l0_gh" demo/repo 201
triage_seed_finding "$l0_state" l0-canon demo app/render.sh:5 "same symptom" Bug 2026-08-10
triage_seed_verdict "$l0_state" l0-canon adopted 2026-08-11T00:00:00Z human comment:l0
triage_seed_finding "$l0_state" l0-open demo app/render.sh:5 "same symptom" Bug 2026-08-12
export TRIAGE_FAKE_GH_DIR="$l0_gh"
export TRIAGE_FAKE_GH_LOG="$TEST_TMP/l0-gh.log"
export TRIAGE_STUB_FAIL=1
unset TRIAGE_STUB_QUEUE_FILE
unset TRIAGE_STUB_PROMPT_MAP
l0_repo_pin=$(make_repo_pin "$TEST_TMP/l0-repo")
run_triage_dry "$l0_config" "$l0_repo_pin"
l0_draft="$l0_state/triage/decisions.draft.jsonl"
[ "$(wc -l < "$l0_draft" | tr -d ' ')" -eq 1 ] ||
  fail "L0 exact-match dedup did not emit a single rejected decision"
assert_contains 'duplicate of l0-canon' "$l0_draft"

parser_state="$TEST_TMP/parser-state"
parser_gh="$TEST_TMP/parser-gh"
parser_config="$TEST_TMP/parser.conf"
parser_queue="$TEST_TMP/parser.queue"
mkdir -p "$parser_state" "$parser_gh"
triage_write_config \
  "$parser_config" \
  "$parser_state" \
  "$TEST_DIR/fixtures/triage/fake-gh.sh"
triage_seed_report_issue "$parser_gh" demo/repo 201
triage_seed_finding "$parser_state" root-canon-abc12345 demo app/render.sh:5 "root canonical" Bug 2026-08-10
triage_seed_verdict "$parser_state" root-canon-abc12345 adopted 2026-08-11T00:00:00Z human comment:root
triage_seed_finding "$parser_state" leaf-full demo app/render.sh:5 "leaf full" Bug 2026-08-10
triage_seed_verdict \
  "$parser_state" \
  leaf-full \
  rejected \
  2026-08-11T00:00:01Z \
  human \
  comment:leaf-full \
  "duplicate of root-canon-abc12345 after review"
triage_seed_finding "$parser_state" leaf-embedded demo app/render.sh:5 "leaf embedded" Bug 2026-08-10
triage_seed_verdict \
  "$parser_state" \
  leaf-embedded \
  rejected \
  2026-08-11T00:00:02Z \
  human \
  comment:leaf-embedded \
  "duplicate/absorbed root-canon-abc12345 after review"
triage_seed_finding "$parser_state" leaf-suffix demo app/render.sh:5 "leaf suffix" Bug 2026-08-10
triage_seed_verdict \
  "$parser_state" \
  leaf-suffix \
  rejected \
  2026-08-11T00:00:03Z \
  human \
  comment:leaf-suffix \
  "duplicate of abc12345"
triage_seed_finding "$parser_state" dup-full demo app/render.sh:5 "dup full" Bug 2026-08-12
triage_seed_finding "$parser_state" dup-embedded demo app/render.sh:5 "dup embedded" Bug 2026-08-12
triage_seed_finding "$parser_state" dup-suffix demo app/render.sh:5 "dup suffix" Bug 2026-08-12
resp_full="$TEST_TMP/resp-full.jsonl"
resp_embedded="$TEST_TMP/resp-embedded.jsonl"
resp_suffix="$TEST_TMP/resp-suffix.jsonl"
printf '%s\n' \
  '{"finding_id":"dup-full","verdict":"DUPLICATE","canonical_id":"leaf-full","confidence":"high","shared_defect":"same defect"}' \
  > "$resp_full"
printf '%s\n' \
  '{"finding_id":"dup-embedded","verdict":"DUPLICATE","canonical_id":"leaf-embedded","confidence":"high","shared_defect":"same defect"}' \
  > "$resp_embedded"
printf '%s\n' \
  '{"finding_id":"dup-suffix","verdict":"DUPLICATE","canonical_id":"leaf-suffix","confidence":"high","shared_defect":"same defect"}' \
  > "$resp_suffix"
printf '%s\n' "$resp_full" "$resp_embedded" "$resp_suffix" > "$parser_queue"
export TRIAGE_FAKE_GH_DIR="$parser_gh"
export TRIAGE_STUB_FAIL=0
export TRIAGE_STUB_QUEUE_FILE="$parser_queue"
parser_repo_pin=$(make_repo_pin "$TEST_TMP/parser-repo")
run_triage_dry "$parser_config" "$parser_repo_pin"
parser_draft="$parser_state/triage/decisions.draft.jsonl"
[ "$(wc -l < "$parser_draft" | tr -d ' ')" -eq 3 ] ||
  fail "parser resolution did not preserve all accepted duplicate matches"
[ "$(grep -c 'duplicate of root-canon-abc12345' "$parser_draft")" -eq 3 ] ||
  fail "accepted canonical references did not resolve to the root canonical"

branch_state="$TEST_TMP/branch-state"
branch_gh="$TEST_TMP/branch-gh"
branch_config="$TEST_TMP/branch.conf"
branch_queue="$TEST_TMP/branch.queue"
mkdir -p "$branch_state" "$branch_gh"
triage_write_config \
  "$branch_config" \
  "$branch_state" \
  "$TEST_DIR/fixtures/triage/fake-gh.sh"
triage_seed_report_issue "$branch_gh" demo/repo 201
triage_seed_finding "$branch_state" deferred-canon demo app/render.sh:5 "deferred canonical" Bug 2026-08-10
triage_seed_verdict \
  "$branch_state" \
  deferred-canon \
  rejected \
  2026-08-11T00:00:00Z \
  human \
  comment:deferred \
  "deferred pending owner decision"
triage_seed_finding "$branch_state" fixed-canon demo app/render.sh:5 "fixed canonical" Bug 2026-08-10
triage_seed_verdict \
  "$branch_state" \
  fixed-canon \
  fixed \
  2026-08-11T00:00:01Z \
  human \
  comment:fixed
triage_seed_finding "$branch_state" open-canon demo app/render.sh:5 "open canonical" Bug 2026-08-10
triage_seed_finding "$branch_state" dup-deferred demo app/render.sh:5 "dup deferred" Bug 2026-08-12
triage_seed_finding "$branch_state" dup-fixed demo app/render.sh:5 "dup fixed" Bug 2026-08-12
triage_seed_finding "$branch_state" dup-open demo app/render.sh:5 "dup open" Bug 2026-08-12
resp_branch_1="$TEST_TMP/resp-branch-1.jsonl"
resp_branch_2="$TEST_TMP/resp-branch-2.jsonl"
resp_branch_3="$TEST_TMP/resp-branch-3.jsonl"
printf '%s\n' \
  '{"finding_id":"dup-deferred","verdict":"DUPLICATE","canonical_id":"deferred-canon","confidence":"high","shared_defect":"same deferred defect"}' \
  > "$resp_branch_1"
printf '%s\n' \
  '{"finding_id":"dup-fixed","verdict":"DUPLICATE","canonical_id":"fixed-canon","confidence":"high","shared_defect":"same fixed defect"}' \
  > "$resp_branch_2"
printf '%s\n' \
  '{"finding_id":"dup-open","verdict":"DUPLICATE","canonical_id":"open-canon","confidence":"high","shared_defect":"same open defect"}' \
  > "$resp_branch_3"
printf '%s\n' \
  "$resp_branch_1" \
  "$resp_branch_2" \
  "$resp_branch_3" > "$branch_queue"
export TRIAGE_FAKE_GH_DIR="$branch_gh"
export TRIAGE_STUB_QUEUE_FILE="$branch_queue"
branch_repo_pin=$(make_repo_pin "$TEST_TMP/branch-repo")
run_triage_dry "$branch_config" "$branch_repo_pin"
branch_draft="$branch_state/triage/decisions.draft.jsonl"
[ "$(wc -l < "$branch_draft" | tr -d ' ')" -eq 1 ] ||
  fail "deferred/fixed/open branch handling emitted the wrong decision count"
assert_contains 'duplicate of deferred-canon' "$branch_draft"
assert_contains 'canonical is deferred' "$branch_draft"
assert_not_contains 'duplicate of fixed-canon' "$branch_draft"
assert_not_contains 'duplicate of open-canon' "$branch_draft"

printf 'test_triage_dedup: PASS\n'
