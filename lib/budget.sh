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

budget_check() {
  if ! budget_tmp_dir=$(mktemp -d "$STATE_DIR/.budget.XXXXXX"); then
    budget_fail_with_meter_error "probe_setup_failed"
    return $?
  fi
  budget_stdout="$budget_tmp_dir/stdout"
  budget_stderr="$budget_tmp_dir/stderr"
  NIGHTSHIFT_ACTIVE_BUDGET_TMP_DIR=$budget_tmp_dir
  NIGHTSHIFT_ACTIVE_PROBE_PID=
  NIGHTSHIFT_ACTIVE_PROBE_DESCENDANTS=

  set -m
  (
    exec /bin/bash -c "$BUDGET_PROBE_CMD"
  ) </dev/null >"$budget_stdout" 2>"$budget_stderr" &
  budget_pid=$!
  NIGHTSHIFT_ACTIVE_PROBE_PID=$budget_pid
  set +m
  budget_started=$(date '+%s')
  budget_timed_out=false
  # Give the exec'd probe one scheduler tick to enter its process group before
  # enforcing the timeout.
  sleep 0.1

  while nightshift_process_tree_alive "$budget_pid" "$NIGHTSHIFT_ACTIVE_PROBE_DESCENDANTS"; do
    NIGHTSHIFT_ACTIVE_PROBE_DESCENDANTS=$NIGHTSHIFT_PROCESS_KNOWN
    budget_now=$(date '+%s')
    if [ $((budget_now - budget_started)) -ge "$BUDGET_PROBE_TIMEOUT_SEC" ]; then
      budget_timed_out=true
      nightshift_stop_process_tree "$budget_pid" "$NIGHTSHIFT_ACTIVE_PROBE_DESCENDANTS"
      NIGHTSHIFT_ACTIVE_PROBE_DESCENDANTS=$NIGHTSHIFT_PROCESS_KNOWN
      break
    fi
    sleep 0.1
  done

  if wait "$budget_pid"; then
    budget_rc=0
  else
    budget_rc=$?
  fi
  nightshift_stop_process_tree "$budget_pid" "$NIGHTSHIFT_ACTIVE_PROBE_DESCENDANTS"
  budget_survivors=$NIGHTSHIFT_PROCESS_SURVIVORS
  NIGHTSHIFT_ACTIVE_PROBE_PID=
  NIGHTSHIFT_ACTIVE_PROBE_DESCENDANTS=

  if [ "$budget_timed_out" = true ]; then
    if [ -n "$(printf '%s' "$budget_survivors" | tr -d '[:space:]')" ]; then
      nightshift_log WARN "Budget probe $budget_pid still has survivors after descendant sweep: $budget_survivors"
    fi
    rm -rf "$budget_tmp_dir"
    NIGHTSHIFT_ACTIVE_BUDGET_TMP_DIR=
    budget_fail_with_meter_error "probe_timeout"
    return $?
  fi

  if [ -n "$(printf '%s' "$budget_survivors" | tr -d '[:space:]')" ]; then
    nightshift_log WARN "Budget probe $budget_pid left survivors after descendant sweep: $budget_survivors"
    rm -rf "$budget_tmp_dir"
    NIGHTSHIFT_ACTIVE_BUDGET_TMP_DIR=
    budget_fail_with_meter_error "probe_survivors"
    return $?
  fi

  if [ "$budget_rc" -ne 0 ]; then
    rm -rf "$budget_tmp_dir"
    NIGHTSHIFT_ACTIVE_BUDGET_TMP_DIR=
    budget_fail_with_meter_error "probe_failed"
    return $?
  fi

  if ! budget_result=$(jq -e -c --arg budget_cap "$NIGHT_BUDGET_TOKENS" '
    select(
      type == "object" and
      has("tokens_spent") and
      (.tokens_spent | type == "number" and . >= 0 and . == floor)
    )
    | (.tokens_spent | floor | tostring) as $spent_text
    | select($spent_text | test("^[0-9]{1,15}$"))
    | ($spent_text | tonumber) as $spent
    | ($budget_cap | tonumber) as $cap
    | {
        status: (
          if $cap > 0 and $spent >= $cap
          then "exhausted"
          else "ok"
          end
        ),
        tokens_spent: $spent
      }
  ' "$budget_stdout" 2>/dev/null); then
    rm -rf "$budget_tmp_dir"
    NIGHTSHIFT_ACTIVE_BUDGET_TMP_DIR=
    budget_fail_with_meter_error "invalid_probe_output"
    return $?
  fi
  case "$budget_result" in
    *'
'*)
      rm -rf "$budget_tmp_dir"
      NIGHTSHIFT_ACTIVE_BUDGET_TMP_DIR=
      budget_fail_with_meter_error "invalid_probe_output"
      return $?
      ;;
  esac

  rm -rf "$budget_tmp_dir"
  NIGHTSHIFT_ACTIVE_BUDGET_TMP_DIR=
  if ! budget_status=$(printf '%s\n' "$budget_result" | jq -r '.status' 2>/dev/null); then
    budget_fail_with_meter_error "invalid_probe_output"
    return $?
  fi
  if ! BUDGET_LAST_SNAPSHOT=$(printf '%s\n' "$budget_result" |
    jq -c '{tokens_spent: .tokens_spent}' 2>/dev/null); then
    budget_fail_with_meter_error "invalid_probe_output"
    return $?
  fi
  case "$budget_status" in
    ok) return 0 ;;
    exhausted) return 2 ;;
    *)
      budget_fail_with_meter_error "invalid_probe_output"
      return $?
      ;;
  esac
}

budget_snapshot() {
  printf '%s\n' "$BUDGET_LAST_SNAPSHOT"
}
