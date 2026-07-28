#!/bin/bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
. "$TEST_DIR/helpers.sh"
. "$ROOT/lib/common.sh"
. "$ROOT/lib/lane-env.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-lane-env.XXXXXX")
REPO_LANE_TMP=
cleanup() {
  rm -rf "$TEST_TMP"
  if [ -n "$REPO_LANE_TMP" ]; then
    rm -rf "$REPO_LANE_TMP"
  fi
}
trap cleanup EXIT
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

fake_operator_home="$TEST_TMP/fake-operator-home"
fake_codex="$fake_operator_home/.codex"
fake_gitconfig="$fake_operator_home/.gitconfig"
mkdir -p "$fake_codex"
printf '%s\n' '{"dummy":"auth"}' > "$fake_codex/auth.json"
printf '%s\n' '[credential]' '	helper = osxkeychain' > "$fake_gitconfig"
LANE_HOME_LINKS="$fake_codex:$fake_gitconfig"
linked_lane="$STATE_DIR/linked-lane"
lane_exec "$linked_lane" /bin/bash -c '
  env > "$LANE_DIR/env.txt"
  cat "$HOME/.codex/auth.json" > "$LANE_DIR/auth-copy.json"
  if command -v gh >/dev/null 2>&1; then
    gh auth status >"$LANE_DIR/gh.txt" 2>&1
    printf "%s\n" "$?" > "$LANE_DIR/gh-status.txt"
  else
    printf "%s\n" "127" > "$LANE_DIR/gh-status.txt"
  fi
  git config --global --get credential.helper > "$LANE_DIR/git-helper.txt" 2>/dev/null
'
[ "$LANE_EXIT_CODE" -eq 0 ] || fail "opt-in HOME link lane failed"
[ -L "$linked_lane/home/.codex" ] || fail "opted-in Codex auth directory was not linked"
assert_contains '"dummy":"auth"' "$linked_lane/auth-copy.json"
assert_not_contains 'GH_TOKEN=' "$linked_lane/env.txt"
assert_not_contains 'GITHUB_TOKEN=' "$linked_lane/env.txt"
[ "$(sed -n '1p' "$linked_lane/gh-status.txt")" -ne 0 ] ||
  fail "gh authenticated despite isolated environment and dummy Codex auth"
[ ! -L "$linked_lane/home/.gitconfig" ] ||
  fail "reserved .gitconfig was replaced by an operator symlink"
[ -z "$(tr -d '[:space:]' < "$linked_lane/git-helper.txt")" ] ||
  fail "reserved empty credential helper was bypassed"

REPO_LANE_TMP=$(mktemp -d "$ROOT/state/lane-ceiling.XXXXXX")
LANE_HOME_LINKS=
lane_exec "$REPO_LANE_TMP/lane" /bin/bash -c '
  git rev-parse --show-toplevel > "$LANE_DIR/git-root.txt" 2>&1
  printf "%s\n" "$?" > "$LANE_DIR/git-root-status.txt"
'
[ "$(sed -n '1p' "$REPO_LANE_TMP/lane/git-root-status.txt")" -ne 0 ] ||
  fail "git discovery escaped the lane into the nightshift worktree"

LANE_TIMEBOX_MIN=0
timeout_lane="$STATE_DIR/timeout-lane"
lane_exec "$timeout_lane" /bin/bash -c '
  sleep 300 &
  printf "%s\n" "$!" > "$LANE_DIR/child.pid"
  sleep 300
'
[ "$LANE_TIMED_OUT" = true ] || fail "lane timebox did not mark the lane timed out"
[ "$LANE_EXIT_CODE" -ne 0 ] || fail "timed-out lane unexpectedly exited successfully"
assert_file_exists "$timeout_lane/child.pid"
child_pid=$(sed -n '1p' "$timeout_lane/child.pid")
child_wait=0
while kill -0 "$child_pid" 2>/dev/null && [ "$child_wait" -lt 20 ]; do
  sleep 0.1
  child_wait=$((child_wait + 1))
done
if kill -0 "$child_pid" 2>/dev/null; then
  fail "lane child process survived process-group timebox"
fi

printf 'test_lane_env_credentials: PASS\n'
