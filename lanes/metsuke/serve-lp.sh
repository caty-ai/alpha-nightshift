#!/bin/bash
set -euo pipefail

LANE_DIR=${LANE_DIR:?LANE_DIR is required}
METSUKE_PORT=${METSUKE_PORT:-4173}
PID_FILE="$LANE_DIR/metsuke-server.pid"
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
  ps -axo pid=,ppid= > "$process_snapshot"
  awk -v root="$root_pid" '
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
  ' "$process_snapshot"
  rm -f "$process_snapshot"
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
  local wait_ticks
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
  local pid_tree
  local refreshed_pid_tree
  local stop_ticks
  local free_ticks

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

  pid_tree=$(collect_pid_tree "$server_pid")
  signal_pid_list TERM "$pid_tree"
  stop_ticks=0
  while [ "$stop_ticks" -lt 30 ]; do
    refreshed_pid_tree=$(collect_pid_tree "$server_pid")
    pid_tree="$pid_tree
$refreshed_pid_tree"
    if ! server_is_alive "$server_pid"; then
      break
    fi
    sleep 0.1
    stop_ticks=$((stop_ticks + 1))
  done
  signal_pid_list KILL "$pid_tree"

  free_ticks=0
  while [ "$free_ticks" -lt 50 ]; do
    if ! port_is_occupied; then
      rm -f "$PID_FILE" "$PORT_FILE"
      log "stopped server tree and verified port $METSUKE_PORT is free"
      return 0
    fi
    sleep 0.1
    free_ticks=$((free_ticks + 1))
  done
  log "port $METSUKE_PORT is still occupied after server stop"
  return 1
}

case "${1:-}" in
  start) start_server ;;
  stop) stop_server ;;
  *)
    printf 'Usage: %s {start|stop}\n' "$0" >&2
    exit 2
    ;;
esac
