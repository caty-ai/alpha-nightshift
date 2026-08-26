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

setup_l2_residual_case() {
  case_name=$1
  demo_id=$2
  with_second=${3:-1}
  oc_case_init "$case_name"
  case_roots+=("$OC_CASE_ROOT")

  oc_make_remote demo main none
  oc_make_remote family-os main pass
  oc_make_remote family-dev-handbook main none
  if [ "$with_second" = 1 ]; then
    oc_make_remote demo-two main none
  fi

  for repo_name in demo demo-two; do
    [ -d "$OC_WORK/$repo_name" ] || continue
    printf '%s\n' '# Agent procedure' 'Follow handbook rule FP-1 before issue-first.' > "$OC_WORK/$repo_name/AGENTS.md"
    oc_commit "$OC_WORK/$repo_name" agent-doc
    oc_push_work "$repo_name" main
  done

  mkdir -p "$OC_WORK/family-os/registry"
  printf '%s\n' '{"version":1,"modules":[]}' > "$OC_WORK/family-os/registry/modules.json"
  oc_commit "$OC_WORK/family-os" registry
  oc_push_work family-os main

  mkdir -p "$OC_WORK/family-dev-handbook/docs"
  printf '%s\n' '# Fail posture' '' '## FP-1 Serial fallback' '' 'Use serial execution when overlap cannot be verified.' > "$OC_WORK/family-dev-handbook/docs/05-fail-posture.md"
  oc_commit "$OC_WORK/family-dev-handbook" rules
  oc_push_work family-dev-handbook main

  handbook_id=$((demo_id + 2))
  family_id=$((demo_id + 3))
  if [ "$with_second" = 1 ]; then
    jq -n \
      --argjson demo "$demo_id" \
      --argjson demo_two "$((demo_id + 1))" \
      --argjson handbook "$handbook_id" \
      --argjson family "$family_id" \
      '[
        {id:$demo,name:"demo",full_name:"caty-ai/demo",description:"Demo",default_branch:"main",clone_url:"https://github.com/caty-ai/demo.git",archived:false,private:false},
        {id:$demo_two,name:"demo-two",full_name:"caty-ai/demo-two",description:"Demo two",default_branch:"main",clone_url:"https://github.com/caty-ai/demo-two.git",archived:false,private:false},
        {id:$handbook,name:"family-dev-handbook",full_name:"caty-ai/family-dev-handbook",description:"Handbook",default_branch:"main",clone_url:"https://github.com/caty-ai/family-dev-handbook.git",archived:false,private:false},
        {id:$family,name:"family-os",full_name:"caty-ai/family-os",description:"Registry",default_branch:"main",clone_url:"https://github.com/caty-ai/family-os.git",archived:false,private:false}
      ]' > "$OC_API"
  else
    jq -n \
      --argjson demo "$demo_id" \
      --argjson handbook "$handbook_id" \
      --argjson family "$family_id" \
      '[
        {id:$demo,name:"demo",full_name:"caty-ai/demo",description:"Demo",default_branch:"main",clone_url:"https://github.com/caty-ai/demo.git",archived:false,private:false},
        {id:$handbook,name:"family-dev-handbook",full_name:"caty-ai/family-dev-handbook",description:"Handbook",default_branch:"main",clone_url:"https://github.com/caty-ai/family-dev-handbook.git",archived:false,private:false},
        {id:$family,name:"family-os",full_name:"caty-ai/family-os",description:"Registry",default_branch:"main",clone_url:"https://github.com/caty-ai/family-os.git",archived:false,private:false}
      ]' > "$OC_API"
  fi
}

run_l2() {
  night=$1
  mode=$2
  shift 2
  oc_run "$night" \
    OC_TEST_DISABLE_L2=0 \
    OC_SEAT_CMD="$seat_cmd" \
    OC_FAKE_SEAT_MODE="$mode" \
    OC_L2_MAX_REPOS=1 \
    OC_H_MAX_REPOS=1 \
    OC_ZERO_STREAK_NIGHTS=99 \
    "$@"
}

# #64 regression: under each independent cap, a permanently failing repo must
# not pin the queue. Attempt nights advance on failure; inspected HEADs advance
# only on success, for both the E/F/G and H audit streams.
setup_l2_residual_case l2-failure-fairness 4101 1
selective_l2_cmd="OC_FAKE_SEAT_FAIL_REPO='caty-ai/demo' /bin/bash '$FAKE_SEAT'"
run_l2 2026-08-01 selective-valid OC_SEAT_CMD="$selective_l2_cmd"
jq -e '
  .repos["4101"].layer2.efg_night == "2026-08-01" and
  .repos["4101"].layer2.h_night == "2026-08-01" and
  ((.repos["4101"].layer2.efg_head // "") == "") and
  ((.repos["4101"].layer2.h_repo_head // "") == "")
' "$OC_STATE/repos.json" >/dev/null || fail 'failed layer-2 attempt consumed a HEAD or omitted its attempt night'
jq -e '
  ([.cells[] | select(.repo_id == 4101 and (.check_id == "OC-E" or .check_id == "OC-F" or .check_id == "OC-G") and .status == "NOT-RUN" and .reason == "seat-failed")] | length) == 3 and
  ([.cells[] | select(.repo_id == 4101 and .check_id == "OC-H" and .status == "NOT-RUN" and .reason == "seat-failed")] | length) == 1
' "$OC_STATE/report/2026-08-01.json" >/dev/null || fail 'mixed permanent-failure precondition did not exercise both layer-2 launches'
run_l2 2026-08-02 selective-valid OC_SEAT_CMD="$selective_l2_cmd"
jq -e '
  ([.cells[] | select(.repo_id == 4102 and (.check_id == "OC-E" or .check_id == "OC-F" or .check_id == "OC-G") and .status == "RUN")] | length) == 3 and
  ([.cells[] | select(.repo_id == 4102 and .check_id == "OC-H" and .status == "RUN")] | length) == 1 and
  ([.cells[] | select(.repo_id == 4101 and .layer == 2 and .deferred != true)] | length) == 0
' "$OC_STATE/report/2026-08-02.json" >/dev/null || fail 'permanent layer-2 failure starved the other capped repository'
jq -e '
  .repos["4101"].layer2.efg_night == "2026-08-01" and
  .repos["4101"].layer2.h_night == "2026-08-01" and
  ((.repos["4101"].layer2.efg_head // "") == "") and
  ((.repos["4101"].layer2.h_repo_head // "") == "") and
  .repos["4102"].layer2.efg_night == "2026-08-02" and
  .repos["4102"].layer2.h_night == "2026-08-02" and
  .repos["4102"].layer2.efg_head == .repos["4102"].head and
  .repos["4102"].layer2.h_repo_head == .repos["4102"].head
' "$OC_STATE/repos.json" >/dev/null || fail 'successful layer-2 attempt did not advance both attempt and HEAD audits'

# Prompt size is enforced before seat execution. A normal payload succeeds;
# after a large README change, a small limit produces visible non-fresh cells,
# records the fairness attempt, and preserves the prior successful HEAD. Raising
# the limit retries and consumes the changed HEAD.
setup_l2_residual_case prompt-limit 4201 0
run_l2 2026-08-01 valid OC_L2_MAX_REPOS=10 OC_H_MAX_REPOS=10 OC_PROMPT_MAX_BYTES=262144
old_head=$(jq -r '.repos["4201"].layer2.efg_head' "$OC_STATE/repos.json")
[ -n "$old_head" ] || fail 'prompt-limit positive control did not record a successful HEAD'
/usr/bin/python3 -B - "$OC_WORK/demo/README.md" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
path.write_text(path.read_text(encoding="utf-8") + "\n" + ("large public claim " * 2048), encoding="utf-8")
PY
oc_commit "$OC_WORK/demo" large-readme
oc_push_work demo main
run_l2 2026-08-02 valid OC_L2_MAX_REPOS=10 OC_H_MAX_REPOS=10 OC_PROMPT_MAX_BYTES=1024
jq -e '
  ([.cells[] | select(.repo_id == 4201 and (.check_id == "OC-E" or .check_id == "OC-F" or .check_id == "OC-G") and .status == "NOT-RUN" and .reason == "prompt-too-large" and .fresh == false)] | length) == 3
' "$OC_STATE/report/2026-08-02.json" >/dev/null || fail 'oversized prompt was not a visible non-fresh NOT-RUN'
jq -e --arg old "$old_head" '
  .repos["4201"].layer2.efg_night == "2026-08-02" and
  .repos["4201"].layer2.efg_head == $old and
  .repos["4201"].head != $old
' "$OC_STATE/repos.json" >/dev/null || fail 'prompt-too-large consumed the changed E/F/G HEAD or lost the attempt audit'
run_l2 2026-08-03 valid OC_L2_MAX_REPOS=10 OC_H_MAX_REPOS=10 OC_PROMPT_MAX_BYTES=262144
jq -e '
  ([.cells[] | select(.repo_id == 4201 and (.check_id == "OC-E" or .check_id == "OC-F" or .check_id == "OC-G") and .status == "RUN")] | length) == 3
' "$OC_STATE/report/2026-08-03.json" >/dev/null || fail 'raised prompt limit did not retry the changed repository'
jq -e '.repos["4201"].layer2.efg_night == "2026-08-03" and .repos["4201"].layer2.efg_head == .repos["4201"].head' "$OC_STATE/repos.json" >/dev/null || fail 'successful prompt retry did not consume the changed HEAD'

# The pinned public handbook corpus must exercise the deterministic rule-index
# extractor. This prevents an all-zero real-world OC-H input from passing CI.
CORPUS_ROOT="$TEST_DIR/fixtures/corpus/family-dev-handbook/49be5f3"
/usr/bin/env PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -B - "$OC_CORE" "$CORPUS_ROOT" <<'PY'
import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location("org_consistency_core", sys.argv[1])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
runner = module.Runner.__new__(module.Runner)
runner.org = "caty-ai"
runner.targets = [{"id": 4905, "full_name": "caty-ai/family-dev-handbook"}]
runner.mirror_results = {4905: (True, {"mirror": str(pathlib.Path(sys.argv[2]))})}
entries = runner.extract_handbook_index()
assert len(entries) > 0, "pinned handbook corpus extracted zero rule IDs"
assert any(item["rule_id"] == "FP-1" for item in entries)
assert all(item["file"].startswith("docs/0") for item in entries)
PY
[ "$(cat "$CORPUS_ROOT/UPSTREAM_SHA")" = 49be5f3c2b3ff84415bc8335111504c4fc36b69a ] || fail 'handbook corpus SHA pin changed unexpectedly'
assert_contains 'docs/05-fail-posture.md' "$CORPUS_ROOT/CORPUS.md"

printf 'test_lane_org_consistency_s4_residuals: PASS\n'
