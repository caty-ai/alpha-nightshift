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
    ''|*[!0-9]*|0) log "METSUKE_PORT must be a positive integer"; return 1 ;;
  esac
  [ "$METSUKE_PORT" -le 65535 ] || {
    log "METSUKE_PORT must not exceed 65535"
    return 1
  }
}

server_is_alive() {
  server_pid=$1
  kill -0 "$server_pid" 2>/dev/null
}

start_server() {
  checkout=${METSUKE_LP_CHECKOUT:-}
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

  log "building local LP in $checkout"
  (cd "$checkout" && npm run build)

  set -m
  (
    cd "$checkout"
    exec npm run start -- -p "$METSUKE_PORT" -H 127.0.0.1
  ) >"$SERVER_LOG" 2>&1 &
  server_pid=$!
  set +m
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

  if ! kill -TERM -- "-$server_pid" 2>/dev/null; then
    if server_is_alive "$server_pid"; then
      kill -TERM "$server_pid" 2>/dev/null || true
    fi
  fi
  stop_ticks=0
  while server_is_alive "$server_pid" && [ "$stop_ticks" -lt 30 ]; do
    sleep 0.1
    stop_ticks=$((stop_ticks + 1))
  done
  # npm may exit before the server it launched. Kill the dedicated job-control
  # process group after the grace period even when the recorded leader is gone.
  if ! kill -KILL -- "-$server_pid" 2>/dev/null; then
    if server_is_alive "$server_pid"; then
      kill -KILL "$server_pid" 2>/dev/null || true
    fi
  fi

  free_ticks=0
  while [ "$free_ticks" -lt 50 ]; do
    if ! curl --max-time 1 -s -o /dev/null \
      "http://127.0.0.1:$METSUKE_PORT"; then
      rm -f "$PID_FILE" "$PORT_FILE"
      log "stopped and verified port $METSUKE_PORT is free"
      return 0
    fi
    sleep 0.1
    free_ticks=$((free_ticks + 1))
  done
  log "port $METSUKE_PORT still accepts connections after server stop"
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
