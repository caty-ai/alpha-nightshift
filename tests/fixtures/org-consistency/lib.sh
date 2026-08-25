#!/bin/bash
# Values declared here are consumed by the sourcing test suites.
# shellcheck disable=SC2034
set -euo pipefail

OC_FIXTURE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OC_REPO_ROOT=$(cd "$OC_FIXTURE_DIR/../../.." && pwd)
OC_RUN_SH="$OC_REPO_ROOT/lanes/org-consistency/run.sh"
OC_CORE="$OC_REPO_ROOT/lanes/org-consistency/core.py"

oc_case_init() {
  case_name=$1
  OC_CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/org-consistency-${case_name}.XXXXXX")
  OC_STATE="$OC_CASE_ROOT/state"
  OC_REMOTES="$OC_CASE_ROOT/remotes"
  OC_WORK="$OC_CASE_ROOT/work"
  OC_API="$OC_CASE_ROOT/api.json"
  mkdir -p "$OC_REMOTES" "$OC_WORK" "$OC_CASE_ROOT/home"
}

oc_git_init_work() {
  repo_name=$1
  branch=${2:-main}
  work="$OC_WORK/$repo_name"
  mkdir -p "$work"
  git -C "$work" init -q
  git -C "$work" config user.name 'Org Consistency Fixture'
  git -C "$work" config user.email 'fixture@example.invalid'
  git -C "$work" config core.hooksPath /dev/null
  git -C "$work" checkout -qb "$branch"
}

oc_write_checker() {
  work=$1
  mode=$2
  mkdir -p "$work/tools"
  case "$mode" in
    fail)
      printf '%s\n' \
        '#!/usr/bin/env python3' \
        'import sys' \
        'assert sys.argv[1:] == ["--offline"]' \
        'print("reality check       : skipped")' \
        'print("orphan check        : skipped")' \
        'print("pin freshness check : skipped")' \
        'print("ci existence check  : skipped")' \
        'print("FAILED (2):")' \
        'print("  - retired: README.md: stale https://github.com/old-owner/one")' \
        'print("  - retired: README.md: stale https://github.com/old-owner/two")' \
        'raise SystemExit(1)' \
        > "$work/tools/check_registry.py"
      ;;
    pass)
      printf '%s\n' \
        '#!/usr/bin/env python3' \
        'import sys' \
        'assert sys.argv[1:] == ["--offline"]' \
        'print("reality check       : skipped")' \
        'print("orphan check        : skipped")' \
        'print("pin freshness check : skipped")' \
        'print("ci existence check  : skipped")' \
        'print("OK")' \
        > "$work/tools/check_registry.py"
      ;;
    slow-pass)
      printf '%s\n' \
        '#!/usr/bin/env python3' \
        'import sys' \
        'import time' \
        'assert sys.argv[1:] == ["--offline"]' \
        'time.sleep(1)' \
        'print("reality check       : skipped")' \
        'print("orphan check        : skipped")' \
        'print("pin freshness check : skipped")' \
        'print("ci existence check  : skipped")' \
        'print("OK")' \
        > "$work/tools/check_registry.py"
      ;;
    degraded)
      printf '%s\n' \
        '#!/usr/bin/env python3' \
        'import sys' \
        'assert sys.argv[1:] == ["--offline"]' \
        'print("degraded: an offline input was skipped unexpectedly")' \
        'print("OK")' \
        > "$work/tools/check_registry.py"
      ;;
    unparsed)
      printf '%s\n' \
        '#!/usr/bin/env python3' \
        'import sys' \
        'assert sys.argv[1:] == ["--offline"]' \
        'print("checker contract changed unexpectedly")' \
        'raise SystemExit(9)' \
        > "$work/tools/check_registry.py"
      ;;
    *)
      printf 'unknown checker fixture mode: %s\n' "$mode" >&2
      return 2
      ;;
  esac
}

oc_commit() {
  work=$1
  message=$2
  git -C "$work" add -A
  git -C "$work" commit -qm "$message"
}

oc_make_remote() {
  repo_name=$1
  branch=${2:-main}
  checker_mode=${3:-pass}
  oc_git_init_work "$repo_name" "$branch"
  work="$OC_WORK/$repo_name"
  if [ "$checker_mode" != none ]; then
    oc_write_checker "$work" "$checker_mode"
  else
    printf '%s\n' fixture > "$work/README.md"
  fi
  oc_commit "$work" initial
  git clone -q --bare "$work" "$OC_REMOTES/$repo_name.git"
}

oc_push_work() {
  repo_name=$1
  branch=$2
  git -C "$OC_WORK/$repo_name" push -q --force "$OC_REMOTES/$repo_name.git" "$branch:$branch"
}

oc_write_single_api() {
  repo_id=$1
  repo_name=$2
  branch=${3:-main}
  clone_name=${4:-$repo_name}
  jq -n \
    --argjson id "$repo_id" \
    --arg name "$repo_name" \
    --arg full_name "caty-ai/$repo_name" \
    --arg branch "$branch" \
    --arg clone_url "https://github.com/caty-ai/$clone_name.git" \
    '[{id:$id,name:$name,full_name:$full_name,default_branch:$branch,clone_url:$clone_url,archived:false,private:false}]' \
    > "$OC_API"
}

oc_write_two_api() {
  first_id=$1
  first_name=$2
  second_id=$3
  second_name=$4
  jq -n \
    --argjson first_id "$first_id" \
    --arg first_name "$first_name" \
    --argjson second_id "$second_id" \
    --arg second_name "$second_name" \
    '[
      {id:$first_id,name:$first_name,full_name:("caty-ai/"+$first_name),default_branch:"main",clone_url:("https://github.com/caty-ai/"+$first_name+".git"),archived:false,private:false},
      {id:$second_id,name:$second_name,full_name:("caty-ai/"+$second_name),default_branch:"main",clone_url:("https://github.com/caty-ai/"+$second_name+".git"),archived:false,private:false}
    ]' > "$OC_API"
}

oc_run() {
  night=$1
  shift
  lane="$OC_CASE_ROOT/lanes/$night"
  mkdir -p "$lane/tmp" "$lane/home"
  /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin \
    HOME="$lane/home" \
    TMPDIR="$lane/tmp" \
    LANG=C \
    TERM=dumb \
    NIGHT_ID="$night" \
    LANE_DIR="$lane" \
    GIT_CEILING_DIRECTORIES="$lane" \
    OC_STATE_DIR="$OC_STATE" \
    OC_API_FIXTURE="$OC_API" \
    OC_TEST_FIXTURE_GIT_ROOT="$OC_REMOTES" \
    OC_TEST_MUTATE="${OC_TEST_MUTATE:-}" \
    "$@" \
    /bin/bash "$OC_RUN_SH"
}

oc_status() {
  night=$1
  repo_id=$2
  jq -r --argjson repo_id "$repo_id" \
    '.cells[] | select(.repo_id == $repo_id and .check_id == "OC-A") | .status' \
    "$OC_STATE/report/$night.json"
}
