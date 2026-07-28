#!/bin/bash
set -euo pipefail

nightshift_iso_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

nightshift_init() {
  REPO_ROOT=$1
  export REPO_ROOT

  NIGHTSHIFT_CONFIG=${NIGHTSHIFT_CONFIG:-"$REPO_ROOT/config/nightshift.conf"}
  if [ -f "$NIGHTSHIFT_CONFIG" ]; then
    # The configuration is trusted operator-controlled shell syntax.
    # shellcheck source=/dev/null
    . "$NIGHTSHIFT_CONFIG"
  fi

  NIGHTSHIFT_STATE_DIR=${NIGHTSHIFT_STATE_DIR:-"$REPO_ROOT/state"}
  STATE_DIR=$NIGHTSHIFT_STATE_DIR
  LANE_TIMEBOX_MIN=${LANE_TIMEBOX_MIN:-60}
  NIGHT_BUDGET_TOKENS=${NIGHT_BUDGET_TOKENS:-0}
  BUDGET_PROBE_CMD=${BUDGET_PROBE_CMD:-"$REPO_ROOT/bin/budget-probe-stub"}
  BUDGET_PROBE_TIMEOUT_SEC=${BUDGET_PROBE_TIMEOUT_SEC:-30}
  # HOME links are read-write through their symlinks. Lanes that need Codex
  # authentication must opt in explicitly.
  LANE_HOME_LINKS=${LANE_HOME_LINKS-}
  LANG=${LANG:-C}
  NIGHT_ID=$(date -v-8H '+%F')

  case "$LANE_TIMEBOX_MIN" in
    ''|*[!0-9]*) printf '%s\n' "LANE_TIMEBOX_MIN must be a non-negative integer" >&2; return 1 ;;
  esac
  case "$NIGHT_BUDGET_TOKENS" in
    ''|*[!0-9]*) printf '%s\n' "NIGHT_BUDGET_TOKENS must be a non-negative integer" >&2; return 1 ;;
  esac
  case "$BUDGET_PROBE_TIMEOUT_SEC" in
    ''|*[!0-9]*|0) printf '%s\n' "BUDGET_PROBE_TIMEOUT_SEC must be a positive integer" >&2; return 1 ;;
  esac

  if ! declare -p LANE_CMD_1 >/dev/null 2>&1; then
    LANE_CMD_1=':'
  fi

  export STATE_DIR NIGHT_ID LANE_TIMEBOX_MIN NIGHT_BUDGET_TOKENS
  export BUDGET_PROBE_CMD BUDGET_PROBE_TIMEOUT_SEC LANE_HOME_LINKS LANG
}

nightshift_prepare_state() {
  mkdir -p \
    "$STATE_DIR/logs" \
    "$STATE_DIR/locks" \
    "$STATE_DIR/ledger" \
    "$STATE_DIR/lanes" \
    "$STATE_DIR/digests"
}

nightshift_start_logging() {
  subcommand=$1
  NIGHTSHIFT_LOG_FILE="$STATE_DIR/logs/${subcommand}-${NIGHT_ID}.log"
  NIGHTSHIFT_LOG_FIFO="$STATE_DIR/logs/.${subcommand}-${NIGHT_ID}.$$.fifo"
  mkfifo "$NIGHTSHIFT_LOG_FIFO"
  tee -a "$NIGHTSHIFT_LOG_FILE" < "$NIGHTSHIFT_LOG_FIFO" &
  NIGHTSHIFT_TEE_PID=$!
  exec 3>&1 4>&2
  exec > "$NIGHTSHIFT_LOG_FIFO" 2>&1
  rm -f "$NIGHTSHIFT_LOG_FIFO"
  export NIGHTSHIFT_LOG_FILE NIGHTSHIFT_TEE_PID
}

nightshift_finish_logging() {
  command_status=$1
  exec 1>&3 2>&4
  exec 3>&- 4>&-

  if wait "$NIGHTSHIFT_TEE_PID"; then
    tee_status=0
  else
    tee_status=$?
  fi
  if [ "$command_status" -eq 0 ] && [ "$tee_status" -ne 0 ]; then
    return "$tee_status"
  fi
  return "$command_status"
}

nightshift_log() {
  level=$1
  shift
  printf '%s [%s] %s\n' "$(nightshift_iso_now)" "$level" "$*"
}
