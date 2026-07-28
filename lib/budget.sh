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
  ledger_append "$meter_record"
  BUDGET_LAST_SNAPSHOT=$(jq -n -c --arg status "meter_error" --arg reason "$meter_reason" \
    '{status: $status, reason: $reason}')
}

budget_check() {
  budget_tmp_dir=$(mktemp -d "$STATE_DIR/.budget.XXXXXX")
  budget_stdout="$budget_tmp_dir/stdout"
  budget_stderr="$budget_tmp_dir/stderr"

  (
    /bin/bash -c "$BUDGET_PROBE_CMD" >"$budget_stdout" 2>"$budget_stderr"
  ) &
  budget_pid=$!
  budget_started=$(date '+%s')
  budget_timed_out=false

  while kill -0 "$budget_pid" 2>/dev/null; do
    budget_now=$(date '+%s')
    if [ $((budget_now - budget_started)) -ge "$BUDGET_PROBE_TIMEOUT_SEC" ]; then
      budget_timed_out=true
      kill -TERM "$budget_pid" 2>/dev/null || true
      sleep 1
      if kill -0 "$budget_pid" 2>/dev/null; then
        kill -KILL "$budget_pid" 2>/dev/null || true
      fi
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
    rm -rf "$budget_tmp_dir"
    budget_record_error "probe_timeout"
    return 1
  fi

  if [ "$budget_rc" -ne 0 ]; then
    rm -rf "$budget_tmp_dir"
    budget_record_error "probe_failed"
    return 1
  fi

  if ! budget_json=$(jq -e -c '
    select(
      type == "object" and
      has("tokens_spent") and
      (.tokens_spent | type == "number" and . >= 0 and . == floor)
    )
    | {tokens_spent: .tokens_spent}
  ' "$budget_stdout" 2>/dev/null); then
    rm -rf "$budget_tmp_dir"
    budget_record_error "invalid_probe_output"
    return 1
  fi
  case "$budget_json" in
    *'
'*)
      rm -rf "$budget_tmp_dir"
      budget_record_error "invalid_probe_output"
      return 1
      ;;
  esac

  rm -rf "$budget_tmp_dir"
  BUDGET_LAST_SNAPSHOT=$budget_json
  tokens_spent=$(printf '%s\n' "$budget_json" | jq -r '.tokens_spent')
  if [ "$NIGHT_BUDGET_TOKENS" -gt 0 ] &&
     [ "$tokens_spent" -ge "$NIGHT_BUDGET_TOKENS" ]; then
    return 2
  fi
  return 0
}

budget_snapshot() {
  printf '%s\n' "$BUDGET_LAST_SNAPSHOT"
}
