#!/bin/bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
# shellcheck source=tests/helpers.sh
. "$TEST_DIR/helpers.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-metsuke-server.XXXXXX")
SERVER_PID=
CHILD_PID=
LATE_CHILD_PID=
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill -KILL "$SERVER_PID" 2>/dev/null || true
  fi
  if [ -n "$CHILD_PID" ]; then
    kill -KILL "$CHILD_PID" 2>/dev/null || true
  fi
  if [ -n "$LATE_CHILD_PID" ]; then
    kill -KILL "$LATE_CHILD_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

SERVE_SH="$ROOT/lanes/metsuke/serve-lp.sh"
REAL_PYTHON=$(command -v python3)
fake_bin="$TEST_TMP/bin"
checkout="$TEST_TMP/checkout"
lane="$TEST_TMP/lane"
port_state="$TEST_TMP/port-occupied"
mkdir -p "$fake_bin" "$checkout/node_modules" "$lane"

server_source="$TEST_TMP/fake-server.sh"
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  '/bin/sh -c '\''while :; do sleep 60; done'\'' &' \
  'child_pid=$!' \
  'printf "%s\n" "$child_pid" > "$FAKE_CHILD_PID_FILE"' \
  ': > "$FAKE_PORT_STATE"' \
  'stop() {' \
  '  /bin/sh -c '\''while :; do sleep 60; done'\'' &' \
  '  late_child_pid=$!' \
  '  printf "%s\n" "$late_child_pid" > "$FAKE_LATE_CHILD_PID_FILE"' \
  '  rm -f "$FAKE_PORT_STATE"' \
  '  while [ ! -e "$FAKE_LATE_CHILD_DISCOVERED" ]; do sleep 0.01; done' \
  '  exit 0' \
  '}' \
  'trap stop TERM INT' \
  'while :; do sleep 1; done' \
  > "$server_source"
chmod +x "$server_source"

# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'case "${1:-}" in' \
  '  run)' \
  '    case "${2:-}" in' \
  '      build) printf "%s\n" built >> "$FAKE_BUILD_LOG"; exit 0 ;;' \
  '      start) exec "$FAKE_SERVER_SOURCE" ;;' \
  '    esac' \
  '    ;;' \
  'esac' \
  'exit 2' \
  > "$fake_bin/npm"

# The production script prefers lsof for both pre-start and post-stop probes.
# This test seam models a listener with a state file because the test sandbox
# denies even localhost bind(2).
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  '[ -e "$FAKE_PORT_STATE" ]' \
  > "$fake_bin/lsof"

# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'if [ -e "$FAKE_PORT_STATE" ]; then' \
  '  case " $* " in *" -w "*) printf 200 ;; esac' \
  '  exit 0' \
  'fi' \
  'exit 7' \
  > "$fake_bin/curl"

# Process inspection is also denied by this test sandbox. Model only the two
# ps queries used by serve-lp.sh from the real PIDs written by the fixtures.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'case " $* " in' \
  '  *" -o stat= -p "*)' \
  '    target=${!#}' \
  '    if kill -0 "$target" 2>/dev/null; then printf "%s\n" S; exit 0; fi' \
  '    exit 1' \
  '    ;;' \
  '  *" -axo pid=,ppid= "*)' \
  '    root=$(sed -n "1p" "$LANE_DIR/metsuke-server.pid")' \
  '    child=$(sed -n "1p" "$FAKE_CHILD_PID_FILE")' \
  '    printf "%s %s\n" "$root" 1 "$child" "$root"' \
  '    if [ -s "$FAKE_LATE_CHILD_PID_FILE" ]; then' \
  '      late_child=$(sed -n "1p" "$FAKE_LATE_CHILD_PID_FILE")' \
  '      printf "%s %s\n" "$late_child" "$root"' \
  '      : > "$FAKE_LATE_CHILD_DISCOVERED"' \
  '    fi' \
  '    ;;' \
  '  *) exit 2 ;;' \
  'esac' \
  > "$fake_bin/ps"
chmod +x "$fake_bin/npm" "$fake_bin/lsof" "$fake_bin/curl" "$fake_bin/ps"

port=43123
caller_pgid=$("$REAL_PYTHON" -c 'import os; print(os.getpgrp())')
PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
FAKE_SERVER_SOURCE="$server_source" \
FAKE_CHILD_PID_FILE="$TEST_TMP/child.pid" \
FAKE_LATE_CHILD_PID_FILE="$TEST_TMP/late-child.pid" \
FAKE_LATE_CHILD_DISCOVERED="$TEST_TMP/late-child-discovered" \
FAKE_PORT_STATE="$port_state" \
FAKE_BUILD_LOG="$TEST_TMP/build.log" \
LANE_DIR="$lane" \
METSUKE_LP_CHECKOUT="$checkout" \
METSUKE_PORT="$port" \
  /bin/bash "$SERVE_SH" start

SERVER_PID=$(sed -n '1p' "$lane/metsuke-server.pid")
server_pgid=$("$REAL_PYTHON" -c 'import os,sys; print(os.getpgid(int(sys.argv[1])))' "$SERVER_PID")
[ "$server_pgid" = "$caller_pgid" ] ||
  fail "LP server left the caller process group ($server_pgid != $caller_pgid)"
child_pid=$(sed -n '1p' "$TEST_TMP/child.pid")
CHILD_PID=$child_pid
kill -0 "$SERVER_PID" 2>/dev/null || fail "fake LP server is not running"
kill -0 "$child_pid" 2>/dev/null || fail "fake LP descendant is not running"
[ -e "$port_state" ] || fail "offline port probe did not become occupied"

PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
FAKE_PORT_STATE="$port_state" \
FAKE_CHILD_PID_FILE="$TEST_TMP/child.pid" \
FAKE_LATE_CHILD_PID_FILE="$TEST_TMP/late-child.pid" \
FAKE_LATE_CHILD_DISCOVERED="$TEST_TMP/late-child-discovered" \
LANE_DIR="$lane" METSUKE_PORT="$port" \
  /bin/bash "$SERVE_SH" stop
LATE_CHILD_PID=$(sed -n '1p' "$TEST_TMP/late-child.pid")
if kill -0 "$child_pid" 2>/dev/null; then
  fail "serve stop left a live descendant process"
fi
if kill -0 "$LATE_CHILD_PID" 2>/dev/null; then
  fail "serve stop left a late descendant process"
fi
SERVER_PID=
CHILD_PID=
LATE_CHILD_PID=
[ ! -e "$port_state" ] || fail "serve stop did not free the offline port seam"

: > "$port_state"
: > "$TEST_TMP/occupied-build.log"
if PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  FAKE_SERVER_SOURCE="$server_source" \
  FAKE_CHILD_PID_FILE="$TEST_TMP/occupied-child.pid" \
  FAKE_PORT_STATE="$port_state" \
  FAKE_BUILD_LOG="$TEST_TMP/occupied-build.log" \
  LANE_DIR="$lane" \
  METSUKE_LP_CHECKOUT="$checkout" \
  METSUKE_PORT="$port" \
  /bin/bash "$SERVE_SH" start >"$TEST_TMP/occupied-stdout" 2>"$TEST_TMP/occupied-stderr"; then
  fail "serve start accepted an already occupied port"
fi
assert_contains "already occupied" "$TEST_TMP/occupied-stderr"
[ ! -s "$TEST_TMP/occupied-build.log" ] ||
  fail "serve start built the LP before refusing an occupied port"
rm -f "$port_state"

printf 'test_metsuke_server_lifecycle: PASS\n'
