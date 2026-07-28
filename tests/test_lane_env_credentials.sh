#!/bin/bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
. "$TEST_DIR/helpers.sh"
. "$ROOT/lib/common.sh"
. "$ROOT/lib/lane-env.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-lane-env.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT
STATE_DIR="$TEST_TMP/state"
NIGHT_ID=2026-07-28
LANE_TIMEBOX_MIN=1
LANE_HOME_LINKS=
LANG=${LANG:-C}
lane_dir="$STATE_DIR/lane"

export GH_TOKEN=fake-gh
export GITHUB_TOKEN=fake-github
export SSH_AUTH_SOCK="$TEST_TMP/fake-agent.sock"
export ANTHROPIC_API_KEY=fake-anthropic

lane_exec "$lane_dir" /bin/bash -c '
  env > "$LANE_DIR/env.txt"
  printf "%s\n" "$HOME" > "$LANE_DIR/home.txt"
  if command -v gh >/dev/null 2>&1; then
    gh auth status >"$LANE_DIR/gh.txt" 2>&1
    printf "%s\n" "$?" > "$LANE_DIR/gh-status.txt"
  else
    printf "%s\n" "127" > "$LANE_DIR/gh-status.txt"
  fi
  git config --get credential.helper > "$LANE_DIR/git-helper.txt" 2>/dev/null
  printf "%s\n" "$?" > "$LANE_DIR/git-helper-status.txt"
'

[ "$LANE_EXIT_CODE" -eq 0 ] || fail "lane environment inspection failed"
env_file="$lane_dir/env.txt"
assert_not_contains 'GH_TOKEN=' "$env_file"
assert_not_contains 'GITHUB_TOKEN=' "$env_file"
assert_not_contains 'SSH_AUTH_SOCK=' "$env_file"
assert_not_contains 'ANTHROPIC_API_KEY=' "$env_file"
if grep -E '(^|_)(API_KEY|TOKEN)=' "$env_file" >/dev/null 2>&1; then
  fail "an API key or token variable crossed into the lane environment"
fi
[ "$(sed -n '1p' "$lane_dir/home.txt")" = "$lane_dir/home" ] ||
  fail "lane HOME was not redirected"
[ "$(sed -n '1p' "$lane_dir/gh-status.txt")" -ne 0 ] ||
  fail "gh remained authenticated inside the isolated lane HOME"
[ -z "$(tr -d '[:space:]' < "$lane_dir/git-helper.txt")" ] ||
  fail "git credential.helper leaked from the user's HOME"

LANE_TIMEBOX_MIN=0
timeout_lane="$STATE_DIR/timeout-lane"
lane_exec "$timeout_lane" /bin/bash -c 'sleep 5'
[ "$LANE_TIMED_OUT" = true ] || fail "lane timebox did not mark the lane timed out"
[ "$LANE_EXIT_CODE" -ne 0 ] || fail "timed-out lane unexpectedly exited successfully"

printf 'test_lane_env_credentials: PASS\n'
