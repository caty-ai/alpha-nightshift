#!/bin/bash
set -euo pipefail

BUDGET_LAST_SNAPSHOT='{"status":"not_checked"}'

budget_record_error() {
  meter_reason=$1
  meter_record=$(jq -n -c \
    --arg ts "$(nightshift_iso_now)" \
    --arg night_id "$NIGHT_ID" \
    --arg reason "$meter_reason" \
    '{ts: $ts, night_id: $night_id, type: "meter_error", reason: $reason}')
  if ! ledger_append "$meter_record"; then
    return 1
  fi
  BUDGET_LAST_SNAPSHOT=$(jq -n -c --arg status "meter_error" --arg reason "$meter_reason" \
    '{status: $status, reason: $reason}')
}

budget_fail_with_meter_error() {
  budget_error_reason=$1
  if ! budget_record_error "$budget_error_reason"; then
    return 3
  fi
  return 1
}

budget_process_group_alive() {
  budget_group_pid=$1
  kill -0 -- "-$budget_group_pid" 2>/dev/null
}

budget_stop_process_group() {
  budget_group_pid=$1
  kill -TERM -- "-$budget_group_pid" 2>/dev/null || true
  budget_grace_started=$(date '+%s')
  while budget_process_group_alive "$budget_group_pid"; do
    budget_grace_now=$(date '+%s')
    if [ $((budget_grace_now - budget_grace_started)) -ge 10 ]; then
      kill -KILL -- "-$budget_group_pid" 2>/dev/null || true
      break
    fi
    sleep 0.1
  done

}

budget_check() {
  budget_tmp_dir=$(mktemp -d "$STATE_DIR/.budget.XXXXXX")
  budget_stdout="$budget_tmp_dir/stdout"
  budget_stderr="$budget_tmp_dir/stderr"

  set -m
  (
    exec /bin/bash -c "$BUDGET_PROBE_CMD"
  ) >"$budget_stdout" 2>"$budget_stderr" &
  budget_pid=$!
  set +m
  budget_started=$(date '+%s')
  budget_timed_out=false
  # Give the exec'd probe one scheduler tick to enter its process group before
  # enforcing the timeout.
  sleep 0.1

  while kill -0 "$budget_pid" 2>/dev/null; do
    budget_now=$(date '+%s')
    if [ $((budget_now - budget_started)) -ge "$BUDGET_PROBE_TIMEOUT_SEC" ]; then
      budget_timed_out=true
      budget_stop_process_group "$budget_pid"
      break
    fi
    sleep 0.1
  done

  if wait "$budget_pid"; then
    budget_rc=0
  else
    budget_rc=$?
  fi

  if [ "$budget_timed_out" = true ]; then
    if budget_group_members=$(ps -g "$budget_pid" -o pid= 2>/dev/null) &&
      [ -n "$(printf '%s' "$budget_group_members" | tr -d '[:space:]')" ]; then
      nightshift_log WARN "Budget probe process group $budget_pid still has survivors after KILL"
    fi
    rm -rf "$budget_tmp_dir"
    budget_fail_with_meter_error "probe_timeout"
    return $?
  fi

  if [ "$budget_rc" -ne 0 ]; then
    rm -rf "$budget_tmp_dir"
    budget_fail_with_meter_error "probe_failed"
    return $?
  fi

  if ! budget_json=$(jq -e -c '
    select(
      type == "object" and
      has("tokens_spent") and
      (.tokens_spent | type == "number" and . >= 0 and . == floor)
    )
    | {tokens_spent: (.tokens_spent | floor)}
  ' "$budget_stdout" 2>/dev/null); then
    rm -rf "$budget_tmp_dir"
    budget_fail_with_meter_error "invalid_probe_output"
    return $?
  fi
  case "$budget_json" in
    *'
'*)
      rm -rf "$budget_tmp_dir"
      budget_fail_with_meter_error "invalid_probe_output"
      return $?
      ;;
  esac

  rm -rf "$budget_tmp_dir"
  BUDGET_LAST_SNAPSHOT=$budget_json
  if ! tokens_spent=$(printf '%s\n' "$budget_json" | jq -r '.tokens_spent' 2>/dev/null); then
    budget_fail_with_meter_error "invalid_probe_output"
    return $?
  fi
  case "$tokens_spent" in
    ''|*[!0-9]*)
      budget_fail_with_meter_error "invalid_probe_output"
      return $?
      ;;
  esac
  if [ "$NIGHT_BUDGET_TOKENS" -gt 0 ] &&
     [ "$tokens_spent" -ge "$NIGHT_BUDGET_TOKENS" ]; then
    return 2
  fi
  return 0
}

budget_snapshot() {
  printf '%s\n' "$BUDGET_LAST_SNAPSHOT"
}
