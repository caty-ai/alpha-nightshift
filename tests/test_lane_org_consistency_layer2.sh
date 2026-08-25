#!/bin/bash
# shellcheck disable=SC1091
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
. "$TEST_DIR/helpers.sh"
. "$TEST_DIR/fixtures/org-consistency/lib.sh"

FAKE_SEAT="$TEST_DIR/fixtures/org-consistency/fake-seat.sh"
seat_cmd="/bin/bash '$FAKE_SEAT'"
case_roots=()
cleanup() {
  rm -rf "${case_roots[@]}"
}
trap cleanup EXIT

setup_l2_case() {
  case_name=$1
  demo_id=$2
  second_demo=${3:-1}
  oc_case_init "$case_name"
  case_roots+=("$OC_CASE_ROOT")

  oc_make_remote family-os main pass
  oc_make_remote demo main none
  oc_make_remote family-dev-handbook main none
  if [ "$second_demo" = 1 ]; then
    oc_make_remote demo-two main none
  fi

  mkdir -p "$OC_WORK/family-os/registry"
  jq -n '{
    version: 1,
    languages: ["en","ja","zh","th"],
    modules: [
      {repo:"caty-ai/demo", adjacent_text:"Demo registry description"},
      {repo:"caty-ai/demo-two", adjacent_text:"Second demo"},
      {repo:"caty-ai/family-dev-handbook", adjacent_text:"Handbook"}
    ]
  }' > "$OC_WORK/family-os/registry/modules.json"
  oc_commit "$OC_WORK/family-os" registry
  oc_push_work family-os main

  mkdir -p "$OC_WORK/demo/.github/workflows"
  printf '%s\n' '# Agent procedure' 'Follow handbook rule A1 before commit-check.' > "$OC_WORK/demo/AGENTS.md"
  printf '%s\n' 'test:' $'\t@echo test' > "$OC_WORK/demo/Makefile"
  printf '%s\n' 'name: ci' > "$OC_WORK/demo/.github/workflows/ci.yml"
  oc_commit "$OC_WORK/demo" l2-inputs
  oc_push_work demo main

  mkdir -p "$OC_WORK/family-dev-handbook/docs"
  printf '%s\n' '# Rules' '' '## A1 Commit check' '' 'Run the commit check.' > "$OC_WORK/family-dev-handbook/docs/01-rules.md"
  oc_commit "$OC_WORK/family-dev-handbook" handbook-rules
  oc_push_work family-dev-handbook main

  family_id=$((demo_id + 3))
  handbook_id=$((demo_id + 2))
  if [ "$second_demo" = 1 ]; then
    jq -n \
      --argjson demo "$demo_id" \
      --argjson demo_two "$((demo_id + 1))" \
      --argjson handbook "$handbook_id" \
      --argjson family "$family_id" \
      '[
        {id:$demo,name:"demo",full_name:"caty-ai/demo",description:"Demo API description",default_branch:"main",clone_url:"https://github.com/caty-ai/demo.git",archived:false,private:false},
        {id:$demo_two,name:"demo-two",full_name:"caty-ai/demo-two",description:"Second API description",default_branch:"main",clone_url:"https://github.com/caty-ai/demo-two.git",archived:false,private:false},
        {id:$handbook,name:"family-dev-handbook",full_name:"caty-ai/family-dev-handbook",description:"Handbook API description",default_branch:"main",clone_url:"https://github.com/caty-ai/family-dev-handbook.git",archived:false,private:false},
        {id:$family,name:"family-os",full_name:"caty-ai/family-os",description:"Registry API description",default_branch:"main",clone_url:"https://github.com/caty-ai/family-os.git",archived:false,private:false}
      ]' > "$OC_API"
  else
    jq -n \
      --argjson demo "$demo_id" \
      --argjson handbook "$handbook_id" \
      --argjson family "$family_id" \
      '[
        {id:$demo,name:"demo",full_name:"caty-ai/demo",description:"Demo API description",default_branch:"main",clone_url:"https://github.com/caty-ai/demo.git",archived:false,private:false},
        {id:$handbook,name:"family-dev-handbook",full_name:"caty-ai/family-dev-handbook",description:"Handbook API description",default_branch:"main",clone_url:"https://github.com/caty-ai/family-dev-handbook.git",archived:false,private:false},
        {id:$family,name:"family-os",full_name:"caty-ai/family-os",description:"Registry API description",default_branch:"main",clone_url:"https://github.com/caty-ai/family-os.git",archived:false,private:false}
      ]' > "$OC_API"
  fi
}

# One repository per E/F/G launch, a separate H launch, cap visibility, scratch
# cwd, baseline quietness, and lane-owned fingerprints.
setup_l2_case l2-queue 1101 1
oc_run 2026-08-01 \
  OC_TEST_DISABLE_L2=0 \
  OC_SEAT_CMD="$seat_cmd" \
  OC_FAKE_SEAT_MODE=cwd \
  OC_L2_MAX_REPOS=1 \
  OC_H_MAX_REPOS=1 \
  OC_ZERO_STREAK_NIGHTS=99
queue_report="$OC_STATE/report/2026-08-01.json"
jq -e '
  .effective_settings.OC_SEAT_TIMEOUT_SEC == 900 and
  .scope.deferred_repos == 3 and
  ([.cells[] | select(.repo_id == 1101 and (.check_id == "OC-E" or .check_id == "OC-F" or .check_id == "OC-G" or .check_id == "OC-H"))] | length) == 4 and
  ([.cells[] | select(.repo_id == 1101 and .layer == 2 and .status == "RUN")] | length) == 4 and
  ([.events[] | select(.type == "SEAT-INVOKED" and .repo_id == 1101)] | length) == 2 and
  ([.cells[] | select(.deferred == true and .status == "NOT-RUN" and .reason == "deferred")] | length) == 12 and
  ([.findings.self_health[] | select(.claim_kind == "notrun-ratio")] | length) == 0
' "$queue_report" >/dev/null || {
  jq '{settings:.effective_settings,scope:.scope,l2:[.cells[]|select(.layer==2)|{id:.repo_id,check:.check_id,status:.status,reason:.reason,deferred:.deferred}],health:.findings.self_health}' "$queue_report" >&2
  fail 'layer-2 cap/launch matrix or deferred NOT-RUN accounting is wrong'
}
assert_contains 'QUEUED (3 repos deferred)' "$OC_STATE/report/2026-08-01.md"
jq -e '
  ([.findings.new[] | select(.check_id == "OC-E" and .confidence == "high")] | length) == 1 and
  ([.findings.new[] | select(.check_id == "OC-H" and .confidence == "medium")] | length) == 1 and
  ([.findings.human_review[] | select(.check_id == "OC-H")] | length) == 1 and
  all(.findings.new[]; (.evidence | contains("/oc-seat.")) and (.evidence | contains("/mirrors/") | not))
' "$queue_report" >/dev/null || fail 'confidence routing or scratch cwd evidence is wrong'
expected_fp=$(python3 -B "$OC_CORE" fingerprint 2 OC-E 1101 README.md desc:api-readme)
jq -e --arg fp "$expected_fp" '[.findings.new[] | select(.check_id == "OC-E" and .fingerprint == $fp)] | length == 1' "$queue_report" >/dev/null || fail 'OC-E fingerprint was not computed from lane-owned structured fields'
[ ! -s "$OC_CASE_ROOT/lanes/2026-08-01/findings.jsonl" ] || fail 'baseline layer-2 findings leaked into findings.jsonl'
if find "$OC_STATE/mirrors" -name prompt.txt -print | grep -q .; then
  fail 'seat delivery wrote its prompt into a mirror'
fi

# Deferred work rotates forward, while the already inspected unchanged demo is
# absent from the next layer-2 plan.
oc_run 2026-08-02 \
  OC_TEST_DISABLE_L2=0 \
  OC_SEAT_CMD="$seat_cmd" \
  OC_FAKE_SEAT_MODE=valid \
  OC_L2_MAX_REPOS=1 \
  OC_H_MAX_REPOS=1 \
  OC_ZERO_STREAK_NIGHTS=99
jq -e '[.cells[] | select(.repo_id == 1101 and (.check_id == "OC-E" or .check_id == "OC-F" or .check_id == "OC-G" or .check_id == "OC-H"))] | length == 0' "$OC_STATE/report/2026-08-02.json" >/dev/null || fail 'unchanged repository re-entered the layer-2 queue'
jq -e -s 'length == 1 and .[0].kind == "org-consistency/OC-E" and .[0].confirm_cost == "1分"' "$OC_CASE_ROOT/lanes/2026-08-02/findings.jsonl" >/dev/null || fail 'new high-confidence layer-2 finding did not use the 1-minute ledger contract'

# Updating only the handbook re-runs H for every agent-doc repository even when
# that repository HEAD did not change. Prompt structure is asserted by the fake
# seat without depending on a model or network.
setup_l2_case l2-handbook 1201 0
oc_run 2026-08-01 OC_TEST_DISABLE_L2=0 OC_SEAT_CMD="$seat_cmd" OC_FAKE_SEAT_MODE=assert-input OC_L2_MAX_REPOS=10 OC_H_MAX_REPOS=10 OC_ZERO_STREAK_NIGHTS=99
oc_run 2026-08-02 OC_TEST_DISABLE_L2=0 OC_SEAT_CMD="$seat_cmd" OC_FAKE_SEAT_MODE=assert-input OC_L2_MAX_REPOS=10 OC_H_MAX_REPOS=10 OC_ZERO_STREAK_NIGHTS=99
jq -e '[.cells[] | select(.layer == 2)] | length == 0' "$OC_STATE/report/2026-08-02.json" >/dev/null || fail 'unchanged complete layer-2 inventory was not silent'
demo_head_before=$(jq -r '.repos["1201"].head' "$OC_STATE/repos.json")
printf '%s\n' '' 'Clarified rule text.' >> "$OC_WORK/family-dev-handbook/docs/01-rules.md"
oc_commit "$OC_WORK/family-dev-handbook" handbook-update
oc_push_work family-dev-handbook main
oc_run 2026-08-03 OC_TEST_DISABLE_L2=0 OC_SEAT_CMD="$seat_cmd" OC_FAKE_SEAT_MODE=valid OC_L2_MAX_REPOS=10 OC_H_MAX_REPOS=10 OC_ZERO_STREAK_NIGHTS=99
jq -e '[.cells[] | select(.repo_id == 1201 and .check_id == "OC-H" and .status == "RUN")] | length == 1' "$OC_STATE/report/2026-08-03.json" >/dev/null || fail 'handbook HEAD change did not inverse-trigger OC-H for an unchanged agent-doc repo'
[ "$(jq -r '.repos["1201"].head' "$OC_STATE/repos.json")" = "$demo_head_before" ] || fail 'handbook inverse-trigger control also changed the demo HEAD'
jq -e '.repos["1201"].layer2.h_handbook_head == .repos["1203"].head' "$OC_STATE/repos.json" >/dev/null || fail 'OC-H ledger did not record the handbook HEAD it inspected'
jq -e -s 'length == 2 and all(.[]; .confirm_cost == "1分") and any(.[]; .kind == "org-consistency/OC-H")' "$OC_CASE_ROOT/lanes/2026-08-03/findings.jsonl" >/dev/null || fail 'medium-confidence OC-H finding was not retained in the 1-minute proposal path'
jq -e '[.findings.human_review[] | select(.check_id == "OC-H" and .confidence == "medium")] | length == 1' "$OC_STATE/report/2026-08-03.json" >/dev/null || fail 'medium-confidence OC-H finding was absent from human review'

# Every schema breach is INVALID-OUTPUT (never fresh RUN), fires self-health,
# and remains retryable on the same repository HEAD. Timeout is NOT-RUN. A
# subsequent valid result is the positive control and produces both confidence
# levels in the normal 1-minute proposal path.
setup_l2_case l2-invalid 1301 0
oc_run 2026-08-01 OC_TEST_DISABLE_L2=0 OC_SEAT_CMD="$seat_cmd" OC_FAKE_SEAT_MODE=valid OC_L2_MAX_REPOS=10 OC_H_MAX_REPOS=10 OC_ZERO_STREAK_NIGHTS=99
baseline_open=$(jq '.findings | length' "$OC_STATE/findings.json")
[ "$baseline_open" -ge 2 ] || fail 'invalid-output lifecycle precondition did not create baseline layer-2 findings'
printf '%s\n' '' 'Changed product claim.' >> "$OC_WORK/demo/README.md"
oc_commit "$OC_WORK/demo" changed-head
oc_push_work demo main

invalid_day=2
for mode in invalid-json extra-field huge-claim fake-fingerprint; do
  night_id=$(printf '2026-08-%02d' "$invalid_day")
  oc_run "$night_id" OC_TEST_DISABLE_L2=0 OC_SEAT_CMD="$seat_cmd" OC_FAKE_SEAT_MODE="$mode" OC_L2_MAX_REPOS=10 OC_H_MAX_REPOS=10 OC_ZERO_STREAK_NIGHTS=99
  jq -e '
    ([.cells[] | select(.repo_id == 1301 and .layer == 2 and .status == "INVALID-OUTPUT" and .fresh == false)] | length) == 4 and
    ([.cells[] | select(.layer == 2 and .repo_id != 1301)] | length) == 0 and
    ([.findings.self_health[] | select(.claim_kind == "invalid-output")] | length) == 1
  ' "$OC_STATE/report/$night_id.json" >/dev/null || fail "$mode was not rejected as INVALID-OUTPUT with self-health"
  jq -e 'all(.findings[]; if .check_id == "self-health" then true else .status == "open" end)' "$OC_STATE/findings.json" >/dev/null || fail "$mode resolved an open finding"
  invalid_day=$((invalid_day + 1))
done

oc_run 2026-08-06 OC_TEST_DISABLE_L2=0 OC_SEAT_CMD="$seat_cmd" OC_FAKE_SEAT_MODE=timeout OC_SEAT_TIMEOUT_SEC=1 OC_L2_MAX_REPOS=10 OC_H_MAX_REPOS=10 OC_ZERO_STREAK_NIGHTS=99
jq -e '([.cells[] | select(.repo_id == 1301 and .layer == 2 and .status == "NOT-RUN" and .reason == "seat-timeout" and .fresh == false)] | length) == 4' "$OC_STATE/report/2026-08-06.json" >/dev/null || fail 'per-launch timeout was not a non-fresh NOT-RUN result'

oc_run 2026-08-07 OC_TEST_DISABLE_L2=0 OC_SEAT_CMD="$seat_cmd" OC_FAKE_SEAT_MODE=valid OC_L2_MAX_REPOS=10 OC_H_MAX_REPOS=10 OC_ZERO_STREAK_NIGHTS=99
jq -e '
  ([.cells[] | select(.repo_id == 1301 and .layer == 2 and .status == "RUN" and .fresh == true)] | length) == 4 and
  ([.findings.new[] | select(.check_id == "OC-E" and .confidence == "high")] | length) == 0 and
  ([.findings.new[] | select(.check_id == "OC-H" and .confidence == "medium")] | length) == 0 and
  ([.findings.self_health[] | select(.claim_kind == "invalid-output")] | length) == 0
' "$OC_STATE/report/2026-08-07.json" >/dev/null || fail 'valid retry was not accepted or invalid-output self-health did not clear'
jq -e 'all(.findings[]; (.fingerprint | test("^[0-9a-f]{64}$")) and .fingerprint != "forged")' "$OC_STATE/findings.json" >/dev/null || fail 'seat-supplied fake fingerprint entered the findings ledger'

# Migration quietness must not consume a changed HEAD from the diff ledger;
# the first normal night on the new fingerprint version re-runs that HEAD.
printf '%s\n' '' 'Changed during fingerprint migration.' >> "$OC_WORK/demo/README.md"
oc_commit "$OC_WORK/demo" migration-head
oc_push_work demo main
oc_run 2026-08-08 OC_TEST_DISABLE_L2=0 OC_SEAT_CMD="$seat_cmd" OC_FAKE_SEAT_MODE=valid OC_FP_SPEC_VERSION=3 OC_L2_MAX_REPOS=10 OC_H_MAX_REPOS=10 OC_ZERO_STREAK_NIGHTS=99
jq -e '.migration_mode == true and .quiet_mode == "migration"' "$OC_STATE/report/2026-08-08.json" >/dev/null || fail 'layer-2 migration night was not quiet'
[ ! -s "$OC_CASE_ROOT/lanes/2026-08-08/findings.jsonl" ] || fail 'layer-2 migration night leaked proposals'
oc_run 2026-08-09 OC_TEST_DISABLE_L2=0 OC_SEAT_CMD="$seat_cmd" OC_FAKE_SEAT_MODE=valid OC_FP_SPEC_VERSION=3 OC_L2_MAX_REPOS=10 OC_H_MAX_REPOS=10 OC_ZERO_STREAK_NIGHTS=99
jq -e '([.cells[] | select(.repo_id == 1301 and .layer == 2 and .status == "RUN")] | length) == 4' "$OC_STATE/report/2026-08-09.json" >/dev/null || fail 'migration night consumed the changed layer-2 HEAD'

printf 'test_lane_org_consistency_layer2: PASS\n'
