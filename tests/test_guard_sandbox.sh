#!/bin/bash
set -euo pipefail

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
ROOT=$(CDPATH= cd -- "$TEST_DIR/.." && pwd -P)
. "$TEST_DIR/helpers.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-sandbox.XXXXXX")
cleanup() {
  [ -z "${listener_one:-}" ] || kill "$listener_one" 2>/dev/null || true
  [ -z "${listener_two:-}" ] || kill "$listener_two" 2>/dev/null || true
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT
TEST_TMP=$(CDPATH= cd -- "$TEST_TMP" && pwd -P)
mkdir -p "$TEST_TMP/workspace" "$TEST_TMP/state"

"$ROOT/guard/render-sandbox.sh" \
  --workspace "$TEST_TMP/workspace" \
  --state "$TEST_TMP/state" > "$TEST_TMP/default.sb"
assert_contains '(deny network*)' "$TEST_TMP/default.sb"
assert_not_contains '(allow network-outbound' "$TEST_TMP/default.sb"
assert_contains '(deny process-info*)' "$TEST_TMP/default.sb"
assert_contains '(deny mach-lookup)' "$TEST_TMP/default.sb"
assert_contains '(deny sysctl-read)' "$TEST_TMP/default.sb"

"$ROOT/guard/render-sandbox.sh" \
  --workspace "$TEST_TMP/workspace" \
  --state "$TEST_TMP/state" \
  --fixture 127.0.0.1:48161 > "$TEST_TMP/fixture.sb"
assert_contains '(allow network-outbound (remote tcp "127.0.0.1:48161"))' "$TEST_TMP/fixture.sb"
if "$ROOT/guard/render-sandbox.sh" \
  --workspace "$TEST_TMP/workspace/../workspace" \
  --state "$TEST_TMP/state" >/dev/null 2>&1; then
  fail "sandbox renderer accepted traversal"
fi
if "$ROOT/guard/render-sandbox.sh" \
  --workspace "$TEST_TMP/workspace" \
  --state "$TEST_TMP/state" \
  --fixture 127.0.0.1:70000 >/dev/null 2>&1; then
  fail "sandbox renderer accepted an invalid fixture"
fi

# Accepted finding 2: every SBPL/sed metacharacter is rejected before rendering.
assert_sandbox_root_rejected() {
  bad_component=$1
  bad_label=$2
  bad_root=$TEST_TMP/$bad_component
  mkdir -p "$bad_root"
  if "$ROOT/guard/render-sandbox.sh" \
    --workspace "$bad_root" \
    --state "$TEST_TMP/state" >/dev/null 2>&1; then
    fail "sandbox renderer accepted $bad_label in a root"
  fi
}
assert_sandbox_root_rejected 'double"quote' 'double quote'
assert_sandbox_root_rejected "single'quote" 'single quote'
assert_sandbox_root_rejected 'white space' 'whitespace'
assert_sandbox_root_rejected 'open(paren' 'opening parenthesis'
assert_sandbox_root_rejected 'close)paren' 'closing parenthesis'
assert_sandbox_root_rejected 'amp&ersand' 'ampersand'
assert_sandbox_root_rejected 'pipe|root' 'pipe'
assert_sandbox_root_rejected 'back\slash' 'backslash'
assert_sandbox_root_rejected 'semi;colon' 'semicolon'
newline_component=$(/usr/bin/printf 'new\nline')
assert_sandbox_root_rejected "$newline_component" 'newline'

sandbox_digest=$(/usr/bin/shasum -a 256 /usr/bin/sandbox-exec | /usr/bin/awk '{print $1}')
sandbox_uid=$(/usr/bin/stat -f '%u' /usr/bin/sandbox-exec)
sandbox_mode=$(/usr/bin/stat -f '%Lp' /usr/bin/sandbox-exec)
/usr/bin/jq \
  --arg digest "$sandbox_digest" \
  --arg uid "$sandbox_uid" \
  --arg mode "$sandbox_mode" '
  .tools.sandbox_exec.sha256=$digest |
  .tools.sandbox_exec.uid=($uid|tonumber) |
  .tools.sandbox_exec.mode=$mode
' "$ROOT/config/guard-activation.example.json" > "$TEST_TMP/sandbox-only-manifest.json"
"$ROOT/guard/preflight.sh" \
  --manifest "$TEST_TMP/sandbox-only-manifest.json" > "$TEST_TMP/sandbox-only-preflight.json"
/usr/bin/jq -e '
  any(.cells[]; .category == "programs" and .name == "renderer" and .status == "UNPROVEN") and
  any(.cells[]; .category == "sandbox" and
    .name == "sandbox_runtime_capability" and .status == "UNPROVEN") and
  ([.cells[] | select(.category == "sandbox" and
    (.name == "exact_port_proof" or .name == "second_port_denial" or .name == "direct_network_denial"))] |
    length == 3 and all(.status == "UNPROVEN"))
' "$TEST_TMP/sandbox-only-preflight.json" >/dev/null ||
  fail "unproven renderer allowed a sandbox capability or fixture claim"

renderer_path=$ROOT/guard/render-sandbox.sh
renderer_digest=$(/usr/bin/shasum -a 256 "$renderer_path" | /usr/bin/awk '{print $1}')
renderer_uid=$(/usr/bin/stat -f '%u' "$renderer_path")
renderer_mode=$(/usr/bin/stat -f '%Lp' "$renderer_path")
/usr/bin/jq \
  --arg path "$renderer_path" \
  --arg digest "$renderer_digest" \
  --arg uid "$renderer_uid" \
  --arg mode "$renderer_mode" '
  .programs.renderer.path=$path |
  .programs.renderer.sha256=$digest |
  .programs.renderer.uid=($uid|tonumber) |
  .programs.renderer.mode=$mode
' "$TEST_TMP/sandbox-only-manifest.json" > "$TEST_TMP/sandbox-manifest.json"
"$ROOT/guard/preflight.sh" \
  --manifest "$TEST_TMP/sandbox-manifest.json" > "$TEST_TMP/preflight.json"

sandbox_supported=true
if ! /usr/bin/env -i \
  HOME=/var/empty \
  LANG=C \
  LC_ALL=C \
  PATH=/usr/bin:/bin \
  /usr/bin/sandbox-exec \
    -f "$TEST_TMP/default.sb" \
    /usr/bin/true >/dev/null 2>&1; then
  sandbox_supported=false
fi
sandbox_runtime_status=$(/usr/bin/jq -r '
  [.cells[] | select(.category == "sandbox" and .name == "sandbox_runtime_capability")] |
  if length == 1 then .[0].status else "INVALID" end
' "$TEST_TMP/preflight.json")
if [ "$sandbox_supported" = true ]; then
  expected_runtime_status=PROVEN
else
  expected_runtime_status=UNSUPPORTED
fi
[ "$sandbox_runtime_status" = "$expected_runtime_status" ] ||
  fail "preflight capability did not measure the rendered fixed Phase 1a profile"

if [ "$sandbox_supported" = true ]; then
  /usr/bin/jq -e '
    [.cells[] | select(.category == "sandbox" and
      (.name == "exact_port_proof" or .name == "second_port_denial" or .name == "direct_network_denial"))] |
    length == 3 and all(.status == "UNPROVEN")
  ' "$TEST_TMP/preflight.json" >/dev/null ||
    fail "sandbox runtime/fixture capability cells were inaccurate"
  /usr/bin/nc -l 127.0.0.1 48161 >/dev/null 2>&1 &
  listener_one=$!
  /usr/bin/nc -l 127.0.0.1 48162 >/dev/null 2>&1 &
  listener_two=$!
  sleep 0.1
  /usr/bin/sandbox-exec -f "$TEST_TMP/fixture.sb" \
    /usr/bin/nc -z 127.0.0.1 48161 >/dev/null 2>&1 ||
    fail "exact sandbox fixture port was not reachable"
  if /usr/bin/sandbox-exec -f "$TEST_TMP/fixture.sb" \
    /usr/bin/nc -z 127.0.0.1 48162 >/dev/null 2>&1; then
    fail "second loopback port escaped sandbox"
  fi
  if /usr/bin/sandbox-exec -f "$TEST_TMP/fixture.sb" \
    /usr/bin/nc -z 127.0.0.2 48161 >/dev/null 2>&1; then
    fail "undeclared direct network target escaped sandbox"
  fi
else
  # Accepted finding 8: assert the dedicated runtime and each named fixture cell.
  /usr/bin/jq -e '
    [.cells[] | select(.category == "sandbox" and
      (.name == "exact_port_proof" or .name == "second_port_denial" or .name == "direct_network_denial"))] |
    length == 3 and all(.status == "UNSUPPORTED")
  ' "$TEST_TMP/preflight.json" >/dev/null ||
    fail "unavailable sandbox runtime or named fixture cell was not marked unsupported"
fi

printf 'test_guard_sandbox: PASS\n'
