#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
# shellcheck source=../../lib/common.sh disable=SC1091
. "$REPO_ROOT/lib/common.sh"
# shellcheck source=../../lib/lock.sh disable=SC1091
. "$REPO_ROOT/lib/lock.sh"

log() {
  printf '%s\n' "org-consistency: $*" >&2
}

OC_STATE_DIR=${OC_STATE_DIR:?OC_STATE_DIR is required}
LANE_DIR=${LANE_DIR:?LANE_DIR is required}
NIGHT_ID=${NIGHT_ID:?NIGHT_ID is required}

if [ "${OC_TEST_MODE:-}" != 1 ]; then
  test_hook_name=$(
    /usr/bin/env |
      /usr/bin/sed -En '/^OC_TEST_MODE=/d; s/^(OC_TEST_[^=]*|OC_API_FIXTURE)=.*/\1/p' |
      /usr/bin/head -n 1
  )
  if [ -n "$test_hook_name" ]; then
    log "$test_hook_name requires OC_TEST_MODE=1"
    exit 2
  fi
fi

case "$OC_STATE_DIR" in
  /*) ;;
  *) log 'OC_STATE_DIR must be absolute'; exit 2 ;;
esac
case "$LANE_DIR" in
  /*) ;;
  *) log 'LANE_DIR must be absolute'; exit 2 ;;
esac

if [ -L "$OC_STATE_DIR" ] || { [ -e "$OC_STATE_DIR" ] && [ ! -d "$OC_STATE_DIR" ]; }; then
  log 'OC_STATE_DIR must be a non-symlink directory'
  exit 2
fi
if [ ! -d "$LANE_DIR" ] || [ -L "$LANE_DIR" ]; then
  log 'LANE_DIR must be an existing non-symlink directory'
  exit 2
fi

mkdir -p "$OC_STATE_DIR"
state_canonical=$(cd -P "$OC_STATE_DIR" && pwd -P)
lane_canonical=$(cd -P "$LANE_DIR" && pwd -P)
OC_STATE_DIR=$state_canonical
LANE_DIR=$lane_canonical
export OC_STATE_DIR LANE_DIR

lock_dir="$OC_STATE_DIR/.lock"
lock_rc=0
lock_acquire "$lock_dir" || lock_rc=$?
if [ "$lock_rc" -ne 0 ]; then
  log "state lock unavailable (rc=$lock_rc)"
  exit 2
fi
child_pid=
# SC2329/SC2317 are one false positive (trap-only functions): older checker
# builds on the ubuntu runner emit SC2317 where newer ones emit SC2329.
# shellcheck disable=SC2329,SC2317
cleanup() {
  lock_release "$lock_dir" || true
}
# shellcheck disable=SC2329,SC2317
forward_signal() {
  signal_name=$1
  signal_exit=$2
  trap - HUP INT TERM
  if [ -n "$child_pid" ]; then
    kill -"$signal_name" "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  fi
  exit "$signal_exit"
}
trap cleanup EXIT
trap 'forward_signal HUP 129' HUP
trap 'forward_signal INT 130' INT
trap 'forward_signal TERM 143' TERM

/usr/bin/python3 -B "$SCRIPT_DIR/core.py" run &
child_pid=$!
child_rc=0
wait "$child_pid" || child_rc=$?
child_pid=
exit "$child_rc"
