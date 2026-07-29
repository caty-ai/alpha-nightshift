#!/bin/bash
set -euo pipefail

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
ROOT=$(CDPATH= cd -- "$TEST_DIR/.." && pwd -P)
. "$TEST_DIR/helpers.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-bypass.XXXXXX")
cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT
TEST_TMP=$(CDPATH= cd -- "$TEST_TMP" && pwd -P)
MANIFEST=$ROOT/config/guard-activation.example.json
GIT=/opt/homebrew/bin/git
DETECTABLE_VALUE='ABCDEFGHIJKLMNOPQRSTUVWXYZ'"123456"
DETECTABLE_ASSIGNMENT="api_key=$DETECTABLE_VALUE"

mkdir -p "$TEST_TMP/stubs"
for command_name in git gh curl ssh security; do
  /usr/bin/printf '%s\n' \
    '#!/bin/bash' \
    "/usr/bin/touch \"$TEST_TMP/REMOTE_PATH_INVOKED\"" \
    'exit 99' > "$TEST_TMP/stubs/$command_name"
  chmod 755 "$TEST_TMP/stubs/$command_name"
done
export PATH="$TEST_TMP/stubs:/usr/bin:/bin"
export GH_TOKEN=planted
export GITHUB_TOKEN=planted
export GIT_ASKPASS="$TEST_TMP/stubs/gh"
export SSH_ASKPASS="$TEST_TMP/stubs/ssh"
export NETRC="$TEST_TMP/netrc"

for operation in \
  'push --no-verify HEAD:main' \
  'push --config core.hooksPath=/tmp/x' \
  'push HEAD:refs/heads/night/lane-proposed' \
  'push --push-option=x --signed' \
  'merge gh pr merge' \
  'api REST merge' \
  'graphql mutation' \
  'comment issue' \
  'label issue'; do
  if "$ROOT/guard/gateway.sh" $operation >/dev/null 2>&1; then
    fail "publication bypass was accepted: $operation"
  fi
done
[ ! -e "$TEST_TMP/REMOTE_PATH_INVOKED" ] ||
  fail "a remote command or credential lookup path was invoked"

for local_bypass in test_runner all_skip zero_tests runner_shim survivor_report open_handle; do
  if "$ROOT/guard/gateway.sh" "$local_bypass" >/dev/null 2>&1; then
    fail "unknown verification/broker field was accepted: $local_bypass"
  fi
done

REPO=$TEST_TMP/repo
"$GIT" init -q "$REPO"
"$GIT" -C "$REPO" config user.name night-bot
"$GIT" -C "$REPO" config user.email night-bot@users.noreply.github.com
/usr/bin/printf '%s\n' base > "$REPO/file.txt"
"$GIT" -C "$REPO" add file.txt
"$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'Base content'
BASE=$("$GIT" -C "$REPO" rev-parse HEAD)

scan_denied() {
  label=$1
  tip=$("$GIT" -C "$REPO" rev-parse HEAD)
  if "$ROOT/guard/scan.sh" \
    --repo "$REPO" \
    --repo-id sample/repo \
    --base "$BASE" \
    --candidate "$tip" \
    --manifest "$MANIFEST" > "$TEST_TMP/$label.out" 2>&1; then
    fail "scanner bypass was accepted: $label"
  fi
  assert_contains 'LOCAL_ONLY_REMOTE_UNPROVEN' "$TEST_TMP/$label.out"
}

reset_base() {
  "$GIT" -C "$REPO" reset -q --hard "$BASE"
}

/usr/bin/printf '%s\n' '[extend]' 'useDefault = true' > "$REPO/.gitleaks.toml"
"$GIT" -C "$REPO" add .gitleaks.toml
"$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'Scanner policy fixture'
scan_denied candidate-scanner-config

reset_base
/usr/bin/printf '%s\n' clean > "$REPO/file.txt"
"$GIT" -C "$REPO" add file.txt
GIT_AUTHOR_NAME=intruder GIT_AUTHOR_EMAIL=intruder@example.invalid \
  "$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'Identity fixture'
scan_denied identity-mismatch

reset_base
/usr/bin/printf '%s\n' header > "$REPO/file.txt"
"$GIT" -C "$REPO" add file.txt
GIT_AUTHOR_NAME="$DETECTABLE_ASSIGNMENT" \
GIT_AUTHOR_EMAIL=intruder@example.invalid \
  "$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'Header fixture'
scan_denied commit-header-secret
assert_not_contains "$DETECTABLE_VALUE" "$TEST_TMP/commit-header-secret.out"

reset_base
/usr/bin/printf '%s\n' clean2 > "$REPO/file.txt"
"$GIT" -C "$REPO" add file.txt
"$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'Mentions #123'
scan_denied message-reference

reset_base
/usr/bin/printf '%s\n' clean3 > "$REPO/file.txt"
"$GIT" -C "$REPO" add file.txt
"$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm \
  "$DETECTABLE_ASSIGNMENT"
scan_denied commit-message-secret
assert_not_contains "$DETECTABLE_VALUE" "$TEST_TMP/commit-message-secret.out"

reset_base
"$GIT" -C "$REPO" switch -q -c side "$BASE"
/usr/bin/printf '%s\n' side > "$REPO/file.txt"
"$GIT" -C "$REPO" add file.txt
"$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'Side content'
"$GIT" -C "$REPO" switch -q -c merge-fixture "$BASE"
/usr/bin/printf '%s\n' main > "$REPO/file.txt"
"$GIT" -C "$REPO" add file.txt
"$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'Main content'
set +e
"$GIT" -C "$REPO" -c core.hooksPath=/dev/null merge --no-commit side >/dev/null 2>&1
set -e
/usr/bin/printf '%s\n' "$DETECTABLE_ASSIGNMENT" > "$REPO/file.txt"
"$GIT" -C "$REPO" add file.txt
"$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'Merge resolution'
scan_denied merge-resolution
assert_not_contains "$DETECTABLE_VALUE" "$TEST_TMP/merge-resolution.out"

reset_base
alternate=$TEST_TMP/alternate
mkdir -p "$alternate"
/usr/bin/printf '%s\n' "$alternate" > "$REPO/.git/objects/info/alternates"
if "$ROOT/guard/scan.sh" \
  --repo "$REPO" \
  --repo-id sample/repo \
  --base "$BASE" \
  --candidate "$BASE" \
  --manifest "$MANIFEST" > "$TEST_TMP/alternate.out" 2>&1; then
  fail "Git object alternates were accepted"
fi
assert_contains 'LOCAL_ONLY_REMOTE_UNPROVEN' "$TEST_TMP/alternate.out"

printf 'test_guard_bypass: PASS\n'
