#!/bin/bash
# shellcheck disable=SC1091,SC2016
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
. "$TEST_DIR/helpers.sh"
. "$TEST_DIR/fixtures/org-consistency/lib.sh"

FAKE_SEAT="$TEST_DIR/fixtures/org-consistency/fake-seat.sh"
seat_cmd="/bin/bash '$FAKE_SEAT'"
for prompt_file in efg.txt h.txt; do
  grep -F '[A-Za-z0-9_./+@=-]' "$TEST_DIR/../lanes/org-consistency/prompts/$prompt_file" >/dev/null ||
    fail "$prompt_file does not state the target_token charset"
  grep -F 'Strip or rewrite' "$TEST_DIR/../lanes/org-consistency/prompts/$prompt_file" >/dev/null ||
    fail "$prompt_file does not state the Strip or rewrite target_token rule"
done
case_roots=()
cleanup() {
  rm -rf "${case_roots[@]}"
}
trap cleanup EXIT

setup_l2_case() {
  case_name=$1
  demo_id=$2
  second_demo=${3:-1}
  swap_demo_ids=${4:-0}
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
  printf '%s\n' '# Rules' '' '## A1 Commit check' '' 'Run the commit check.' 'A1 remains the same rule.' > "$OC_WORK/family-dev-handbook/docs/01-rules.md"
  oc_commit "$OC_WORK/family-dev-handbook" handbook-rules
  oc_push_work family-dev-handbook main

  family_id=$((demo_id + 3))
  handbook_id=$((demo_id + 2))
  if [ "$second_demo" = 1 ]; then
    first_demo_id=$demo_id
    second_demo_id=$((demo_id + 1))
    if [ "$swap_demo_ids" = 1 ]; then
      first_demo_id=$((demo_id + 1))
      second_demo_id=$demo_id
    fi
    jq -n \
      --argjson demo "$first_demo_id" \
      --argjson demo_two "$second_demo_id" \
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
setup_l2_case l2-queue 1101 1 1
printf '%s\n' '# Handbook agent procedure' 'Apply rule A1 before commit-check.' > "$OC_WORK/family-dev-handbook/AGENTS.md"
oc_commit "$OC_WORK/family-dev-handbook" handbook-agent-doc
oc_push_work family-dev-handbook main
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
  ([.cells[] | select(.repo_id == 1101 and (.check_id == "OC-E" or .check_id == "OC-F") and .status == "RUN")] | length) == 2 and
  ([.cells[] | select(.repo_id == 1101 and .check_id == "OC-G" and .status == "NO-INPUT")] | length) == 1 and
  ([.cells[] | select(.repo_id == 1102 and .check_id == "OC-H" and .status == "RUN" and .metrics.extracted == 1)] | length) == 1 and
  ([.cells[] | select(.repo_id == 1101 and .check_id == "OC-H")] | length) == 0 and
  ([.events[] | select(.type == "SEAT-INVOKED" and (.repo_id == 1101 or .repo_id == 1102))] | length) == 2 and
  ([.cells[] | select(.deferred == true and .status == "NOT-RUN" and .reason == "deferred")] | length) == 10 and
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

# Both previously selected repositories keep changing. Least-recently-run still
# advances deferred E/F/G and H work before either recent repository can run
# again, and the no-agent-doc repository never enters the H queue.
printf '%s\n' '' 'Continuously changing low-id repository.' >> "$OC_WORK/demo-two/README.md"
oc_commit "$OC_WORK/demo-two" continuous-efg-change
oc_push_work demo-two main
printf '%s\n' '' 'Continuously changing agent-doc repository.' >> "$OC_WORK/demo/README.md"
oc_commit "$OC_WORK/demo" continuous-h-change
oc_push_work demo main
oc_run 2026-08-02 \
  OC_TEST_DISABLE_L2=0 \
  OC_SEAT_CMD="$seat_cmd" \
  OC_FAKE_SEAT_MODE=valid \
  OC_L2_MAX_REPOS=1 \
  OC_H_MAX_REPOS=1 \
  OC_ZERO_STREAK_NIGHTS=99
jq -e '
  ([.cells[] | select(.repo_id == 1102 and (.check_id == "OC-E" or .check_id == "OC-F" or .check_id == "OC-G") and .status == "RUN")] | length) == 3 and
  ([.cells[] | select(.repo_id == 1103 and .check_id == "OC-H" and .status == "RUN")] | length) == 1 and
  ([.cells[] | select(.repo_id == 1101 and (.check_id == "OC-E" or .check_id == "OC-F" or .check_id == "OC-G") and .deferred == true)] | length) == 3 and
  ([.cells[] | select(.repo_id == 1102 and .check_id == "OC-H" and .deferred == true)] | length) == 1 and
  ([.cells[] | select(.repo_id == 1101 and .check_id == "OC-H")] | length) == 0
' "$OC_STATE/report/2026-08-02.json" >/dev/null || fail 'least-recently-run did not advance both capped queues past continuously changing repositories'
jq -e -s 'length == 2 and all(.[]; .confirm_cost == "1分") and any(.[]; .kind == "org-consistency/OC-E") and any(.[]; .kind == "org-consistency/OC-H")' "$OC_CASE_ROOT/lanes/2026-08-02/findings.jsonl" >/dev/null || fail 'rotated layer-2 findings did not use the 1-minute ledger contract'

# Updating only the handbook re-runs H for every agent-doc repository even when
# that repository HEAD did not change. Prompt structure is asserted by the fake
# seat without depending on a model or network.
setup_l2_case l2-handbook 1201 0
oc_run 2026-08-01 OC_TEST_DISABLE_L2=0 OC_SEAT_CMD="$seat_cmd" OC_FAKE_SEAT_MODE=assert-input OC_L2_MAX_REPOS=10 OC_H_MAX_REPOS=10 OC_ZERO_STREAK_NIGHTS=99
oc_run 2026-08-02 OC_TEST_DISABLE_L2=0 OC_SEAT_CMD="$seat_cmd" OC_FAKE_SEAT_MODE=assert-input OC_L2_MAX_REPOS=10 OC_H_MAX_REPOS=10 OC_ZERO_STREAK_NIGHTS=99
jq -e '[.cells[] | select(.layer == 2)] | length == 0' "$OC_STATE/report/2026-08-02.json" >/dev/null || fail 'unchanged complete layer-2 inventory was not silent'
assert_not_contains 'QUEUED (' "$OC_STATE/report/2026-08-02.md"
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

# OC-E identity is anchored to README.md even when the seat chooses a different
# supplied README for display/evidence on consecutive inspections.
setup_l2_case l2-fingerprint 1251 0
oc_run 2026-08-01 OC_TEST_DISABLE_L2=0 OC_SEAT_CMD="$seat_cmd" OC_FAKE_SEAT_MODE=valid-ja OC_L2_MAX_REPOS=10 OC_H_MAX_REPOS=10 OC_ZERO_STREAK_NIGHTS=99
stable_fp=$(jq -r '.findings[] | select(.repo_id == 1251 and .check_id == "OC-E") | .fingerprint' "$OC_STATE/findings.json")
expected_stable_fp=$(python3 -B "$OC_CORE" fingerprint 2 OC-E 1251 README.md desc:api-readme)
[ "$stable_fp" = "$expected_stable_fp" ] || fail 'OC-E did not use the canonical README.md fingerprint input'
jq -e '.findings[] | select(.repo_id == 1251 and .check_id == "OC-E") | .file == "readme.ja.md"' "$OC_STATE/findings.json" >/dev/null || fail 'OC-E discarded the seat-selected display file'
printf '%s\n' '' 'Same description drift after a repository change.' >> "$OC_WORK/demo/README.md"
oc_commit "$OC_WORK/demo" same-description-drift
oc_push_work demo main
oc_run 2026-08-02 OC_TEST_DISABLE_L2=0 OC_SEAT_CMD="$seat_cmd" OC_FAKE_SEAT_MODE=valid OC_L2_MAX_REPOS=10 OC_H_MAX_REPOS=10 OC_ZERO_STREAK_NIGHTS=99
jq -e --arg fp "$stable_fp" '
  ([.findings[] | select(.repo_id == 1251 and .check_id == "OC-E")] | length) == 1 and
  (.findings[] | select(.repo_id == 1251 and .check_id == "OC-E") | .fingerprint == $fp and .last_seen == "2026-08-02")
' "$OC_STATE/findings.json" >/dev/null || fail 'OC-E ledger identity changed when the seat changed its display file'
jq -e '
  ([.findings.new[] | select(.repo_id == 1251 and .check_id == "OC-E")] | length) == 0 and
  ([.findings.resolved_candidates[] | select(.repo_id == 1251 and .check_id == "OC-E")] | length) == 0
' "$OC_STATE/report/2026-08-02.json" >/dev/null || fail 'OC-E fingerprint churned when the seat changed its display file'

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
for mode in invalid-json extra-field huge-claim fake-fingerprint non-utf8 deep-nest bad-target-token; do
  night_id=$(printf '2026-08-%02d' "$invalid_day")
  if [ "$mode" = extra-field ]; then
    printf '%s\n' blocked > "$OC_STATE/quarantine/$night_id"
  fi
  oc_run "$night_id" OC_TEST_DISABLE_L2=0 OC_SEAT_CMD="$seat_cmd" OC_FAKE_SEAT_MODE="$mode" OC_L2_MAX_REPOS=10 OC_H_MAX_REPOS=10 OC_ZERO_STREAK_NIGHTS=99
  if [ "$mode" = extra-field ]; then
    jq -e '
      ([.events[] | select(.type == "INVALID-OUTPUT" and .repo_id == 1301 and .launch == "OC-E/F/G")] | length) == 1 and
      ([.events[] | select(.type == "INVALID-OUTPUT" and .repo_id == 1301 and .launch == "OC-E/F/G" and has("quarantine"))] | length) == 0
    ' "$OC_STATE/report/$night_id.json" >/dev/null || fail 'blocked quarantine write still emitted a quarantine path on the INVALID-OUTPUT event'
  fi
  if [ "$mode" = extra-field ]; then
    [ -f "$OC_STATE/quarantine/$night_id" ] || fail 'quarantine write failure did not stay isolated'
    rm "$OC_STATE/quarantine/$night_id"
  fi
  jq -e '
    .complete == true and
    ([.cells[] | select(.repo_id == 1301 and .layer == 2 and .status == "INVALID-OUTPUT" and .fresh == false)] | length) == 4 and
    ([.cells[] | select(.layer == 2 and .repo_id != 1301)] | length) == 0 and
    ([.findings.self_health[] | select(.claim_kind == "invalid-output")] | length) == 1
  ' "$OC_STATE/report/$night_id.json" >/dev/null || fail "$mode was not rejected as INVALID-OUTPUT with self-health"
  jq -e 'all(.findings[]; if .check_id == "self-health" then true else .status == "open" end)' "$OC_STATE/findings.json" >/dev/null || fail "$mode resolved an open finding"
  if [ "$mode" = bad-target-token ]; then
    quarantine_file="$OC_STATE/quarantine/$night_id/1301-OC-E-F-G.txt"
    [ -f "$quarantine_file" ] || fail 'bad target_token stdout was not quarantined'
    grep -F '$HOME' "$quarantine_file" >/dev/null || fail 'quarantine did not preserve the violating target_token'
    jq -e --arg path "quarantine/$night_id/1301-OC-E-F-G.txt" '
      ([.events[] | select(.type == "INVALID-OUTPUT" and .repo_id == 1301 and .launch == "OC-E/F/G" and .quarantine == $path)] | length) == 1
    ' "$OC_STATE/report/$night_id.json" >/dev/null || fail 'INVALID-OUTPUT event did not link the quarantine file'
  fi
  invalid_day=$((invalid_day + 1))
done

oc_run 2026-08-09 OC_TEST_DISABLE_L2=0 OC_SEAT_CMD="$seat_cmd" OC_FAKE_SEAT_MODE=timeout OC_SEAT_TIMEOUT_SEC=1 OC_L2_MAX_REPOS=10 OC_H_MAX_REPOS=10 OC_ZERO_STREAK_NIGHTS=99
jq -e '([.cells[] | select(.repo_id == 1301 and .layer == 2 and .status == "NOT-RUN" and .reason == "seat-timeout" and .fresh == false)] | length) == 4' "$OC_STATE/report/2026-08-09.json" >/dev/null || fail 'per-launch timeout was not a non-fresh NOT-RUN result'

oc_run 2026-08-10 OC_TEST_DISABLE_L2=0 OC_SEAT_CMD="$seat_cmd" OC_FAKE_SEAT_MODE=valid OC_L2_MAX_REPOS=10 OC_H_MAX_REPOS=10 OC_ZERO_STREAK_NIGHTS=99
jq -e '
  ([.cells[] | select(.repo_id == 1301 and .layer == 2 and .status == "RUN" and .fresh == true)] | length) == 4 and
  ([.findings.new[] | select(.check_id == "OC-E" and .confidence == "high")] | length) == 0 and
  ([.findings.new[] | select(.check_id == "OC-H" and .confidence == "medium")] | length) == 0 and
  ([.findings.self_health[] | select(.claim_kind == "invalid-output")] | length) == 0
' "$OC_STATE/report/2026-08-10.json" >/dev/null || fail 'valid retry was not accepted or invalid-output self-health did not clear'
jq -e 'all(.findings[]; (.fingerprint | test("^[0-9a-f]{64}$")) and .fingerprint != "forged")' "$OC_STATE/findings.json" >/dev/null || fail 'seat-supplied fake fingerprint entered the findings ledger'

# Migration quietness must not consume a changed HEAD from the diff ledger;
# the first normal night on the new fingerprint version re-runs that HEAD.
printf '%s\n' '' 'Changed during fingerprint migration.' >> "$OC_WORK/demo/README.md"
oc_commit "$OC_WORK/demo" migration-head
oc_push_work demo main
oc_run 2026-08-11 OC_TEST_DISABLE_L2=0 OC_SEAT_CMD="$seat_cmd" OC_FAKE_SEAT_MODE=valid OC_FP_SPEC_VERSION=3 OC_L2_MAX_REPOS=10 OC_H_MAX_REPOS=10 OC_ZERO_STREAK_NIGHTS=99
jq -e '.migration_mode == true and .quiet_mode == "migration"' "$OC_STATE/report/2026-08-11.json" >/dev/null || fail 'layer-2 migration night was not quiet'
[ ! -s "$OC_CASE_ROOT/lanes/2026-08-11/findings.jsonl" ] || fail 'layer-2 migration night leaked proposals'
oc_run 2026-08-12 OC_TEST_DISABLE_L2=0 OC_SEAT_CMD="$seat_cmd" OC_FAKE_SEAT_MODE=valid OC_FP_SPEC_VERSION=3 OC_L2_MAX_REPOS=10 OC_H_MAX_REPOS=10 OC_ZERO_STREAK_NIGHTS=99
jq -e '([.cells[] | select(.repo_id == 1301 and .layer == 2 and .status == "RUN")] | length) == 4' "$OC_STATE/report/2026-08-12.json" >/dev/null || fail 'migration night consumed the changed layer-2 HEAD'

# A stale-target night may report all checks as NO-INPUT, but it must not consume
# the changed HEAD. The next FRESH night retries and then records completion.
setup_l2_case l2-no-input-stale 1351 0
oc_run 2026-08-01 OC_TEST_DISABLE_L2=0 OC_SEAT_CMD="$seat_cmd" OC_FAKE_SEAT_MODE=valid OC_L2_MAX_REPOS=10 OC_H_MAX_REPOS=10 OC_ZERO_STREAK_NIGHTS=99
old_efg_head=$(jq -r '.repos["1351"].layer2.efg_head' "$OC_STATE/repos.json")
rm "$OC_WORK/demo/README.md" "$OC_WORK/demo/README.ja.md" "$OC_WORK/demo/README.zh.md" "$OC_WORK/demo/README.th.md" "$OC_WORK/demo/AGENTS.md"
oc_commit "$OC_WORK/demo" remove-layer-two-inputs
oc_push_work demo main
oc_run 2026-08-02 OC_TEST_DISABLE_L2=0 OC_SEAT_CMD="$seat_cmd" OC_FAKE_SEAT_MODE=valid OC_TEST_API_FAIL=1 OC_L2_MAX_REPOS=10 OC_H_MAX_REPOS=10 OC_ZERO_STREAK_NIGHTS=99
jq -e --arg old "$old_efg_head" '
  .targets_label == "TARGETS: STALE (2026-08-01)" and
  ([.cells[] | select(.repo_id == 1351 and (.check_id == "OC-E" or .check_id == "OC-F" or .check_id == "OC-G") and .status == "NO-INPUT")] | length) == 3 and
  ([.cells[] | select(.repo_id == 1351 and .check_id == "OC-H")] | length) == 0 and
  .effective_settings.OC_FP_SPEC_VERSION == "2"
' "$OC_STATE/report/2026-08-02.json" >/dev/null || fail 'stale all-NO-INPUT retry precondition was not represented correctly'
jq -e --arg old "$old_efg_head" '.repos["1351"].layer2.efg_head == $old and .repos["1351"].layer2.efg_night == "2026-08-01" and .repos["1351"].head != $old' "$OC_STATE/repos.json" >/dev/null || fail 'stale all-NO-INPUT night consumed the changed E/F/G HEAD'
oc_run 2026-08-03 OC_TEST_DISABLE_L2=0 OC_SEAT_CMD="$seat_cmd" OC_FAKE_SEAT_MODE=valid OC_L2_MAX_REPOS=10 OC_H_MAX_REPOS=10 OC_ZERO_STREAK_NIGHTS=99
jq -e '.repos["1351"].layer2.efg_head == .repos["1351"].head and .repos["1351"].layer2.efg_night == "2026-08-03"' "$OC_STATE/repos.json" >/dev/null || fail 'fresh all-NO-INPUT retry did not consume the changed E/F/G HEAD'

# An unavailable handbook HEAD must not erase the last known inspected value;
# a later non-empty synchronized HEAD still advances normally.
/usr/bin/python3 -B - "$OC_CORE" "$OC_CASE_ROOT/mark-complete-state.json" <<'PY'
import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location("org_consistency_core", sys.argv[1])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
runner = module.Runner.__new__(module.Runner)
runner.findings_path = pathlib.Path(sys.argv[2])
runner.fp_spec_version = "2"
runner.night_id = "2026-08-01"
runner.handbook_repo = {"id": 2}
runner.repo_state = {"repos": {"1": {"layer2": {"h_handbook_head": "handbook-known"}}}}
repo = {"id": 1}
runner.mirror_results = {
    1: (True, {"new_head": "repo-new"}),
    2: (False, {"old_head": "handbook-known", "reason": "fetch-failed"}),
}
runner.mark_l2_complete(repo, "OC-H")
layer2 = runner.repo_state["repos"]["1"]["layer2"]
assert layer2["h_handbook_head"] == "handbook-known"
runner.night_id = "2026-08-02"
runner.mirror_results[2] = (True, {"new_head": "handbook-new"})
runner.mark_l2_complete(repo, "OC-H")
assert layer2["h_handbook_head"] == "handbook-new"
PY

# OC-E recognizes the top-level org-profile record without mutating the
# registry, while unrelated repositories still have no registry entry.
/usr/bin/python3 -B - "$OC_CORE" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("org_consistency_core", sys.argv[1])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
runner = module.Runner.__new__(module.Runner)
profile = {"repo": "caty-ai/.github", "files": {"en": "profile/README.md"}}
runner.registry = {"modules": [], "org_profile": profile}
entry = runner.registry_entry_for_repo({"full_name": "CATY-AI/.GITHUB"})
assert entry == {"org_profile": True, **profile}
assert entry is not profile
assert "org_profile" not in profile
assert runner.registry_entry_for_repo({"full_name": "caty-ai/unregistered"}) is None
PY

assert_contains 'registry/modules.json for registry_entry' "$OC_REPO_ROOT/lanes/org-consistency/prompts/efg.txt"

printf 'test_lane_org_consistency_layer2: PASS\n'
