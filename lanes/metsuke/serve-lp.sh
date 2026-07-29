#!/bin/bash
set -euo pipefail

LANE_DIR=${LANE_DIR:?LANE_DIR is required}
METSUKE_PORT=${METSUKE_PORT:-4173}
PID_FILE="$LANE_DIR/metsuke-server.pid"
PGID_FILE="$LANE_DIR/metsuke-server.pgid"
PORT_FILE="$LANE_DIR/metsuke-server.port"
SERVER_LOG="$LANE_DIR/metsuke-server.log"

log() {
  printf '%s\n' "metsuke serve: $*" >&2
}

validate_port() {
  case "$METSUKE_PORT" in
    ''|*[!0-9]*|0)
      log "METSUKE_PORT must be a positive integer"
      return 1
      ;;
  esac
  [ "$METSUKE_PORT" -le 65535 ] || {
    log "METSUKE_PORT must not exceed 65535"
    return 1
  }
}

server_is_alive() {
  local server_pid=$1
  local process_state
  kill -0 "$server_pid" 2>/dev/null || return 1
  process_state=$(ps -o stat= -p "$server_pid" 2>/dev/null | tr -d ' ') || return 1
  case "$process_state" in
    ''|Z*) return 1 ;;
  esac
  return 0
}

candidate_is_active() {
  local process_pid=$1
  local process_state
  kill -0 "$process_pid" 2>/dev/null || return 1
  if ! process_state=$(ps -o stat= -p "$process_pid" 2>/dev/null |
    tr -d ' '); then
    return 2
  fi
  case "$process_state" in
    ''|Z*) return 1 ;;
  esac
  return 0
}

process_group_for_pid() {
  local process_pid=$1
  local process_group
  process_group=$(ps -o pgid= -p "$process_pid" 2>/dev/null |
    awk 'NR == 1 {print $1}') || return 1
  case "$process_group" in
    ''|*[!0-9]*|0) return 1 ;;
  esac
  printf '%s\n' "$process_group"
}

port_is_occupied() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$METSUKE_PORT" -sTCP:LISTEN >/dev/null 2>&1
    return
  fi
  if command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$METSUKE_PORT" >/dev/null 2>&1
    return
  fi
  curl --max-time 1 -s -o /dev/null "http://127.0.0.1:$METSUKE_PORT"
}

collect_pid_tree() {
  local root_pid=$1
  local process_snapshot="$LANE_DIR/.metsuke-processes.$$.txt"
  if ! ps -axo pid=,ppid= > "$process_snapshot"; then
    rm -f "$process_snapshot"
    return 1
  fi
  if ! awk -v root="$root_pid" '
    {
      pid[NR] = $1
      parent[NR] = $2
    }
    END {
      selected[root] = 1
      changed = 1
      while (changed) {
        changed = 0
        for (row = 1; row <= NR; row += 1) {
          if (selected[parent[row]] && !selected[pid[row]]) {
            selected[pid[row]] = 1
            changed = 1
          }
        }
      }
      for (row = 1; row <= NR; row += 1) {
        if (selected[pid[row]]) {
          print pid[row]
        }
      }
    }
  ' "$process_snapshot"; then
    rm -f "$process_snapshot"
    return 1
  fi
  rm -f "$process_snapshot"
}

collect_pgid_members() {
  local process_group=$1
  local process_snapshot="$LANE_DIR/.metsuke-process-groups.$$.txt"
  if ! ps -axo pid=,pgid= > "$process_snapshot"; then
    rm -f "$process_snapshot"
    return 1
  fi
  if ! awk -v process_group="$process_group" '
    $2 == process_group {
      print $1
    }
  ' "$process_snapshot"; then
    rm -f "$process_snapshot"
    return 1
  fi
  rm -f "$process_snapshot"
}

merge_pid_lists() {
  printf '%s\n%s\n' "$1" "$2" |
    awk '/^[0-9]+$/ && !seen[$1]++ {print $1}'
}

pid_list_contains() {
  local wanted_pid=$1
  local pid_list=$2
  printf '%s\n' "$pid_list" | grep -F -x "$wanted_pid" >/dev/null 2>&1
}

pid_list_without() {
  local pid_list=$1
  local excluded_pids=$2
  local process_pid
  while IFS= read -r process_pid; do
    case "$process_pid" in
      ''|*[!0-9]*) continue ;;
    esac
    if ! pid_list_contains "$process_pid" "$excluded_pids"; then
      printf '%s\n' "$process_pid"
    fi
  done <<EOF
$pid_list
EOF
}

collect_server_candidates() {
  local server_pid=$1
  local server_pgid=$2
  local protected_baseline=$3
  local descendant_tree
  local cleanup_tree
  local group_members
  local merged_candidates
  local candidate_pid
  local activity_status
  cleanup_tree=$(collect_pid_tree "$$") || return 1
  descendant_tree=$(collect_pid_tree "$server_pid") || return 1
  group_members=$(collect_pgid_members "$server_pgid") || return 1
  merged_candidates=$(merge_pid_lists "$descendant_tree" "$group_members")
  while IFS= read -r candidate_pid; do
    case "$candidate_pid" in
      ''|*[!0-9]*) continue ;;
    esac
    if pid_list_contains "$candidate_pid" "$protected_baseline" ||
      pid_list_contains "$candidate_pid" "$cleanup_tree"; then
      continue
    fi
    activity_status=0
    candidate_is_active "$candidate_pid" || activity_status=$?
    if [ "$activity_status" -eq 0 ]; then
      printf '%s\n' "$candidate_pid"
    elif [ "$activity_status" -ne 1 ]; then
      return 1
    fi
  done <<EOF
$merged_candidates
EOF
}

signal_pid_list() {
  local signal_name=$1
  local pid_list=$2
  local process_pid
  while IFS= read -r process_pid; do
    case "$process_pid" in
      ''|*[!0-9]*) continue ;;
    esac
    kill "-$signal_name" "$process_pid" 2>/dev/null || true
  done <<EOF
$pid_list
EOF
}

start_server() {
  local checkout=${METSUKE_LP_CHECKOUT:-}
  local old_pid
  local server_pid
  local server_pgid
  local wait_ticks
  local pgid_ticks
  local http_status

  [ -n "$checkout" ] || {
    log "METSUKE_LP_CHECKOUT is required when METSUKE_TARGET_URL is unset"
    return 1
  }
  [ -d "$checkout" ] || {
    log "LP checkout does not exist: $checkout"
    return 1
  }
  [ -d "$checkout/node_modules" ] || {
    log "LP checkout is missing node_modules; install dependencies before the night run: $checkout"
    return 1
  }
  validate_port
  if [ -s "$PID_FILE" ]; then
    old_pid=$(sed -n '1p' "$PID_FILE")
    case "$old_pid" in
      ''|*[!0-9]*) ;;
      *)
        if server_is_alive "$old_pid"; then
          log "server is already running with pid $old_pid"
          return 1
        fi
        ;;
    esac
  fi
  if port_is_occupied; then
    log "port $METSUKE_PORT is already occupied; refusing to build or start"
    return 1
  fi

  log "building local LP in $checkout"
  (cd "$checkout" && npm run build)

  (
    cd "$checkout"
    exec npm run start -- -p "$METSUKE_PORT" -H 127.0.0.1
  ) >"$SERVER_LOG" 2>&1 &
  server_pid=$!
  printf '%s\n' "$server_pid" > "$PID_FILE"
  pgid_ticks=0
  server_pgid=
  while [ "$pgid_ticks" -lt 50 ]; do
    if server_pgid=$(process_group_for_pid "$server_pid"); then
      break
    fi
    if ! kill -0 "$server_pid" 2>/dev/null; then
      break
    fi
    sleep 0.01
    pgid_ticks=$((pgid_ticks + 1))
  done
  if [ -z "$server_pgid" ]; then
    log "could not record the LP server process group; refusing an untracked server"
    kill -KILL "$server_pid" 2>/dev/null || true
    rm -f "$PID_FILE" "$PGID_FILE" "$PORT_FILE"
    return 1
  fi
  printf '%s\n' "$server_pgid" > "$PGID_FILE"
  printf '%s\n' "$METSUKE_PORT" > "$PORT_FILE"

  wait_ticks=0
  while [ "$wait_ticks" -lt 180 ]; do
    if ! server_is_alive "$server_pid"; then
      log "LP server exited before becoming ready; see $SERVER_LOG"
      stop_server || true
      return 1
    fi
    http_status=$(curl --max-time 2 -s -o /dev/null -w '%{http_code}' \
      "http://127.0.0.1:$METSUKE_PORT" || true)
    if [ "$http_status" = 200 ]; then
      log "ready at http://127.0.0.1:$METSUKE_PORT"
      return 0
    fi
    sleep 1
    wait_ticks=$((wait_ticks + 1))
  done
  log "LP server did not return HTTP 200 within 180 seconds; see $SERVER_LOG"
  stop_server || true
  return 1
}

stop_server() {
  local server_pid
  local server_pgid
  local initial_tree
  local initial_group
  local protected_baseline
  local candidates
  local refreshed_candidates
  local term_ticks
  local kill_ticks
  local stable_ticks
  local previous_candidates
  local process_cleanup_failed=0
  local process_inspection_failed=0
  local free_ticks
  local port_free=false

  [ -s "$PID_FILE" ] || return 0
  server_pid=$(sed -n '1p' "$PID_FILE")
  case "$server_pid" in
    ''|*[!0-9]*)
      log "invalid server pid file: $PID_FILE"
      return 1
      ;;
  esac
  if [ -s "$PORT_FILE" ]; then
    METSUKE_PORT=$(sed -n '1p' "$PORT_FILE")
  fi
  validate_port

  if [ -s "$PGID_FILE" ]; then
    server_pgid=$(sed -n '1p' "$PGID_FILE")
  else
    server_pgid=$(process_group_for_pid "$server_pid") || {
      log "server process group is missing and cannot be recovered for pid $server_pid"
      return 1
    }
  fi
  case "$server_pgid" in
    ''|*[!0-9]*|0)
      log "invalid server process-group file: $PGID_FILE"
      return 1
      ;;
  esac

  if ! initial_group=$(collect_pgid_members "$server_pgid"); then
    log "could not inspect retained server process group $server_pgid"
    return 1
  fi
  if ! initial_tree=$(collect_pid_tree "$server_pid"); then
    log "could not inspect the recorded server descendant tree"
    return 1
  fi
  protected_baseline=$(pid_list_without "$initial_group" "$initial_tree")
  protected_baseline=$(merge_pid_lists "$protected_baseline" "$$
$PPID")
  if ! candidates=$(collect_server_candidates \
    "$server_pid" "$server_pgid" "$protected_baseline"); then
    log "could not build the initial server cleanup candidate set"
    return 1
  fi
  signal_pid_list TERM "$candidates"

  term_ticks=0
  while [ "$term_ticks" -lt 30 ]; do
    sleep 0.1
    if ! refreshed_candidates=$(collect_server_candidates \
      "$server_pid" "$server_pgid" "$protected_baseline"); then
      process_inspection_failed=1
      break
    fi
    candidates=$refreshed_candidates
    if [ -z "$candidates" ]; then
      break
    fi
    signal_pid_list TERM "$candidates"
    term_ticks=$((term_ticks + 1))
  done

  kill_ticks=0
  stable_ticks=0
  previous_candidates=
  while [ "$kill_ticks" -lt 30 ]; do
    if ! candidates=$(collect_server_candidates \
      "$server_pid" "$server_pgid" "$protected_baseline"); then
      process_inspection_failed=1
      break
    fi
    if [ -z "$candidates" ]; then
      break
    fi
    signal_pid_list KILL "$candidates"
    sleep 0.1
    if ! refreshed_candidates=$(collect_server_candidates \
      "$server_pid" "$server_pgid" "$protected_baseline"); then
      process_inspection_failed=1
      break
    fi
    if [ -z "$refreshed_candidates" ]; then
      candidates=
      break
    fi
    if [ "$refreshed_candidates" = "$previous_candidates" ]; then
      stable_ticks=$((stable_ticks + 1))
    else
      stable_ticks=0
    fi
    previous_candidates=$refreshed_candidates
    candidates=$refreshed_candidates
    if [ "$stable_ticks" -ge 2 ]; then
      break
    fi
    kill_ticks=$((kill_ticks + 1))
  done
  if [ "$process_inspection_failed" -ne 0 ]; then
    process_cleanup_failed=1
    log "server cleanup process inspection failed; refusing to report a clean stop"
  elif ! candidates=$(collect_server_candidates \
    "$server_pid" "$server_pgid" "$protected_baseline"); then
    process_cleanup_failed=1
    log "final server cleanup process inspection failed"
  elif [ -n "$candidates" ]; then
    process_cleanup_failed=1
    log "non-baseline server-group processes remain after bounded cleanup: $candidates"
  fi

  free_ticks=0
  while [ "$free_ticks" -lt 50 ]; do
    if ! port_is_occupied; then
      port_free=true
      break
    fi
    sleep 0.1
    free_ticks=$((free_ticks + 1))
  done
  if [ "$port_free" != true ]; then
    log "port $METSUKE_PORT is still occupied after server stop"
    process_cleanup_failed=1
  fi
  if [ "$process_cleanup_failed" -ne 0 ]; then
    log "server stop incomplete; protected same-group baseline was not signaled: $protected_baseline"
    return 1
  fi

  rm -f "$PID_FILE" "$PGID_FILE" "$PORT_FILE"
  log "stopped server tree and verified port $METSUKE_PORT is free"
}

case "${1:-}" in
  start) start_server ;;
  stop) stop_server ;;
  *)
    printf 'Usage: %s {start|stop}\n' "$0" >&2
    exit 2
    ;;
esac
