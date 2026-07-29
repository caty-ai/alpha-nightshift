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
PROTECTED_PID=
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
  if [ -n "$PROTECTED_PID" ]; then
    kill -KILL "$PROTECTED_PID" 2>/dev/null || true
    wait "$PROTECTED_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

wait_for_dead() {
  local process_pid=$1
  local wait_ticks=0
  while [ "$wait_ticks" -lt 50 ]; do
    kill -0 "$process_pid" 2>/dev/null || return 0
    sleep 0.02
    wait_ticks=$((wait_ticks + 1))
  done
  return 1
}

SERVE_SH="$ROOT/lanes/metsuke/serve-lp.sh"
REAL_PYTHON=$(command -v python3)
fake_bin="$TEST_TMP/bin"
checkout="$TEST_TMP/checkout"
lane="$TEST_TMP/lane"
port_state="$TEST_TMP/port-occupied"
mkdir -p "$fake_bin" "$checkout/node_modules" "$lane"

server_source="$TEST_TMP/fake-server.py"
printf '%s\n' \
  '#!/usr/bin/env python3' \
  'import os' \
  'import signal' \
  'import subprocess' \
  'import time' \
  '' \
  'early = subprocess.Popen(["/bin/sh", "-c", "while :; do sleep 60; done"])' \
  'with open(os.environ["FAKE_CHILD_PID_FILE"], "w", encoding="utf-8") as handle:' \
  '    handle.write(f"{early.pid}\n")' \
  'open(os.environ["FAKE_PORT_STATE"], "w", encoding="utf-8").close()' \
  '' \
  'def stop(_signum, _frame):' \
  '    signal.signal(signal.SIGTERM, signal.SIG_IGN)' \
  '    late_pid = os.fork()' \
  '    if late_pid == 0:' \
  '        with open(os.environ["FAKE_LATE_CHILD_PGID_FILE"], "w", encoding="utf-8") as handle:' \
  '            handle.write(f"{os.getpgrp()}\n")' \
  '        deadline = time.time() + 1.0' \
  '        while os.getppid() != 1 and time.time() < deadline:' \
  '            time.sleep(0.001)' \
  '        with open(os.environ["FAKE_LATE_CHILD_PPID_FILE"], "w", encoding="utf-8") as handle:' \
  '            handle.write(f"{os.getppid()}\n")' \
  '        while True:' \
  '            time.sleep(60)' \
  '    with open(os.environ["FAKE_LATE_CHILD_PID_FILE"], "w", encoding="utf-8") as handle:' \
  '        handle.write(f"{late_pid}\n")' \
  '    try:' \
  '        os.unlink(os.environ["FAKE_PORT_STATE"])' \
  '    except FileNotFoundError:' \
  '        pass' \
  '    raise SystemExit(0)' \
  '' \
  'signal.signal(signal.SIGTERM, stop)' \
  'signal.signal(signal.SIGINT, stop)' \
  'while True:' \
  '    time.sleep(1)' \
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
  '      start) exec "$REAL_PYTHON" "$FAKE_SERVER_SOURCE" ;;' \
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

# Process inspection is also denied by this test sandbox. Model the production
# PPID and retained-PGID queries from real PIDs written by the fixtures.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'process_alive() {' \
  '  kill -0 "$1" 2>/dev/null' \
  '}' \
  'emit_if_alive() {' \
  '  process_alive "$1" || return 0' \
  '  printf "%s %s\n" "$1" "$2"' \
  '}' \
  'case " $* " in' \
  '  *" -o stat= -p "*)' \
  '    target=${!#}' \
  '    if process_alive "$target"; then printf "%s\n" S; exit 0; fi' \
  '    exit 1' \
  '    ;;' \
  '  *" -o pgid= -p "*)' \
  '    printf "%s\n" "$FAKE_EXPECTED_PGID"' \
  '    ;;' \
  '  *" -axo pid=,ppid= "*)' \
  '    root=$(sed -n "1p" "$LANE_DIR/metsuke-server.pid")' \
  '    emit_if_alive "$root" 1' \
  '    if [ -s "$FAKE_CHILD_PID_FILE" ]; then' \
  '      child=$(sed -n "1p" "$FAKE_CHILD_PID_FILE")' \
  '      emit_if_alive "$child" "$root"' \
  '    fi' \
  '    if [ -s "$FAKE_LATE_CHILD_PID_FILE" ] && ! process_alive "$root"; then' \
  '      late_child=$(sed -n "1p" "$FAKE_LATE_CHILD_PID_FILE")' \
  '      if process_alive "$late_child"; then' \
  '        : > "$FAKE_PPID_OMITTED_MARKER"' \
  '      fi' \
  '    fi' \
  '    ;;' \
  '  *" -axo pid=,pgid= "*)' \
  '    root=$(sed -n "1p" "$LANE_DIR/metsuke-server.pid")' \
  '    emit_if_alive "$root" "$FAKE_EXPECTED_PGID"' \
  '    if [ -s "$FAKE_CHILD_PID_FILE" ]; then' \
  '      child=$(sed -n "1p" "$FAKE_CHILD_PID_FILE")' \
  '      emit_if_alive "$child" "$FAKE_EXPECTED_PGID"' \
  '    fi' \
  '    if [ -s "$FAKE_PROTECTED_PID_FILE" ]; then' \
  '      protected=$(sed -n "1p" "$FAKE_PROTECTED_PID_FILE")' \
  '      emit_if_alive "$protected" "$FAKE_EXPECTED_PGID"' \
  '    fi' \
  '    if [ -s "$FAKE_LATE_CHILD_PID_FILE" ]; then' \
  '      late_child=$(sed -n "1p" "$FAKE_LATE_CHILD_PID_FILE")' \
  '      if process_alive "$late_child"; then' \
  '        printf "%s %s\n" "$late_child" "$FAKE_EXPECTED_PGID"' \
  '        if ! process_alive "$root"; then : > "$FAKE_PGID_DISCOVERED_MARKER"; fi' \
  '      fi' \
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
REAL_PYTHON="$REAL_PYTHON" \
FAKE_CHILD_PID_FILE="$TEST_TMP/child.pid" \
FAKE_LATE_CHILD_PID_FILE="$TEST_TMP/late-child.pid" \
FAKE_LATE_CHILD_PGID_FILE="$TEST_TMP/late-child.pgid" \
FAKE_LATE_CHILD_PPID_FILE="$TEST_TMP/late-child.ppid" \
FAKE_EXPECTED_PGID="$caller_pgid" \
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

/bin/sh -c 'while :; do sleep 60; done' &
PROTECTED_PID=$!
printf '%s\n' "$PROTECTED_PID" > "$TEST_TMP/protected.pid"
protected_pgid=$("$REAL_PYTHON" -c \
  'import os,sys; print(os.getpgid(int(sys.argv[1])))' "$PROTECTED_PID")
[ "$protected_pgid" = "$caller_pgid" ] ||
  fail "protected sibling did not share the caller process group"

PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
FAKE_PORT_STATE="$port_state" \
FAKE_CHILD_PID_FILE="$TEST_TMP/child.pid" \
FAKE_LATE_CHILD_PID_FILE="$TEST_TMP/late-child.pid" \
FAKE_PROTECTED_PID_FILE="$TEST_TMP/protected.pid" \
FAKE_EXPECTED_PGID="$caller_pgid" \
FAKE_PPID_OMITTED_MARKER="$TEST_TMP/late-child-omitted-from-ppid" \
FAKE_PGID_DISCOVERED_MARKER="$TEST_TMP/late-child-discovered-by-pgid" \
LANE_DIR="$lane" METSUKE_PORT="$port" \
  /bin/bash "$SERVE_SH" stop
LATE_CHILD_PID=$(sed -n '1p' "$TEST_TMP/late-child.pid")
wait_for_dead "$child_pid" ||
  fail "serve stop left a live descendant process"
wait_for_dead "$LATE_CHILD_PID" ||
  fail "serve stop left a late descendant process"
[ -e "$TEST_TMP/late-child-omitted-from-ppid" ] ||
  fail "late descendant was not omitted from the PPID-only refresh"
[ -e "$TEST_TMP/late-child-discovered-by-pgid" ] ||
  fail "late descendant was not recovered through retained-PGID discovery"
[ "$(sed -n '1p' "$TEST_TMP/late-child.ppid")" = 1 ] ||
  fail "late descendant was not reparented before PGID cleanup"
[ "$(sed -n '1p' "$TEST_TMP/late-child.pgid")" = "$caller_pgid" ] ||
  fail "late descendant did not retain the server/caller process group"
kill -0 "$PROTECTED_PID" 2>/dev/null ||
  fail "serve stop killed a protected same-PGID sibling"
SERVER_PID=
CHILD_PID=
LATE_CHILD_PID=
[ ! -e "$port_state" ] || fail "serve stop did not free the offline port seam"

: > "$port_state"
: > "$TEST_TMP/occupied-build.log"
if PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  FAKE_SERVER_SOURCE="$server_source" \
  REAL_PYTHON="$REAL_PYTHON" \
  FAKE_CHILD_PID_FILE="$TEST_TMP/occupied-child.pid" \
  FAKE_LATE_CHILD_PID_FILE="$TEST_TMP/occupied-late-child.pid" \
  FAKE_LATE_CHILD_PGID_FILE="$TEST_TMP/occupied-late-child.pgid" \
  FAKE_LATE_CHILD_PPID_FILE="$TEST_TMP/occupied-late-child.ppid" \
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
