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
  NIGHT_ID=$(date -v-8H '+%F' 2>/dev/null || date -d '-8 hours' '+%F')

  case "$LANE_TIMEBOX_MIN" in
    ''|*[!0-9]*) printf '%s\n' "LANE_TIMEBOX_MIN must be a non-negative integer" >&2; return 1 ;;
  esac
  if [ "${#LANE_TIMEBOX_MIN}" -gt 7 ]; then
    printf '%s\n' "LANE_TIMEBOX_MIN is too large" >&2
    return 1
  fi
  case "$NIGHT_BUDGET_TOKENS" in
    ''|*[!0-9]*) printf '%s\n' "NIGHT_BUDGET_TOKENS must be a non-negative integer" >&2; return 1 ;;
  esac
  if [ "${#NIGHT_BUDGET_TOKENS}" -gt 15 ]; then
    printf '%s\n' "NIGHT_BUDGET_TOKENS must not exceed 15 digits" >&2
    return 1
  fi
  case "$BUDGET_PROBE_TIMEOUT_SEC" in
    ''|*[!0-9]*|0) printf '%s\n' "BUDGET_PROBE_TIMEOUT_SEC must be a positive integer" >&2; return 1 ;;
  esac
  if [ "${#BUDGET_PROBE_TIMEOUT_SEC}" -gt 7 ]; then
    printf '%s\n' "BUDGET_PROBE_TIMEOUT_SEC is too large" >&2
    return 1
  fi

  if ! declare -p LANE_CMD_1 >/dev/null 2>&1; then
    LANE_CMD_1=':'
  fi

  export STATE_DIR NIGHT_ID LANE_TIMEBOX_MIN NIGHT_BUDGET_TOKENS
  export BUDGET_PROBE_CMD BUDGET_PROBE_TIMEOUT_SEC LANE_HOME_LINKS LANG
}

nightshift_prepare_state() {
  if ! mkdir -p \
    "$STATE_DIR/logs" \
    "$STATE_DIR/locks" \
    "$STATE_DIR/ledger" \
    "$STATE_DIR/lanes" \
    "$STATE_DIR/digests"; then
    printf '%s\n' "Failed to prepare nightshift state: $STATE_DIR" >&2
    return 1
  fi
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

nightshift_pid_alive() {
  nightshift_alive_pid=$1
  if ! kill -0 "$nightshift_alive_pid" 2>/dev/null; then
    return 1
  fi
  if nightshift_alive_stat=$(ps -p "$nightshift_alive_pid" -o stat= 2>/dev/null); then
    :
  else
    nightshift_alive_rc=$?
    nightshift_alive_stat=
    if [ "$nightshift_alive_rc" -gt 1 ]; then
      NIGHTSHIFT_PROCESS_INSPECTION_FAILED=true
    fi
  fi
  case "$nightshift_alive_stat" in
    *Z*) return 1 ;;
  esac
  return 0
}

nightshift_refresh_process_tree() {
  nightshift_tree_root=$1
  nightshift_tree_known=${2:-}
  NIGHTSHIFT_PROCESS_PIDS=

  for nightshift_tree_pid in $nightshift_tree_known; do
    case "$nightshift_tree_pid" in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$nightshift_tree_pid" = "$nightshift_tree_root" ] && continue
    case " $NIGHTSHIFT_PROCESS_PIDS " in
      *" $nightshift_tree_pid "*) ;;
      *) NIGHTSHIFT_PROCESS_PIDS="$NIGHTSHIFT_PROCESS_PIDS $nightshift_tree_pid" ;;
    esac
  done

  if nightshift_group_members=$(ps -g "$nightshift_tree_root" -o pid= 2>/dev/null); then
    :
  else
    nightshift_group_rc=$?
    nightshift_group_members=
    if [ "$nightshift_group_rc" -gt 1 ]; then
      NIGHTSHIFT_PROCESS_INSPECTION_FAILED=true
    fi
  fi
  for nightshift_tree_pid in $nightshift_group_members; do
    case "$nightshift_tree_pid" in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$nightshift_tree_pid" = "$nightshift_tree_root" ] && continue
    case " $NIGHTSHIFT_PROCESS_PIDS " in
      *" $nightshift_tree_pid "*) ;;
      *) NIGHTSHIFT_PROCESS_PIDS="$NIGHTSHIFT_PROCESS_PIDS $nightshift_tree_pid" ;;
    esac
  done

  nightshift_tree_frontier="$nightshift_tree_root $NIGHTSHIFT_PROCESS_PIDS"
  while [ -n "$(printf '%s' "$nightshift_tree_frontier" | tr -d '[:space:]')" ]; do
    nightshift_tree_next=
    for nightshift_tree_parent in $nightshift_tree_frontier; do
      case "$nightshift_tree_parent" in
        ''|*[!0-9]*) continue ;;
      esac
      if nightshift_tree_children=$(pgrep -P "$nightshift_tree_parent" 2>/dev/null); then
        :
      else
        nightshift_children_rc=$?
        nightshift_tree_children=
        if [ "$nightshift_children_rc" -gt 1 ]; then
          NIGHTSHIFT_PROCESS_INSPECTION_FAILED=true
        fi
      fi
      for nightshift_tree_pid in $nightshift_tree_children; do
        case "$nightshift_tree_pid" in
          ''|*[!0-9]*) continue ;;
        esac
        [ "$nightshift_tree_pid" = "$nightshift_tree_root" ] && continue
        case " $NIGHTSHIFT_PROCESS_PIDS " in
          *" $nightshift_tree_pid "*) ;;
          *)
            NIGHTSHIFT_PROCESS_PIDS="$NIGHTSHIFT_PROCESS_PIDS $nightshift_tree_pid"
            nightshift_tree_next="$nightshift_tree_next $nightshift_tree_pid"
            ;;
        esac
      done
    done
    nightshift_tree_frontier=$nightshift_tree_next
  done
}

nightshift_process_tree_alive() {
  nightshift_check_root=$1
  nightshift_check_known=${2:-}
  nightshift_refresh_process_tree "$nightshift_check_root" "$nightshift_check_known"
  NIGHTSHIFT_PROCESS_KNOWN=$NIGHTSHIFT_PROCESS_PIDS
  if nightshift_pid_alive "$nightshift_check_root"; then
    return 0
  fi
  for nightshift_check_pid in $NIGHTSHIFT_PROCESS_PIDS; do
    if nightshift_pid_alive "$nightshift_check_pid"; then
      return 0
    fi
  done
  return 1
}

nightshift_stop_process_tree() {
  nightshift_stop_root=$1
  nightshift_stop_known=${2:-}
  nightshift_refresh_process_tree "$nightshift_stop_root" "$nightshift_stop_known"
  nightshift_stop_known=$NIGHTSHIFT_PROCESS_PIDS

  for nightshift_stop_pid in $nightshift_stop_known; do
    kill -TERM "$nightshift_stop_pid" 2>/dev/null || true
  done
  # Give the group leader a chance to reap its children before terminating it;
  # killing the leader first can leave short-lived orphan zombies that look
  # like live escapees to kill -0 checks.
  sleep 0.1
  kill -TERM -- "-$nightshift_stop_root" 2>/dev/null || true

  nightshift_stop_started=$(date '+%s')
  while nightshift_process_tree_alive "$nightshift_stop_root" "$nightshift_stop_known"; do
    nightshift_stop_known=$NIGHTSHIFT_PROCESS_KNOWN
    nightshift_stop_now=$(date '+%s')
    if [ $((nightshift_stop_now - nightshift_stop_started)) -ge 10 ]; then
      for nightshift_stop_pid in $nightshift_stop_known; do
        kill -KILL "$nightshift_stop_pid" 2>/dev/null || true
      done
      sleep 0.1
      kill -KILL -- "-$nightshift_stop_root" 2>/dev/null || true
      break
    fi
    sleep 0.1
  done

  sleep 0.1
  nightshift_refresh_process_tree "$nightshift_stop_root" "$nightshift_stop_known"
  nightshift_stop_known=$NIGHTSHIFT_PROCESS_PIDS
  NIGHTSHIFT_PROCESS_SURVIVORS=
  for nightshift_stop_pid in "$nightshift_stop_root" $nightshift_stop_known; do
    if nightshift_pid_alive "$nightshift_stop_pid"; then
      NIGHTSHIFT_PROCESS_SURVIVORS="$NIGHTSHIFT_PROCESS_SURVIVORS $nightshift_stop_pid"
    fi
  done
  NIGHTSHIFT_PROCESS_KNOWN=$nightshift_stop_known
}
