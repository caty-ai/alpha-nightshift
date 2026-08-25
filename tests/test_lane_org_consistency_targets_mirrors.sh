#!/bin/bash
# shellcheck disable=SC1091
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
. "$TEST_DIR/helpers.sh"
. "$TEST_DIR/fixtures/org-consistency/lib.sh"

oc_case_init targets
case_one=$OC_CASE_ROOT
trap 'rm -rf "$case_one" ${case_two:-} ${case_three:-} ${case_four:-}' EXIT

# Pagination follows Link, the 100-item page forces INCOMPLETE, and exclusion
# applies after the complete numeric-ID target set has been assembled.
python3 - "$OC_API" <<'PY'
import json
import sys
page_one = [
    {
        "id": index,
        "name": f"repo-{index}",
        "full_name": f"caty-ai/repo-{index}",
        "default_branch": "main",
        "clone_url": f"https://github.com/caty-ai/repo-{index}.git",
        "archived": False,
        "private": False,
    }
    for index in range(1, 101)
]
page_two = [{
    "id": 101,
    "name": "repo-101",
    "full_name": "caty-ai/repo-101",
    "default_branch": "main",
    "clone_url": "https://github.com/caty-ai/repo-101.git",
    "archived": False,
    "private": False,
}]
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"pages": [
        {"repos": page_one, "link": '<fixture://page/2>; rel="next"'},
        {"repos": page_two, "link": None},
    ]}, handle)
PY
target_json=$(OC_STATE_DIR="$OC_STATE" LANE_DIR="$OC_CASE_ROOT" NIGHT_ID=2026-08-01 \
  OC_API_FIXTURE="$OC_API" OC_TEST_MODE=1 OC_EXCLUDE_REPOS=repo-50 OC_TEST_MUTATE="${OC_TEST_MUTATE:-}" \
  python3 -B "$OC_CORE" targets)
printf '%s\n' "$target_json" > "$OC_CASE_ROOT/targets.json"
jq -e '.status == "FRESH" and .pages == 2 and .incomplete == true and .label == "TARGETS: FRESH / TARGETS: INCOMPLETE" and (.ids | length) == 100 and (.ids | index(101)) != null and (.ids | index(50)) == null' "$OC_CASE_ROOT/targets.json" >/dev/null || fail 'pagination/INCOMPLETE/exclusion target selection is wrong'

oc_case_init mirrors
case_two=$OC_CASE_ROOT
oc_make_remote family-os main none
oc_write_single_api 600 family-os main
oc_run 2026-08-01
[ "$(oc_status 2026-08-01 600)" = NO-INPUT ] || fail 'family-os without a checker did not produce NO-INPUT after a successful fetch'
mirror="$OC_STATE/mirrors/600"
first_head=$(git -C "$mirror" rev-parse HEAD)

printf '%s\n' changed >> "$OC_WORK/family-os/README.md"
oc_commit "$OC_WORK/family-os" update-readme
oc_push_work family-os main
oc_run 2026-08-02
second_head=$(git -C "$mirror" rev-parse HEAD)
[ "$first_head" != "$second_head" ] || fail 'mirror HEAD did not advance after fetch/reset'
assert_contains 'README.md' "$OC_STATE/diffs/2026-08-02/600.stat"

git -C "$OC_WORK/family-os" checkout -qb trunk
printf '%s\n' trunk >> "$OC_WORK/family-os/README.md"
oc_commit "$OC_WORK/family-os" switch-default
oc_push_work family-os trunk
oc_write_single_api 600 family-os trunk
oc_run 2026-08-03
jq -e '(.scope.branch_changed | length) == 1 and .scope.branch_changed[0].from == "main" and .scope.branch_changed[0].to == "trunk"' "$OC_STATE/report/2026-08-03.json" >/dev/null || fail 'default_branch change event is missing'
[ "$(git -C "$mirror" symbolic-ref --short HEAD)" = trunk ] || fail 'mirror did not move its checked-out head to the API default_branch'

mv "$OC_REMOTES/family-os.git" "$OC_REMOTES/family-os.git.offline"
oc_run 2026-08-04
[ "$(oc_status 2026-08-04 600)" = NOT-RUN ] || fail 'fetch failure did not mark the OC-A cell NOT-RUN'
jq -e '.scope.not_run == 1 and .cells[0].reason == "fetch-failed"' "$OC_STATE/report/2026-08-04.json" >/dev/null || fail 'fetch failure was not visible in the report'

mv "$OC_REMOTES/family-os.git.offline" "$OC_REMOTES/family-os.git"
oc_write_checker "$OC_WORK/family-os" pass
oc_commit "$OC_WORK/family-os" add-checker-before-rename
git clone -q --bare "$OC_WORK/family-os" "$OC_REMOTES/renamed.git"
oc_write_single_api 600 renamed trunk renamed
oc_run 2026-08-05
jq -e '(.scope.renamed | length) == 1 and .scope.renamed[0].from == "caty-ai/family-os" and .scope.renamed[0].to == "caty-ai/renamed" and (.cells | length) == 1 and .cells[0].repo_id == 600 and .cells[0].repo == "caty-ai/renamed" and .cells[0].status == "RUN" and .cells[0].reason == "checker-complete" and .cells[0].fresh == true' "$OC_STATE/report/2026-08-05.json" >/dev/null || fail 'numeric-ID rename did not keep OC-A on the renamed repository'
jq -e '.repos["600"].name_history | length == 2' "$OC_STATE/repos.json" >/dev/null || fail 'id-to-name history did not retain the rename'
[ -d "$OC_STATE/mirrors/600" ] || fail 'rename changed the numeric mirror path'

oc_run 2026-08-06 OC_TEST_API_FAIL=1
jq -e '.targets_label == "TARGETS: STALE (2026-08-05)"' "$OC_STATE/report/2026-08-06.json" >/dev/null || fail 'API failure did not use and date the previous snapshot'

# Without any usable target snapshot, identity reconciliation is unknown and
# must not manufacture rename/branch/left-scope events or erase prior state.
rm -rf "$OC_STATE/snapshots"
unavailable_rc=0
oc_run 2026-08-07 OC_TEST_API_FAIL=1 || unavailable_rc=$?
[ "$unavailable_rc" -eq 2 ] || fail 'TARGETS UNAVAILABLE did not fail closed'
jq -e '.targets_label == "TARGETS: UNAVAILABLE" and (.scope.left_scope | length) == 0 and (.scope.renamed | length) == 0 and (.scope.branch_changed | length) == 0' "$OC_STATE/report/2026-08-07.json" >/dev/null || fail 'TARGETS UNAVAILABLE fabricated identity events'
jq -e '.repos["600"].full_name == "caty-ai/renamed"' "$OC_STATE/repos.json" >/dev/null || fail 'TARGETS UNAVAILABLE erased repository identity state'

# Both write-ahead plans and journals retain exactly the newest 400 nights.
for index in $(seq -w 1 401); do
  printf '%s\n' '{}' > "$OC_STATE/plan-0000-$index.json"
  printf '%s\n' '{}' > "$OC_STATE/journal/0000-$index.json"
  printf '%s\n' '{}' > "$OC_STATE/snapshots/repos-0000-$index.json"
  mkdir -p "$OC_STATE/diffs/0000-$index"
  printf '%s\n' fixture > "$OC_STATE/diffs/0000-$index/600.stat"
done
oc_write_single_api 600 family-os trunk
oc_run 2026-08-08
[ "$(find "$OC_STATE" -maxdepth 1 -name 'plan-*.json' | wc -l | tr -d ' ')" -eq 400 ] || fail 'plan retention is not 400 nights'
[ "$(find "$OC_STATE/journal" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')" -eq 400 ] || fail 'journal retention is not 400 nights'
[ "$(find "$OC_STATE/snapshots" -maxdepth 1 -name 'repos-*.json' | wc -l | tr -d ' ')" -eq 400 ] || fail 'snapshot retention is not 400 nights'
[ "$(find "$OC_STATE/diffs" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" -eq 400 ] || fail 'diff retention is not 400 nights'
[ ! -e "$OC_STATE/plan-0000-001.json" ] && [ -e "$OC_STATE/plan-2026-08-08.json" ] || fail 'plan pruning did not retain the newest nights'
[ ! -e "$OC_STATE/journal/0000-001.json" ] && [ -e "$OC_STATE/journal/2026-08-08.json" ] || fail 'journal pruning did not retain the newest nights'
[ ! -e "$OC_STATE/snapshots/repos-0000-001.json" ] && [ -e "$OC_STATE/snapshots/repos-2026-08-08.json" ] || fail 'snapshot pruning did not retain the newest nights'
[ ! -e "$OC_STATE/diffs/0000-001" ] && [ -e "$OC_STATE/diffs/2026-08-08" ] || fail 'diff pruning did not retain the newest nights'

# A post-fetch Git plumbing failure is isolated to this repository and the
# lane still publishes a complete report instead of aborting the night.
oc_case_init git-finalize-failure
case_three=$OC_CASE_ROOT
oc_make_remote family-os main pass
oc_write_single_api 601 family-os main
mkdir -p "$OC_CASE_ROOT/git-shim"
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'if [ "$#" -ge 4 ] && [ "$3" = rev-parse ] && [ "$4" = FETCH_HEAD ]; then' \
  '  printf '\''injected rev-parse failure\n'\'' >&2' \
  '  exit 42' \
  'fi' \
  'exec /usr/bin/git "$@"' \
  > "$OC_CASE_ROOT/git-shim/git"
chmod +x "$OC_CASE_ROOT/git-shim/git"
oc_run 2026-08-01 PATH="$OC_CASE_ROOT/git-shim:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
jq -e '.complete == true and .cells[0].status == "NOT-RUN" and .cells[0].reason == "mirror-finalize-failed" and .cells[0].fresh == false' "$OC_STATE/report/2026-08-01.json" >/dev/null || fail 'unexpected Git failure aborted the lane instead of isolating the cell'

# OC-A is still planned when configuration removes family-os from tonight's
# target set. The explicit non-fresh cell keeps the night from looking green.
oc_case_init excluded-family-os
case_four=$OC_CASE_ROOT
oc_make_remote family-os main pass
oc_write_single_api 602 family-os main
oc_run 2026-08-01 OC_EXCLUDE_REPOS=family-os
jq -e '.complete == true and (.cells | length) == 1 and .cells[0].repo_id == 602 and .cells[0].repo == "caty-ai/family-os" and .cells[0].status == "NOT-RUN" and .cells[0].reason == "family-os-absent" and .cells[0].fresh == false and .scope.not_run == 1' "$OC_STATE/report/2026-08-01.json" >/dev/null || fail 'excluded family-os left no non-fresh OC-A trace'
[ ! -e "$OC_STATE/mirrors/602" ] || fail 'excluded family-os was fetched despite its NOT-RUN cell'

printf 'test_lane_org_consistency_targets_mirrors: PASS\n'
