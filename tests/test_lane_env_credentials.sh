#!/bin/bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
PYTHON_BIN=$(command -v python3)
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

process_inspection_available=true
sleep 1 &
inspection_child=$!
if ! inspection_children=$(pgrep -P "$$" 2>/dev/null) ||
  ! printf '%s\n' "$inspection_children" |
    grep -F -x "$inspection_child" >/dev/null 2>&1; then
  process_inspection_available=false
fi
kill "$inspection_child" 2>/dev/null || true
wait "$inspection_child" 2>/dev/null || true

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

sensitive_home="$TEST_TMP/sensitive-home"
mkdir -p \
  "$sensitive_home/.ssh" \
  "$sensitive_home/.config/gh" \
  "$sensitive_home/.aws" \
  "$sensitive_home/.gnupg"
printf '%s\n' secret > "$sensitive_home/.git-credentials"
printf '%s\n' secret > "$sensitive_home/.netrc"
printf '%s\n' planted-github-token > "$sensitive_home/.config/gh/hosts.yml"
ln -s "$sensitive_home/.config/gh" "$sensitive_home/github-alias"
LANE_HOME_LINKS="$sensitive_home/.ssh/:$sensitive_home//.ssh:$sensitive_home/./.ssh:$sensitive_home/.config:$sensitive_home/.config/gh:$sensitive_home/.config/gh/hosts.yml:$sensitive_home/.git-credentials:$sensitive_home/.netrc:$sensitive_home/.aws:$sensitive_home/.gnupg:$sensitive_home/github-alias"
if [ -e "$sensitive_home/.SsH" ]; then
  LANE_HOME_LINKS="$LANE_HOME_LINKS:$sensitive_home/.SsH"
fi
sensitive_lane="$STATE_DIR/sensitive-lane"
lane_exec "$sensitive_lane" /usr/bin/true
[ "$LANE_EXIT_CODE" -eq 0 ] || fail "denylisted HOME-link lane failed"
for refused_name in .ssh .config gh hosts.yml .git-credentials .netrc .aws .gnupg github-alias .SsH; do
  [ ! -L "$sensitive_lane/home/$refused_name" ] ||
    fail "sensitive HOME link $refused_name was accepted"
done
if grep -R -F 'planted-github-token' "$sensitive_lane/home" >/dev/null 2>&1; then
  fail "a planted GitHub token was readable through lane HOME"
fi

setup_failure_lane="$STATE_DIR/setup-failure-lane"
mkdir -p "$setup_failure_lane/home/.gitconfig"
if lane_exec "$setup_failure_lane" /usr/bin/true; then
  fail "lane_exec accepted an unwritable Git config target"
fi
[ "$LANE_SETUP_FAILED" = true ] ||
  fail "lane_exec did not classify its setup failure"

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

leader_exit_lane="$STATE_DIR/leader-exit-lane"
LANE_TIMEBOX_MIN=1
leader_exit_started=$(date '+%s')
lane_exec "$leader_exit_lane" /bin/bash -c '
  /bin/bash -c '\''trap "" HUP; exec sleep 300'\'' &
  printf "%s\n" "$!" > "$LANE_DIR/leader-exit-child.pid"
  exit 0
'
leader_exit_elapsed=$(( $(date '+%s') - leader_exit_started ))
[ "$leader_exit_elapsed" -lt 5 ] ||
  fail "leader-exit lane waited $leader_exit_elapsed seconds instead of stopping promptly"
[ "$LANE_LIFECYCLE_VIOLATION" = true ] ||
  fail "leader-exit lane did not report a lifecycle violation"
[ "$LANE_EXIT_CODE" -ne 0 ] ||
  fail "leader-exit lane reported a success-like exit"
[ "$LANE_TIMED_OUT" = false ] ||
  fail "leader-exit lane was incorrectly reported as timed out"
leader_exit_pid=$(sed -n '1p' "$leader_exit_lane/leader-exit-child.pid")
if kill -0 "$leader_exit_pid" 2>/dev/null; then
  fail "child survived after its lane leader exited first"
fi

setsid_lane="$STATE_DIR/setsid-lane"
LANE_TIMEBOX_MIN=0
lane_exec "$setsid_lane" /bin/bash -c "
  \"$PYTHON_BIN\" -c 'import os,time; time.sleep(0.2); os.setsid(); open(os.environ[\"LANE_DIR\"] + \"/setsid-child.pid\", \"w\").write(str(os.getpid())); time.sleep(300)' &
  wait
"
[ "$LANE_TIMED_OUT" = true ] || fail "setsid lane was not timed out"
if [ ! -f "$setsid_lane/setsid-child.pid" ]; then
  sed -n '1,80p' "$setsid_lane/lane.log" >&2
  fail "setsid child did not publish its pid"
fi
setsid_pid=$(sed -n '1p' "$setsid_lane/setsid-child.pid")
if kill -0 "$setsid_pid" 2>/dev/null; then
  if printf '%s\n' "$LANE_SURVIVORS_JSON" |
    jq -e --argjson pid "$setsid_pid" 'index($pid) != null' >/dev/null; then
    :
  elif [ "$process_inspection_available" = false ]; then
    [ "$LANE_PROCESS_INSPECTION_FAILED" = true ] ||
      fail "unavailable descendant inspection was not recorded"
    kill -KILL "$setsid_pid" 2>/dev/null || true
  else
    fail "setsid survivor was neither killed nor reported"
  fi
fi

printf 'test_lane_env_credentials: PASS\n'
