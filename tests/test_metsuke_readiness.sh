#!/bin/bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
# shellcheck source=tests/helpers.sh
. "$TEST_DIR/helpers.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-metsuke-readiness.XXXXXX")
TEST_TMP=$(cd -P "$TEST_TMP" && pwd -P)
trap 'rm -rf "$TEST_TMP"' EXIT

CHECKER_SOURCE="$ROOT/lanes/metsuke/check-readiness.sh"
LOCKFILE="$ROOT/lanes/metsuke/package-lock.json"
FIXTURE_ROOT="$TEST_TMP/fixture"
LANE="$FIXTURE_ROOT/lane"
LP="$FIXTURE_ROOT/lp"
CACHE="$FIXTURE_ROOT/browser-cache"
CODEX="$FIXTURE_ROOT/bin/codex"
STATE="$FIXTURE_ROOT/state/future/night"
MARKER="$TEST_TMP/prohibited-command-ran"
SECRET='PLANTED_METSUKE_SECRET_9f1d'
REAL_JQ=$(command -v jq)
export MARKER

write_fixture_metadata() {
  local playwright_version=$1
  local chromium_revision=$2
  local headless_shell_revision=${3:-$2}
  mkdir -p \
    "$LANE/node_modules/playwright" \
    "$LANE/node_modules/playwright-core" \
    "$LP/node_modules" \
    "$CACHE/chromium-1193/chrome-mac/Chromium.app/Contents/MacOS" \
    "$CACHE/chromium_headless_shell-1193/chrome-mac" \
    "$FIXTURE_ROOT/bin" \
    "$FIXTURE_ROOT/state"
  cp "$CHECKER_SOURCE" "$LANE/check-readiness.sh"
  chmod +x "$LANE/check-readiness.sh"
  printf '{\n  "name": "playwright",\n  "version": "%s"\n}\n' \
    "$playwright_version" > "$LANE/node_modules/playwright/package.json"
  printf '{\n  "name": "playwright-core",\n  "version": "%s"\n}\n' \
    "$playwright_version" > "$LANE/node_modules/playwright-core/package.json"
  printf '{\n  "browsers": [\n    {\n      "name": "chromium",\n      "revision": "%s",\n      "installByDefault": true\n    },\n    {\n      "name": "chromium-headless-shell",\n      "revision": "%s",\n      "installByDefault": true\n    }\n  ]\n}\n' \
    "$chromium_revision" \
    "$headless_shell_revision" \
    > "$LANE/node_modules/playwright-core/browsers.json"
  printf '#!/bin/bash\n: > "$MARKER"\n' \
    > "$CACHE/chromium-1193/chrome-mac/Chromium.app/Contents/MacOS/Chromium"
  printf '#!/bin/bash\n: > "$MARKER"\n' \
    > "$CACHE/chromium_headless_shell-1193/chrome-mac/headless_shell"
  printf '#!/bin/bash\n: > "$MARKER"\n' > "$CODEX"
  chmod +x \
    "$CACHE/chromium-1193/chrome-mac/Chromium.app/Contents/MacOS/Chromium" \
    "$CACHE/chromium_headless_shell-1193/chrome-mac/headless_shell" \
    "$CODEX"
}

run_checker() {
  "$LANE/check-readiness.sh" \
    --lp-checkout "$LP" \
    --browser-cache "$CACHE" \
    --codex-bin "$CODEX" \
    --state-dir "$STATE"
}

expect_failure() {
  local expected=$1
  local output=$2
  shift 2
  if "$@" >"$output" 2>&1; then
    fail "expected readiness failure containing: $expected"
  fi
  assert_contains "$expected" "$output"
  assert_not_contains "$SECRET" "$output"
}

"$REAL_JQ" -e '
  .lockfileVersion == 3 and
  .packages[""].dependencies.playwright == "1.55.1" and
  .packages["node_modules/playwright"].version == "1.55.1" and
  .packages["node_modules/playwright"].dependencies["playwright-core"] == "1.55.1" and
  .packages["node_modules/playwright"].optionalDependencies.fsevents == "2.3.2" and
  .packages["node_modules/playwright-core"].version == "1.55.1" and
  .packages["node_modules/fsevents"].version == "2.3.2" and
  (.packages | keys | sort) == [
    "",
    "node_modules/fsevents",
    "node_modules/playwright",
    "node_modules/playwright-core"
  ]
' "$LOCKFILE" >/dev/null || fail "package-lock.json does not pin the expected graph"

fake_bin="$TEST_TMP/fake-bin"
mkdir -p "$fake_bin"
for command_name in \
  npm npx pnpm yarn node playwright chromium chrome codex \
  git gh curl wget nc ssh dig host nslookup brew install; do
  printf '#!/bin/bash\n: > "$MARKER"\nexit 97\n' > "$fake_bin/$command_name"
  chmod +x "$fake_bin/$command_name"
done
PATH="$fake_bin:/usr/bin:/bin"
export PATH

write_fixture_metadata 1.55.1 1193
ready_output="$TEST_TMP/ready.out"
MARKER="$MARKER" \
  PLANTED_SECRET="$SECRET" \
  run_checker >"$ready_output" 2>"$TEST_TMP/ready.err" || {
  sed -n '1,40p' "$TEST_TMP/ready.err" >&2
  fail "valid readiness fixture was rejected"
}
[ ! -e "$MARKER" ] || fail "a prohibited command was invoked"
[ ! -e "$STATE" ] || fail "readiness checker created the state directory"
[ ! -s "$TEST_TMP/ready.err" ] || fail "ready path wrote stderr"
assert_not_contains "$SECRET" "$ready_output"
"$REAL_JQ" -e \
  --arg lp "$LP" \
  --arg cache "$CACHE" \
  --arg codex "$CODEX" \
  --arg state "$STATE" '
    . == {
      ready: true,
      playwright_version: "1.55.1",
      chromium_revision: "1193",
      lp_checkout: $lp,
      browser_cache: $cache,
      codex_bin: $codex,
      state_dir: $state
    }
  ' "$ready_output" >/dev/null || fail "ready output contract changed"

alternate_lane="$FIXTURE_ROOT/alternate-lane"
mkdir -p "$alternate_lane"
cp -R "$LANE/node_modules" "$alternate_lane/node_modules"
ln -s "$LANE/check-readiness.sh" "$alternate_lane/check-readiness.sh"
expect_failure "checker_self" "$TEST_TMP/checker-self-symlink.out" \
  "$alternate_lane/check-readiness.sh" \
  --lp-checkout "$LP" \
  --browser-cache "$CACHE" \
  --codex-bin "$CODEX" \
  --state-dir "$STATE"

mv "$LANE/node_modules/playwright" "$LANE/node_modules/playwright.missing"
expect_failure "playwright_package" "$TEST_TMP/missing-dependency.out" run_checker
mv "$LANE/node_modules/playwright.missing" "$LANE/node_modules/playwright"

write_fixture_metadata 1.54.0 1193
expect_failure "playwright_version" "$TEST_TMP/version-mismatch.out" run_checker

write_fixture_metadata 1.55.0 1193
expect_failure "playwright_version" \
  "$TEST_TMP/vulnerable-version-mismatch.out" run_checker

write_fixture_metadata 1.55.2 1193
expect_failure "playwright_version" \
  "$TEST_TMP/future-version-mismatch.out" run_checker

write_fixture_metadata 1.55.1 1193
printf '%s\n' \
  '{"name":"playwright","dependencies":{"version":"1.55.1"}}' \
  > "$LANE/node_modules/playwright/package.json"
expect_failure "playwright_version" \
  "$TEST_TMP/playwright-nested-only-version.out" run_checker

write_fixture_metadata 1.55.1 1193
printf '%s\n' \
  '{"name":"playwright-core","dependencies":{"version":"1.55.1"}}' \
  > "$LANE/node_modules/playwright-core/package.json"
expect_failure "playwright_core_version" \
  "$TEST_TMP/playwright-core-nested-only-version.out" run_checker

write_fixture_metadata 1.55.1 1193
printf '%s\n' \
  '{"name":"not-playwright","version":"1.55.1"}' \
  > "$LANE/node_modules/playwright/package.json"
expect_failure "playwright_version" \
  "$TEST_TMP/playwright-wrong-package-name.out" run_checker

write_fixture_metadata 1.55.1 1193
printf '%s\n' \
  '{"name":"not-playwright-core","version":"1.55.1"}' \
  > "$LANE/node_modules/playwright-core/package.json"
expect_failure "playwright_core_version" \
  "$TEST_TMP/playwright-core-wrong-package-name.out" run_checker

write_fixture_metadata 1.55.1 1193
printf '%s\n' \
  '{"name":"playwright-core","version":"1.55.0"}' \
  > "$LANE/node_modules/playwright-core/package.json"
expect_failure "playwright_core_version" \
  "$TEST_TMP/playwright-core-vulnerable-version.out" run_checker

write_fixture_metadata 1.55.1 1193
printf '%s\n' \
  '{"name":"playwright"}' \
  > "$LANE/node_modules/playwright/package.json"
expect_failure "playwright_version" \
  "$TEST_TMP/playwright-missing-version.out" run_checker

write_fixture_metadata 1.55.1 1193
printf '%s\n' \
  '{"name":"playwright","version":1.55}' \
  > "$LANE/node_modules/playwright/package.json"
expect_failure "playwright_version" \
  "$TEST_TMP/playwright-non-string-version.out" run_checker

write_fixture_metadata 1.55.1 1187 1193
expect_failure "chromium_revision" "$TEST_TMP/chromium-revision-mismatch.out" run_checker

write_fixture_metadata 1.55.1 1193 1187
expect_failure "chromium_headless_shell_revision" \
  "$TEST_TMP/headless-revision-mismatch.out" run_checker

write_fixture_metadata 1.55.1 1193
printf '%s\n' \
  '{"browsers":[{"name":"chromium","revision":"1193"}]}' \
  > "$LANE/node_modules/playwright-core/browsers.json"
expect_failure "chromium_headless_shell_revision" \
  "$TEST_TMP/headless-metadata-missing.out" run_checker

write_fixture_metadata 1.55.1 1193
printf '%s\n' \
  '{"browsers":[{"name":"chromium","revision":"1193"},{"name":"chromium-headless-shell","revision":"1193"},{"name":"chromium-headless-shell","revision":"1193"}]}' \
  > "$LANE/node_modules/playwright-core/browsers.json"
expect_failure "chromium_headless_shell_revision" \
  "$TEST_TMP/headless-metadata-duplicate.out" run_checker

write_fixture_metadata 1.55.1 1193
printf '%s\n' \
  '{"metadata":{"browsers":[{"name":"chromium","revision":"1193"},{"name":"chromium-headless-shell","revision":"1193"}]}}' \
  > "$LANE/node_modules/playwright-core/browsers.json"
expect_failure "chromium_revision" \
  "$TEST_TMP/browser-nested-only-metadata.out" run_checker

write_fixture_metadata 1.55.1 1193
printf '%s\n' '{' > "$LANE/node_modules/playwright-core/browsers.json"
expect_failure "chromium_revision" \
  "$TEST_TMP/browser-malformed-metadata.out" run_checker

write_fixture_metadata 1.55.1 1193
rm -rf "$CACHE/chromium_headless_shell-1193"
expect_failure "chromium_headless_shell_executable" \
  "$TEST_TMP/headed-only-cache.out" run_checker

write_fixture_metadata 1.55.1 1193
rm "$CACHE/chromium_headless_shell-1193/chrome-mac/headless_shell"
expect_failure "chromium_headless_shell_executable" \
  "$TEST_TMP/headless-missing.out" run_checker

write_fixture_metadata 1.55.1 1193
chmod -x "$CACHE/chromium_headless_shell-1193/chrome-mac/headless_shell"
expect_failure "chromium_headless_shell_executable" \
  "$TEST_TMP/headless-not-executable.out" run_checker

write_fixture_metadata 1.55.1 1193
mv \
  "$CACHE/chromium_headless_shell-1193" \
  "$CACHE/chromium_headless_shell-1194"
expect_failure "chromium_headless_shell_executable" \
  "$TEST_TMP/headless-cache-revision.out" run_checker

write_fixture_metadata 1.55.1 1193
rmdir "$LP/node_modules"
expect_failure "lp_node_modules" "$TEST_TMP/lp-node-modules.out" run_checker

write_fixture_metadata 1.55.1 1193
expect_failure "lp_checkout" "$TEST_TMP/relative.out" \
  "$LANE/check-readiness.sh" \
  --lp-checkout relative/lp \
  --browser-cache "$CACHE" \
  --codex-bin "$CODEX" \
  --state-dir "$STATE"

expect_failure "duplicate --lp-checkout" "$TEST_TMP/duplicate.out" \
  "$LANE/check-readiness.sh" \
  --lp-checkout "$LP" \
  --lp-checkout "$LP" \
  --browser-cache "$CACHE" \
  --codex-bin "$CODEX" \
  --state-dir "$STATE"

expect_failure "unknown argument" "$TEST_TMP/unknown.out" \
  "$LANE/check-readiness.sh" \
  --lp-checkout "$LP" \
  --browser-cache "$CACHE" \
  --codex-bin "$CODEX" \
  --state-dir "$STATE" \
  --network maybe

expect_failure "missing --state-dir" "$TEST_TMP/missing-argument.out" \
  "$LANE/check-readiness.sh" \
  --lp-checkout "$LP" \
  --browser-cache "$CACHE" \
  --codex-bin "$CODEX"

expect_failure "path is not canonical" "$TEST_TMP/noncanonical.out" \
  "$LANE/check-readiness.sh" \
  --lp-checkout "$FIXTURE_ROOT/./lp" \
  --browser-cache "$CACHE" \
  --codex-bin "$CODEX" \
  --state-dir "$STATE"

ln -s "$LP" "$FIXTURE_ROOT/lp-link"
expect_failure "symlink paths are refused" "$TEST_TMP/lp-symlink.out" \
  "$LANE/check-readiness.sh" \
  --lp-checkout "$FIXTURE_ROOT/lp-link" \
  --browser-cache "$CACHE" \
  --codex-bin "$CODEX" \
  --state-dir "$STATE"

ln -s "$CACHE" "$FIXTURE_ROOT/cache-link"
expect_failure "symlink paths are refused" "$TEST_TMP/cache-symlink.out" \
  "$LANE/check-readiness.sh" \
  --lp-checkout "$LP" \
  --browser-cache "$FIXTURE_ROOT/cache-link" \
  --codex-bin "$CODEX" \
  --state-dir "$STATE"

ln -s "$CODEX" "$FIXTURE_ROOT/bin/codex-link"
expect_failure "symlink files are refused" "$TEST_TMP/codex-symlink.out" \
  "$LANE/check-readiness.sh" \
  --lp-checkout "$LP" \
  --browser-cache "$CACHE" \
  --codex-bin "$FIXTURE_ROOT/bin/codex-link" \
  --state-dir "$STATE"

mkdir -p "$FIXTURE_ROOT/real-state-parent"
ln -s "$FIXTURE_ROOT/real-state-parent" "$FIXTURE_ROOT/state-link"
expect_failure "state_parent" "$TEST_TMP/state-symlink.out" \
  "$LANE/check-readiness.sh" \
  --lp-checkout "$LP" \
  --browser-cache "$CACHE" \
  --codex-bin "$CODEX" \
  --state-dir "$FIXTURE_ROOT/state-link/future"

blocked_parent="$FIXTURE_ROOT/blocked-state"
mkdir -p "$blocked_parent"
chmod 500 "$blocked_parent"
expect_failure "nearest existing parent is not writable" \
  "$TEST_TMP/state-not-writable.out" \
  "$LANE/check-readiness.sh" \
  --lp-checkout "$LP" \
  --browser-cache "$CACHE" \
  --codex-bin "$CODEX" \
  --state-dir "$blocked_parent/future"
chmod 700 "$blocked_parent"

state_file="$FIXTURE_ROOT/state-file"
: > "$state_file"
expect_failure "state_parent" "$TEST_TMP/state-file-parent.out" \
  "$LANE/check-readiness.sh" \
  --lp-checkout "$LP" \
  --browser-cache "$CACHE" \
  --codex-bin "$CODEX" \
  --state-dir "$state_file/future"

[ ! -e "$MARKER" ] || fail "a prohibited command was invoked during failures"
printf 'test_metsuke_readiness: PASS\n'
