#!/bin/bash
set -euo pipefail

LANE_DIR=${LANE_DIR:?LANE_DIR is required}
METSUKE_PORT=${METSUKE_PORT:-4173}
PID_FILE="$LANE_DIR/metsuke-server.pid"
PGID_FILE="$LANE_DIR/metsuke-server.pgid"
PORT_FILE="$LANE_DIR/metsuke-server.port"
BASELINE_FILE="$LANE_DIR/metsuke-server.baseline"
IDENTITY_FILE="$LANE_DIR/metsuke-server.identity"
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
    kill -0 "$process_pid" 2>/dev/null || return 1
    return 2
  fi
  case "$process_state" in
    ''|Z*) return 1 ;;
  esac
  return 0
}

process_identity_for_pid() {
  local process_pid=$1
  local process_started
  kill -0 "$process_pid" 2>/dev/null || return 1
  if ! process_started=$(ps -o lstart= -p "$process_pid" 2>/dev/null |
    awk '{$1=$1; print}'); then
    kill -0 "$process_pid" 2>/dev/null || return 1
    return 2
  fi
  if [ -z "$process_started" ]; then
    kill -0 "$process_pid" 2>/dev/null || return 1
    return 2
  fi
  printf '%s\n' "$process_pid $process_started" |
    shasum -a 256 | awk '{print $1}'
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

write_atomic_state_line() {
  local destination=$1
  local value=$2
  local state_tmp
  state_tmp=$(mktemp "$LANE_DIR/.metsuke-state.XXXXXX") || return 1
  if ! printf '%s\n' "$value" > "$state_tmp" ||
    ! mv "$state_tmp" "$destination"; then
    rm -f "$state_tmp"
    return 1
  fi
}

read_single_state_line() {
  local state_file=$1
  local state_value
  [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1
  state_value=$(awk '
    NR == 1 {value = $0}
    NR > 1 {exit 1}
    END {
      if (NR != 1 || value == "") {
        exit 1
      }
      print value
    }
  ' "$state_file") || return 1
  printf '%s\n' "$state_value"
}

clear_lifecycle_state() {
  rm -f \
    "$PID_FILE" \
    "$PGID_FILE" \
    "$PORT_FILE" \
    "$BASELINE_FILE" \
    "$IDENTITY_FILE"
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

collect_pid_forest() {
  local root_pids=$1
  local root_csv
  local process_snapshot="$LANE_DIR/.metsuke-process-forest.$$.txt"
  root_csv=$(printf '%s\n' "$root_pids" |
    awk '/^[0-9]+$/ {values = values separator $1; separator = ","} END {print values}')
  if ! ps -axo pid=,ppid= > "$process_snapshot"; then
    rm -f "$process_snapshot"
    return 1
  fi
  if ! awk -v roots="$root_csv" '
    BEGIN {
      root_count = split(roots, root_list, ",")
      for (root_index = 1; root_index <= root_count; root_index += 1) {
        if (root_list[root_index] ~ /^[0-9]+$/) {
          selected[root_list[root_index]] = 1
        }
      }
    }
    {
      pid[NR] = $1
      parent[NR] = $2
    }
    END {
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

collect_pid_ancestry() {
  local process_pid=$1
  local process_snapshot="$LANE_DIR/.metsuke-process-ancestry.$$.txt"
  if ! ps -axo pid=,ppid= > "$process_snapshot"; then
    rm -f "$process_snapshot"
    return 1
  fi
  if ! awk -v root="$process_pid" '
    {
      parent[$1] = $2
    }
    END {
      current = root
      while (current ~ /^[0-9]+$/ && current > 0 && !seen[current]++) {
        print current
        current = parent[current]
      }
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

pid_list_intersection() {
  local pid_list=$1
  local retained_pids=$2
  local process_pid
  while IFS= read -r process_pid; do
    case "$process_pid" in
      ''|*[!0-9]*) continue ;;
    esac
    if pid_list_contains "$process_pid" "$retained_pids"; then
      printf '%s\n' "$process_pid"
    fi
  done <<EOF
$pid_list
EOF
}

record_prelaunch_baseline() {
  local server_pgid=$1
  local baseline_tmp
  local baseline_members
  local baseline_pid
  local baseline_identity
  local identity_status
  baseline_tmp=$(mktemp "$LANE_DIR/.metsuke-baseline.XXXXXX") || return 1
  : > "$baseline_tmp"
  if ! baseline_members=$(collect_pgid_members "$server_pgid"); then
    rm -f "$baseline_tmp"
    return 1
  fi
  while IFS= read -r baseline_pid; do
    case "$baseline_pid" in
      ''|*[!0-9]*) continue ;;
    esac
    identity_status=0
    baseline_identity=$(process_identity_for_pid "$baseline_pid") ||
      identity_status=$?
    if [ "$identity_status" -eq 1 ]; then
      continue
    fi
    if [ "$identity_status" -ne 0 ]; then
      rm -f "$baseline_tmp"
      return 1
    fi
    printf '%s %s\n' "$baseline_pid" "$baseline_identity" \
      >> "$baseline_tmp" || {
      rm -f "$baseline_tmp"
      return 1
    }
  done <<EOF
$baseline_members
EOF
  if [ ! -s "$baseline_tmp" ] ||
    ! mv "$baseline_tmp" "$BASELINE_FILE"; then
    rm -f "$baseline_tmp"
    return 1
  fi
}

collect_live_baseline_members() {
  local baseline_pid
  local expected_identity
  local extra_field
  local actual_identity
  local identity_status
  [ -f "$BASELINE_FILE" ] && [ ! -L "$BASELINE_FILE" ] ||
    return 2
  [ -s "$BASELINE_FILE" ] || return 2
  while IFS=' ' read -r baseline_pid expected_identity extra_field; do
    case "$baseline_pid" in
      ''|*[!0-9]*) return 2 ;;
    esac
    case "$expected_identity" in
      ''|*[!0-9a-f]*)
        return 2
        ;;
    esac
    [ "${#expected_identity}" -eq 64 ] || return 2
    [ -z "$extra_field" ] || return 2
    identity_status=0
    actual_identity=$(process_identity_for_pid "$baseline_pid") ||
      identity_status=$?
    if [ "$identity_status" -eq 1 ]; then
      continue
    fi
    if [ "$identity_status" -ne 0 ] ||
      [ "$actual_identity" != "$expected_identity" ]; then
      return 2
    fi
    printf '%s\n' "$baseline_pid"
  done < "$BASELINE_FILE"
}

pid_list_has_pgid_member() {
  local pid_list=$1
  local wanted_pgid=$2
  local process_pid
  local process_pgid
  while IFS= read -r process_pid; do
    case "$process_pid" in
      ''|*[!0-9]*) continue ;;
    esac
    process_pgid=$(process_group_for_pid "$process_pid") || continue
    if [ "$process_pgid" = "$wanted_pgid" ]; then
      return 0
    fi
  done <<EOF
$pid_list
EOF
  return 1
}

collect_server_candidates() {
  local server_pid=$1
  local server_pgid=$2
  local expected_server_identity=$3
  local caller_ancestry=$4
  local live_baseline
  local baseline_status
  local actual_server_identity
  local identity_status
  local actual_server_pgid
  local descendant_tree
  local protected_roots
  local protected_tree
  local group_members
  local merged_candidates
  local candidate_pid
  local activity_status
  baseline_status=0
  live_baseline=$(collect_live_baseline_members) || baseline_status=$?
  [ "$baseline_status" -eq 0 ] || return 1
  identity_status=0
  actual_server_identity=$(process_identity_for_pid "$server_pid") ||
    identity_status=$?
  if [ "$identity_status" -eq 0 ]; then
    [ "$actual_server_identity" = "$expected_server_identity" ] || return 1
    actual_server_pgid=$(process_group_for_pid "$server_pid") || return 1
    [ "$actual_server_pgid" = "$server_pgid" ] || return 1
    descendant_tree=$(collect_pid_tree "$server_pid") || return 1
  elif [ "$identity_status" -eq 1 ]; then
    descendant_tree=
    pid_list_has_pgid_member "$live_baseline" "$server_pgid" || return 1
  else
    return 1
  fi
  group_members=$(collect_pgid_members "$server_pgid") || return 1
  caller_ancestry=$(pid_list_intersection "$caller_ancestry" "$group_members")
  protected_roots=$(merge_pid_lists "$live_baseline" "$caller_ancestry")
  protected_roots=$(pid_list_without "$protected_roots" "1")
  protected_tree=$(collect_pid_forest "$protected_roots") || return 1
  protected_tree=$(pid_list_without "$protected_tree" "$descendant_tree")
  merged_candidates=$(merge_pid_lists "$descendant_tree" "$group_members")
  while IFS= read -r candidate_pid; do
    case "$candidate_pid" in
      ''|*[!0-9]*) continue ;;
    esac
    if pid_list_contains "$candidate_pid" "$protected_tree"; then
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
  local identity_ticks
  local http_status
  local caller_pgid
  local server_identity

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

  caller_pgid=$(process_group_for_pid "$$") || {
    log "could not determine the pre-launch process group"
    return 1
  }
  if ! record_prelaunch_baseline "$caller_pgid"; then
    log "could not atomically record the pre-launch process identity baseline"
    return 1
  fi
  (
    cd "$checkout"
    exec npm run start -- -p "$METSUKE_PORT" -H 127.0.0.1
  ) >"$SERVER_LOG" 2>&1 &
  server_pid=$!
  if ! write_atomic_state_line "$PID_FILE" "$server_pid" ||
    ! write_atomic_state_line "$PGID_FILE" "$caller_pgid"; then
    log "could not persist the LP server lifecycle state"
    kill -KILL "$server_pid" 2>/dev/null || true
    clear_lifecycle_state
    return 1
  fi
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
  if [ -z "$server_pgid" ] || [ "$server_pgid" != "$caller_pgid" ]; then
    log "LP server did not retain the recorded pre-launch process group"
    kill -KILL "$server_pid" 2>/dev/null || true
    clear_lifecycle_state
    return 1
  fi
  identity_ticks=0
  server_identity=
  while [ "$identity_ticks" -lt 50 ]; do
    if server_identity=$(process_identity_for_pid "$server_pid"); then
      break
    fi
    if ! kill -0 "$server_pid" 2>/dev/null; then
      break
    fi
    sleep 0.01
    identity_ticks=$((identity_ticks + 1))
  done
  if [ -z "$server_identity" ] ||
    ! write_atomic_state_line "$IDENTITY_FILE" "$server_identity" ||
    ! write_atomic_state_line "$PORT_FILE" "$METSUKE_PORT"; then
    log "could not persist the LP server process identity"
    kill -KILL "$server_pid" 2>/dev/null || true
    clear_lifecycle_state
    return 1
  fi

  wait_ticks=0
  while [ "$wait_ticks" -lt 180 ]; do
    if ! server_is_alive "$server_pid"; then
      log "LP server exited before becoming ready; see $SERVER_LOG"
      stop_server || true
      clear_lifecycle_state
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
  clear_lifecycle_state
  return 1
}

stop_server() {
  local server_pid
  local server_pgid
  local expected_server_identity
  local actual_server_identity
  local identity_status
  local actual_server_pgid
  local caller_ancestry
  local live_baseline
  local baseline_status
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
  server_pid=$(read_single_state_line "$PID_FILE") || {
    log "missing or unsafe server pid state: $PID_FILE"
    return 1
  }
  case "$server_pid" in
    ''|*[!0-9]*)
      log "invalid server pid file: $PID_FILE"
      return 1
      ;;
  esac
  if [ -s "$PORT_FILE" ]; then
    METSUKE_PORT=$(read_single_state_line "$PORT_FILE") || {
      log "missing or unsafe server port state: $PORT_FILE"
      return 1
    }
  fi
  validate_port

  server_pgid=$(read_single_state_line "$PGID_FILE") || {
    log "missing or unsafe server process-group state: $PGID_FILE"
    return 1
  }
  case "$server_pgid" in
    ''|*[!0-9]*|0)
      log "invalid server process-group file: $PGID_FILE"
      return 1
      ;;
  esac
  expected_server_identity=$(read_single_state_line "$IDENTITY_FILE") || {
    log "missing or unsafe server identity state: $IDENTITY_FILE"
    return 1
  }
  case "$expected_server_identity" in
    *[!0-9a-f]*)
      log "malformed server identity state: $IDENTITY_FILE"
      return 1
      ;;
  esac
  [ "${#expected_server_identity}" -eq 64 ] || {
    log "malformed server identity state: $IDENTITY_FILE"
    return 1
  }
  baseline_status=0
  live_baseline=$(collect_live_baseline_members) || baseline_status=$?
  if [ "$baseline_status" -ne 0 ]; then
    log "missing, malformed, or stale pre-launch process baseline: $BASELINE_FILE"
    return 1
  fi
  identity_status=0
  actual_server_identity=$(process_identity_for_pid "$server_pid") ||
    identity_status=$?
  if [ "$identity_status" -eq 0 ]; then
    if [ "$actual_server_identity" != "$expected_server_identity" ]; then
      log "recorded server pid $server_pid has been reused; refusing to signal it or its process tree"
      return 1
    fi
    actual_server_pgid=$(process_group_for_pid "$server_pid") || {
      log "could not verify the live recorded server process group"
      return 1
    }
    if [ "$actual_server_pgid" != "$server_pgid" ]; then
      log "live recorded server pid $server_pid moved from retained process group $server_pgid; refusing cleanup"
      return 1
    fi
  elif [ "$identity_status" -eq 1 ]; then
    if ! pid_list_has_pgid_member "$live_baseline" "$server_pgid"; then
      log "server root is gone and no identity-matching pre-launch baseline anchor retains process group $server_pgid"
      return 1
    fi
  else
    log "could not verify the recorded server process identity"
    return 1
  fi
  caller_ancestry=$(collect_pid_ancestry "$$") || {
    log "could not inspect cleanup caller ancestry"
    return 1
  }
  if ! candidates=$(collect_server_candidates \
    "$server_pid" "$server_pgid" "$expected_server_identity" \
    "$caller_ancestry"); then
    log "could not build the initial server cleanup candidate set"
    return 1
  fi
  signal_pid_list TERM "$candidates"

  term_ticks=0
  while [ "$term_ticks" -lt 30 ]; do
    sleep 0.1
    if ! refreshed_candidates=$(collect_server_candidates \
      "$server_pid" "$server_pgid" "$expected_server_identity" \
      "$caller_ancestry"); then
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
      "$server_pid" "$server_pgid" "$expected_server_identity" \
      "$caller_ancestry"); then
      process_inspection_failed=1
      break
    fi
    if [ -z "$candidates" ]; then
      break
    fi
    signal_pid_list KILL "$candidates"
    sleep 0.1
    if ! refreshed_candidates=$(collect_server_candidates \
      "$server_pid" "$server_pgid" "$expected_server_identity" \
      "$caller_ancestry"); then
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
    "$server_pid" "$server_pgid" "$expected_server_identity" \
    "$caller_ancestry"); then
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
    log "server stop incomplete; pre-launch baseline and caller ancestry were not signaled"
    return 1
  fi

  clear_lifecycle_state
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
