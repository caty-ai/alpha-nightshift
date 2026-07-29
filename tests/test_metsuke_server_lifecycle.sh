#!/bin/bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
# shellcheck source=tests/helpers.sh
. "$TEST_DIR/helpers.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-metsuke-server.XXXXXX")
NATIVE_PS=false
if /bin/ps -axo pid=,ppid= >/dev/null 2>&1; then
  NATIVE_PS=true
fi
TRACKED_PIDS=
cleanup() {
  local tracked_pid
  while IFS= read -r tracked_pid; do
    case "$tracked_pid" in
      ''|*[!0-9]*) continue ;;
    esac
    kill -KILL "$tracked_pid" 2>/dev/null || true
  done <<EOF
$TRACKED_PIDS
EOF
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

track_pid() {
  TRACKED_PIDS="${TRACKED_PIDS}${TRACKED_PIDS:+
}$1"
}

wait_for_file() {
  local target=$1
  local wait_ticks=0
  while [ ! -s "$target" ] && [ "$wait_ticks" -lt 250 ]; do
    sleep 0.02
    wait_ticks=$((wait_ticks + 1))
  done
  [ -s "$target" ]
}

wait_for_dead() {
  local process_pid=$1
  local wait_ticks=0
  while [ "$wait_ticks" -lt 250 ]; do
    kill -0 "$process_pid" 2>/dev/null || return 0
    sleep 0.02
    wait_ticks=$((wait_ticks + 1))
  done
  return 1
}

wait_for_pid_absent() {
  local process_pid=$1
  local process_pids
  local wait_ticks=0
  if [ "$NATIVE_PS" != true ]; then
    wait_for_dead "$process_pid"
    return
  fi
  while [ "$wait_ticks" -lt 250 ]; do
    if process_pids=$(/bin/ps -axo pid= 2>/dev/null); then
      if ! printf '%s\n' "$process_pids" |
        awk -v wanted="$process_pid" '$1 == wanted {found = 1} END {exit !found}'; then
        return 0
      fi
    fi
    sleep 0.02
    wait_ticks=$((wait_ticks + 1))
  done
  return 1
}

wait_for_ppid_one() {
  local process_pid=$1
  local wait_ticks=0
  local process_ppid
  while [ "$wait_ticks" -lt 250 ]; do
    process_ppid=$(ps -o ppid= -p "$process_pid" 2>/dev/null |
      awk 'NR == 1 {print $1}') || true
    [ "$process_ppid" = 1 ] && return 0
    sleep 0.02
    wait_ticks=$((wait_ticks + 1))
  done
  return 1
}

process_identity() {
  local process_pid=$1
  local process_started="Mon Jan 1 00:00:00 2024"
  if [ "$NATIVE_PS" = true ]; then
    process_started=$(/bin/ps -o lstart= -p "$process_pid" |
      awk '{$1=$1; print}')
  fi
  printf '%s\n' "$process_pid $process_started" |
    shasum -a 256 | awk '{print $1}'
}

SERVE_SH="$ROOT/lanes/metsuke/serve-lp.sh"
REAL_PYTHON=$(command -v python3)
fake_bin="$TEST_TMP/bin"
checkout="$TEST_TMP/checkout"
mkdir -p "$fake_bin" "$checkout/node_modules"

server_source="$TEST_TMP/fake-server.py"
cat > "$server_source" <<'PY'
#!/usr/bin/env python3
import os
import signal
import subprocess
import time

mode = os.environ["FAKE_SERVER_MODE"]
listener_file = os.environ["FAKE_LISTENER_PID_FILE"]

if mode == "root-dead":
    worker = os.fork()
    if worker == 0:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        while os.getppid() != 1:
            time.sleep(0.001)
        with open(os.environ["FAKE_WORKER_PPID_FILE"], "w", encoding="utf-8") as handle:
            handle.write(f"{os.getppid()}\n")
        while True:
            time.sleep(60)
    with open(os.environ["FAKE_WORKER_PID_FILE"], "w", encoding="utf-8") as handle:
        handle.write(f"{worker}\n")
    with open(listener_file, "w", encoding="utf-8") as handle:
        handle.write(f"{worker}\n")
    while not os.path.exists(os.environ["FAKE_ROOT_EXIT_TRIGGER"]):
        time.sleep(0.01)
    raise SystemExit(0)

early = subprocess.Popen(["/bin/sh", "-c", "trap '' TERM; while :; do sleep 60; done"])
with open(os.environ["FAKE_EARLY_PID_FILE"], "w", encoding="utf-8") as handle:
    handle.write(f"{early.pid}\n")
with open(listener_file, "w", encoding="utf-8") as handle:
    handle.write(f"{os.getpid()}\n")

def stop(_signum, _frame):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    late_pid = os.fork()
    if late_pid == 0:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        deadline = time.time() + 2.0
        while os.getppid() != 1 and time.time() < deadline:
            time.sleep(0.001)
        with open(os.environ["FAKE_LATE_PPID_FILE"], "w", encoding="utf-8") as handle:
            handle.write(f"{os.getppid()}\n")
        with open(os.environ["FAKE_LATE_PGID_FILE"], "w", encoding="utf-8") as handle:
            handle.write(f"{os.getpgrp()}\n")
        while True:
            time.sleep(60)
    with open(os.environ["FAKE_LATE_PID_FILE"], "w", encoding="utf-8") as handle:
        handle.write(f"{late_pid}\n")
    with open(listener_file, "w", encoding="utf-8") as handle:
        handle.write(f"{late_pid}\n")
    raise SystemExit(0)

signal.signal(signal.SIGTERM, stop)
while True:
    time.sleep(60)
PY
chmod +x "$server_source"

# shellcheck disable=SC2016
cat > "$fake_bin/npm" <<'EOF'
#!/bin/bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "run build") exit 0 ;;
  "run start") exec "$REAL_PYTHON" "$FAKE_SERVER_SOURCE" ;;
esac
exit 2
EOF

# shellcheck disable=SC2016
cat > "$fake_bin/listener-active" <<'EOF'
#!/bin/bash
[ -s "$FAKE_LISTENER_PID_FILE" ] || exit 1
listener_pid=$(sed -n '1p' "$FAKE_LISTENER_PID_FILE")
kill -0 "$listener_pid" 2>/dev/null || exit 1

# Native ps distinguishes a KILLed zombie from a live listener. Restricted
# sandboxes can deny ps entirely, so retain the kill -0 seam in that case.
if /bin/ps -o stat= -p "$$" >/dev/null 2>&1; then
  listener_stat=$(/bin/ps -o stat= -p "$listener_pid" 2>/dev/null) || exit 1
  case "$listener_stat" in
    *Z*) exit 1 ;;
  esac
fi
EOF

# shellcheck disable=SC2016
cat > "$fake_bin/lsof" <<'EOF'
#!/bin/bash
listener-active
EOF

# shellcheck disable=SC2016
cat > "$fake_bin/curl" <<'EOF'
#!/bin/bash
if listener-active; then
  case " $* " in *" -w "*) printf 200 ;; esac
  exit 0
fi
exit 7
EOF

# A restricted workspace may deny native ps(1). This fallback exposes the real
# fixture PIDs through the exact BSD query shapes used by serve-lp.sh.
# shellcheck disable=SC2016
cat > "$fake_bin/ps" <<'EOF'
#!/bin/bash
set -euo pipefail
alive() {
  kill -0 "$1" 2>/dev/null
}
emit() {
  local process_pid=$1
  local related_value=$2
  alive "$process_pid" || return 0
  printf "%s %s\n" "$process_pid" "$related_value"
}
root_pid=
[ -s "$LANE_DIR/metsuke-server.pid" ] &&
  root_pid=$(sed -n "1p" "$LANE_DIR/metsuke-server.pid")
case " $* " in
  *" -o lstart= -p "*)
    target=${!#}
    alive "$target" || exit 1
    printf "%s\n" "Mon Jan  1 00:00:00 2024"
    ;;
  *" -o stat= -p "*)
    target=${!#}
    alive "$target" || exit 1
    printf "%s\n" S
    ;;
  *" -o pgid= -p "*)
    target=${!#}
    alive "$target" || exit 1
    printf "%s\n" "$FAKE_EXPECTED_PGID"
    ;;
  *" -axo pid=,ppid= "*)
    emit "$FAKE_CALLER_PID" 1
    emit "$PPID" "$FAKE_CALLER_PID"
    if [ -n "$root_pid" ]; then emit "$root_pid" 1; fi
    if [ -s "${FAKE_WORKER_PID_FILE:-}" ]; then
      worker=$(sed -n "1p" "$FAKE_WORKER_PID_FILE")
      if [ -n "$root_pid" ] && alive "$root_pid"; then
        emit "$worker" "$root_pid"
      else
        emit "$worker" 1
      fi
    fi
    if [ -s "${FAKE_EARLY_PID_FILE:-}" ]; then
      early=$(sed -n "1p" "$FAKE_EARLY_PID_FILE")
      if [ -n "$root_pid" ] && alive "$root_pid"; then
        emit "$early" "$root_pid"
      else
        emit "$early" 1
      fi
    fi
    if [ -s "${FAKE_LATE_PID_FILE:-}" ]; then
      late=$(sed -n "1p" "$FAKE_LATE_PID_FILE")
      emit "$late" 1
    fi
    if [ -n "${FAKE_PROTECTED_PID:-}" ]; then
      emit "$FAKE_PROTECTED_PID" "$FAKE_CALLER_PID"
    fi
    ;;
  *" -axo pid=,pgid= "*)
    emit "$FAKE_CALLER_PID" "$FAKE_EXPECTED_PGID"
    emit "$PPID" "$FAKE_EXPECTED_PGID"
    if [ -n "$root_pid" ]; then emit "$root_pid" "$FAKE_EXPECTED_PGID"; fi
    for pid_file in \
      "${FAKE_WORKER_PID_FILE:-}" \
      "${FAKE_EARLY_PID_FILE:-}" \
      "${FAKE_LATE_PID_FILE:-}"; do
      if [ -s "$pid_file" ]; then
        emit "$(sed -n "1p" "$pid_file")" "$FAKE_EXPECTED_PGID"
      fi
    done
    if [ -n "${FAKE_PROTECTED_PID:-}" ]; then
      emit "$FAKE_PROTECTED_PID" "$FAKE_EXPECTED_PGID"
    fi
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x \
  "$fake_bin/npm" \
  "$fake_bin/listener-active" \
  "$fake_bin/lsof" \
  "$fake_bin/curl" \
  "$fake_bin/ps"
if [ "$NATIVE_PS" = true ]; then
  rm -f "$fake_bin/ps"
fi

run_serve() {
  local action=$1
  local lane=$2
  local port=$3
  shift 3
  PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    REAL_PYTHON="$REAL_PYTHON" \
    FAKE_SERVER_SOURCE="$server_source" \
    FAKE_CALLER_PID="$$" \
    FAKE_EXPECTED_PGID="$caller_pgid" \
    METSUKE_LP_CHECKOUT="$checkout" \
    LANE_DIR="$lane" \
    METSUKE_PORT="$port" \
    "$@" \
    /bin/bash "$SERVE_SH" "$action"
}

caller_pgid=$("$REAL_PYTHON" -c 'import os; print(os.getpgrp())')

# Root-dead-before-stop: a retained-PGID orphan must remain distinguishable
# from a caller-side sibling created after launch.
root_dead_lane="$TEST_TMP/root-dead-lane"
mkdir -p "$root_dead_lane"
root_dead_worker_file="$TEST_TMP/root-dead-worker.pid"
root_dead_worker_ppid_file="$TEST_TMP/root-dead-worker.ppid"
root_dead_listener_file="$TEST_TMP/root-dead-listener.pid"
root_dead_trigger="$TEST_TMP/root-dead-trigger"
run_serve start "$root_dead_lane" 43123 \
  env FAKE_SERVER_MODE=root-dead \
  FAKE_WORKER_PID_FILE="$root_dead_worker_file" \
  FAKE_WORKER_PPID_FILE="$root_dead_worker_ppid_file" \
  FAKE_LISTENER_PID_FILE="$root_dead_listener_file" \
  FAKE_ROOT_EXIT_TRIGGER="$root_dead_trigger"
root_dead_pid=$(sed -n '1p' "$root_dead_lane/metsuke-server.pid")
root_dead_worker=$(sed -n '1p' "$root_dead_worker_file")
track_pid "$root_dead_pid"
track_pid "$root_dead_worker"
root_dead_pgid=$("$REAL_PYTHON" -c \
  'import os,sys; print(os.getpgid(int(sys.argv[1])))' "$root_dead_worker")
[ "$root_dead_pgid" = "$caller_pgid" ] ||
  fail "root-dead worker did not retain the caller/server PGID"

/bin/sh -c 'while :; do sleep 60; done' &
protected_pid=$!
track_pid "$protected_pid"
protected_pgid=$("$REAL_PYTHON" -c \
  'import os,sys; print(os.getpgid(int(sys.argv[1])))' "$protected_pid")
[ "$protected_pgid" = "$caller_pgid" ] ||
  fail "protected caller-side sibling did not share the server PGID"

: > "$root_dead_trigger"
wait_for_pid_absent "$root_dead_pid" ||
  fail "recorded server root was still present before stop"
wait_for_file "$root_dead_worker_ppid_file" ||
  fail "server orphan did not reach PPID 1 before stop"
run_serve stop "$root_dead_lane" 43123 \
  env FAKE_LISTENER_PID_FILE="$root_dead_listener_file" \
  FAKE_WORKER_PID_FILE="$root_dead_worker_file" \
  FAKE_PROTECTED_PID="$protected_pid"
wait_for_dead "$root_dead_worker" ||
  fail "stop left the root-dead retained-PGID orphan alive"
kill -0 "$protected_pid" 2>/dev/null ||
  fail "stop killed a legitimate caller-side same-PGID sibling"
[ ! -e "$root_dead_lane/metsuke-server.baseline" ] ||
  fail "successful stop retained the pre-launch baseline"
[ ! -e "$root_dead_lane/metsuke-server.identity" ] ||
  fail "successful stop retained the server identity state"

# Existing TERM-time descendant case remains covered: the root exits
# immediately after forking an orphan that retains the server PGID.
term_lane="$TEST_TMP/term-descendant-lane"
mkdir -p "$term_lane"
term_early_file="$TEST_TMP/term-early.pid"
term_late_file="$TEST_TMP/term-late.pid"
term_late_ppid_file="$TEST_TMP/term-late.ppid"
term_late_pgid_file="$TEST_TMP/term-late.pgid"
term_listener_file="$TEST_TMP/term-listener.pid"
run_serve start "$term_lane" 43124 \
  env FAKE_SERVER_MODE=term-descendant \
  FAKE_EARLY_PID_FILE="$term_early_file" \
  FAKE_LATE_PID_FILE="$term_late_file" \
  FAKE_LATE_PPID_FILE="$term_late_ppid_file" \
  FAKE_LATE_PGID_FILE="$term_late_pgid_file" \
  FAKE_LISTENER_PID_FILE="$term_listener_file"
term_root=$(sed -n '1p' "$term_lane/metsuke-server.pid")
term_early=$(sed -n '1p' "$term_early_file")
track_pid "$term_root"
track_pid "$term_early"
run_serve stop "$term_lane" 43124 \
  env FAKE_EARLY_PID_FILE="$term_early_file" \
  FAKE_LATE_PID_FILE="$term_late_file" \
  FAKE_LATE_PPID_FILE="$term_late_ppid_file" \
  FAKE_LATE_PGID_FILE="$term_late_pgid_file" \
  FAKE_LISTENER_PID_FILE="$term_listener_file"
wait_for_file "$term_late_file" ||
  fail "TERM handler did not create the late descendant"
term_late=$(sed -n '1p' "$term_late_file")
track_pid "$term_late"
wait_for_dead "$term_early" ||
  fail "stop left the early server descendant alive"
wait_for_dead "$term_late" ||
  fail "stop left the TERM-time retained-PGID descendant alive"
[ "$(sed -n '1p' "$term_late_ppid_file")" = 1 ] ||
  fail "TERM-time descendant was not reparented to PID 1"
[ "$(sed -n '1p' "$term_late_pgid_file")" = "$caller_pgid" ] ||
  fail "TERM-time descendant did not retain the server PGID"

# Stale PID identity must fail closed before any innocent tree member is
# signaled, even when the recorded PGID still names the caller's live group.
stale_lane="$TEST_TMP/stale-lane"
mkdir -p "$stale_lane"
stale_child_file="$TEST_TMP/stale-child.pid"
"$REAL_PYTHON" - "$stale_child_file" <<'PY' &
import subprocess
import sys
import time

child = subprocess.Popen(["/bin/sh", "-c", "while :; do sleep 60; done"])
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(f"{child.pid}\n")
while True:
    time.sleep(60)
PY
stale_root=$!
track_pid "$stale_root"
wait_for_file "$stale_child_file" || fail "innocent stale-state tree did not start"
stale_child=$(sed -n '1p' "$stale_child_file")
track_pid "$stale_child"
stale_pgid=$("$REAL_PYTHON" -c \
  'import os,sys; print(os.getpgid(int(sys.argv[1])))' "$stale_root")
printf '%s\n' "$stale_root" > "$stale_lane/metsuke-server.pid"
printf '%s\n' "$stale_pgid" > "$stale_lane/metsuke-server.pgid"
printf '%s\n' 43125 > "$stale_lane/metsuke-server.port"
printf '%064d\n' 0 > "$stale_lane/metsuke-server.identity"
printf '%s %s\n' "$$" "$(process_identity "$$")" \
  > "$stale_lane/metsuke-server.baseline"
set +e
run_serve stop "$stale_lane" 43125 \
  env FAKE_LISTENER_PID_FILE="$TEST_TMP/no-listener" \
  >"$TEST_TMP/stale-stdout" 2>"$TEST_TMP/stale-stderr"
stale_rc=$?
set -e
[ "$stale_rc" -ne 0 ] ||
  fail "stale reused-PID state was accepted"
assert_contains "has been reused" "$TEST_TMP/stale-stderr"
kill -0 "$stale_root" 2>/dev/null ||
  fail "stale-state refusal killed the innocent recorded PID"
kill -0 "$stale_child" 2>/dev/null ||
  fail "stale-state refusal killed the innocent process tree"

# Missing lifecycle baseline also fails closed without widening the target set.
printf '%s\n' "$(process_identity "$stale_root")" \
  > "$stale_lane/metsuke-server.identity"
rm -f "$stale_lane/metsuke-server.baseline"
set +e
run_serve stop "$stale_lane" 43125 \
  env FAKE_LISTENER_PID_FILE="$TEST_TMP/no-listener" \
  >"$TEST_TMP/missing-stdout" 2>"$TEST_TMP/missing-stderr"
missing_rc=$?
set -e
[ "$missing_rc" -ne 0 ] ||
  fail "missing pre-launch baseline was accepted"
assert_contains "pre-launch process baseline" "$TEST_TMP/missing-stderr"
kill -0 "$stale_root" 2>/dev/null ||
  fail "missing-baseline refusal signaled the innocent root"
kill -0 "$stale_child" 2>/dev/null ||
  fail "missing-baseline refusal signaled the innocent child"

: > "$TEST_TMP/occupied-listener.pid"
printf '%s\n' "$$" > "$TEST_TMP/occupied-listener.pid"
occupied_lane="$TEST_TMP/occupied-lane"
mkdir -p "$occupied_lane"
set +e
run_serve start "$occupied_lane" 43126 \
  env FAKE_SERVER_MODE=root-dead \
  FAKE_WORKER_PID_FILE="$TEST_TMP/occupied-worker.pid" \
  FAKE_WORKER_PPID_FILE="$TEST_TMP/occupied-worker.ppid" \
  FAKE_LISTENER_PID_FILE="$TEST_TMP/occupied-listener.pid" \
  FAKE_ROOT_EXIT_TRIGGER="$TEST_TMP/occupied-trigger" \
  >"$TEST_TMP/occupied-stdout" 2>"$TEST_TMP/occupied-stderr"
occupied_rc=$?
set -e
[ "$occupied_rc" -ne 0 ] ||
  fail "serve start accepted an already occupied port"
assert_contains "already occupied" "$TEST_TMP/occupied-stderr"
[ ! -e "$occupied_lane/metsuke-server.baseline" ] ||
  fail "occupied-port refusal recorded a premature lifecycle baseline"

printf 'test_metsuke_server_lifecycle: PASS\n'
