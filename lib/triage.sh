#!/bin/bash
set -euo pipefail

TRIAGE_ACTOR=auto-triage
TRIAGE_REPORT_NONCE=
TRIAGE_RUN_ID=
TRIAGE_WORK_DIR=
TRIAGE_LOCK_DIR=
TRIAGE_LOCK_HELD=false
TRIAGE_LOGGING_STARTED=false
TRIAGE_PHASE_A_END_EPOCH=0

triage_usage() {
  cat <<'EOF' >&2
Usage: bin/morning-triage [--dry-run] [--force] [--state-dir /abs/path] [--repo-pin repo=sha[@/abs/path]]
EOF
}

triage_validate_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

triage_validate_hhmm() {
  case "$1" in
    [0-2][0-9]:[0-5][0-9]) ;;
    *) return 1 ;;
  esac
  hour=${1%%:*}
  [ "$hour" -le 23 ]
}

triage_validate_absolute_dir() {
  case "$1" in
    /*) ;;
    *) return 1 ;;
  esac
  return 0
}

triage_safe_relative_path() {
  printf '%s\n' "$1" | jq -e -R '
    length > 0 and
    (test("[\u0000-\u001F\u007F]") | not) and
    (startswith("/") | not) and
    (startswith("//") | not) and
    (test("^[A-Za-z][A-Za-z0-9+.-]*:") | not) and
    (test("(^|/)\\.\\.?(?:/|$)") | not)
  ' >/dev/null 2>&1
}

triage_join_by() {
  triage_join_sep=$1
  shift
  triage_join_first=true
  for triage_join_item in "$@"; do
    if [ "$triage_join_first" = true ]; then
      printf '%s' "$triage_join_item"
      triage_join_first=false
    else
      printf '%s%s' "$triage_join_sep" "$triage_join_item"
    fi
  done
  printf '\n'
}

triage_iso_to_epoch() {
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" '+%s'
}

triage_date_to_epoch() {
  date -j -u -f '%Y-%m-%d' "$1" '+%s'
}

triage_now_hhmm() {
  printf '%s\n' "${TRIAGE_NOW_HM:-$(date '+%H:%M')}"
}

triage_phase_budget_available() {
  [ "$TRIAGE_PHASE_A_END_EPOCH" -gt 0 ] || return 0
  [ "$(/bin/date '+%s')" -lt "$TRIAGE_PHASE_A_END_EPOCH" ]
}

triage_before_hard_wall() {
  [ "$(triage_now_hhmm)" \< "$TRIAGE_HARD_WALL" ]
}

triage_current_repo_full_name() {
  triage_remote_url=$(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null || true)
  [ -n "$triage_remote_url" ] || return 1
  printf '%s\n' "$triage_remote_url" |
    sed -E \
      -e 's#^git@github\.com:##' \
      -e 's#^https://github\.com/##' \
      -e 's#\.git$##'
}

triage_load_defaults() {
  TRIAGE_ENABLED=${TRIAGE_ENABLED:-0}
  TRIAGE_ALREADY_FIXED_MODE=${TRIAGE_ALREADY_FIXED_MODE:-suggest}
  TRIAGE_MAX_VERIFY_PER_RUN=${TRIAGE_MAX_VERIFY_PER_RUN:-25}
  TRIAGE_REVERIFY_INTERVAL_DAYS=${TRIAGE_REVERIFY_INTERVAL_DAYS:-7}
  TRIAGE_MAX_NEW_FOR_DEDUP=${TRIAGE_MAX_NEW_FOR_DEDUP:-40}
  TRIAGE_VERIFY_BATCH=${TRIAGE_VERIFY_BATCH:-5}
  TRIAGE_DEDUP_BATCH=${TRIAGE_DEDUP_BATCH:-10}
  TRIAGE_CONCURRENCY=${TRIAGE_CONCURRENCY:-3}
  TRIAGE_LLM_TIMEOUT_SEC=${TRIAGE_LLM_TIMEOUT_SEC:-300}
  TRIAGE_PHASE_A_DEADLINE_SEC=${TRIAGE_PHASE_A_DEADLINE_SEC:-900}
  TRIAGE_HARD_WALL=${TRIAGE_HARD_WALL:-06:58}
  TRIAGE_DEDUP_POOL_MAX=${TRIAGE_DEDUP_POOL_MAX:-150}
  TRIAGE_ADAPTER=${TRIAGE_ADAPTER:-"$REPO_ROOT/lanes/review/adapters/codex.sh"}
  TRIAGE_REPORT_ISSUE=${TRIAGE_REPORT_ISSUE:-}
  TRIAGE_TARGET_REPOS=${TRIAGE_TARGET_REPOS:-}
  TRIAGE_REPORT_REPO_FULL_NAME=${TRIAGE_REPORT_REPO_FULL_NAME:-}
  TRIAGE_GH_BIN=${TRIAGE_GH_BIN:-gh}
  TRIAGE_SYNC_RETRY_ATTEMPTS=${TRIAGE_SYNC_RETRY_ATTEMPTS:-5}
  TRIAGE_SYNC_RETRY_SEC=${TRIAGE_SYNC_RETRY_SEC:-60}

  triage_validate_uint "$TRIAGE_ENABLED" || return 1
  triage_validate_uint "$TRIAGE_MAX_VERIFY_PER_RUN" || return 1
  triage_validate_uint "$TRIAGE_REVERIFY_INTERVAL_DAYS" || return 1
  triage_validate_uint "$TRIAGE_MAX_NEW_FOR_DEDUP" || return 1
  triage_validate_uint "$TRIAGE_VERIFY_BATCH" || return 1
  triage_validate_uint "$TRIAGE_DEDUP_BATCH" || return 1
  triage_validate_uint "$TRIAGE_CONCURRENCY" || return 1
  triage_validate_uint "$TRIAGE_LLM_TIMEOUT_SEC" || return 1
  triage_validate_uint "$TRIAGE_PHASE_A_DEADLINE_SEC" || return 1
  triage_validate_uint "$TRIAGE_DEDUP_POOL_MAX" || return 1
  triage_validate_uint "$TRIAGE_SYNC_RETRY_ATTEMPTS" || return 1
  triage_validate_uint "$TRIAGE_SYNC_RETRY_SEC" || return 1
  triage_validate_hhmm "$TRIAGE_HARD_WALL" || return 1
  case "$TRIAGE_ALREADY_FIXED_MODE" in
    suggest|reject) ;;
    *) return 1 ;;
  esac
  [ -x "$TRIAGE_ADAPTER" ] || return 1
}

triage_prepare_runtime() {
  TRIAGE_RUN_ID="triage-$(date -u '+%Y%m%dT%H%M%SZ')-$$"
  export TRIAGE_RUN_ID
  mkdir -p \
    "$STATE_DIR/triage" \
    "$STATE_DIR/triage/cache" \
    "$STATE_DIR/triage/state" \
    "$STATE_DIR/triage/clones"
  TRIAGE_WORK_DIR=$(mktemp -d "$STATE_DIR/.morning-triage.XXXXXX") || return 1
  mkdir -p "$TRIAGE_WORK_DIR/clones"
}

triage_cleanup() {
  triage_cleanup_rc=$?
  if [ "$TRIAGE_LOCK_HELD" = true ] && [ -n "$TRIAGE_LOCK_DIR" ]; then
    lock_release "$TRIAGE_LOCK_DIR" || true
  fi
  if [ -n "$TRIAGE_WORK_DIR" ] && [ -d "$TRIAGE_WORK_DIR" ]; then
    rm -rf "$TRIAGE_WORK_DIR"
  fi
  if [ "$TRIAGE_LOGGING_STARTED" = true ]; then
    nightshift_finish_logging "$triage_cleanup_rc" || true
  fi
  return "$triage_cleanup_rc"
}

triage_acquire_lock() {
  TRIAGE_LOCK_DIR="$STATE_DIR/locks/nightshift.lock"
  triage_lock_rc=0
  lock_acquire "$TRIAGE_LOCK_DIR" || triage_lock_rc=$?
  if [ "$triage_lock_rc" -ne 0 ]; then
    return "$triage_lock_rc"
  fi
  TRIAGE_LOCK_HELD=true
}

triage_release_lock() {
  [ "$TRIAGE_LOCK_HELD" = true ] || return 0
  lock_release "$TRIAGE_LOCK_DIR"
  TRIAGE_LOCK_HELD=false
}

triage_state_file() {
  printf '%s\n' "$STATE_DIR/triage/state/triage-state.json"
}

triage_init_state_file() {
  triage_state_path=$(triage_state_file)
  if [ ! -f "$triage_state_path" ]; then
    printf '%s\n' '{"last_run_completed_at":null,"verified":{}}' > "$triage_state_path"
  fi
}

triage_assert_actor_uniqueness() {
  triage_actor_projection="$TRIAGE_WORK_DIR/actor-projection.jsonl"
  triage_actor_repo=$(triage_report_repo_full_name) || return 1
  triage_actor_source_prefix="https://github.com/$triage_actor_repo/issues/"
  ledger_project_findings > "$triage_actor_projection" || return 1
  if jq -e --arg actor "$TRIAGE_ACTOR" \
    --arg source_prefix "$triage_actor_source_prefix" '
    select(
      .latest_verdict.actor == $actor and
      (
        (.latest_verdict.source_ref | type) != "string" or
        ((.latest_verdict.source_ref | startswith($source_prefix)) | not)
      )
    )
  ' "$triage_actor_projection" >/dev/null 2>&1; then
    return 1
  else
    triage_actor_jq_rc=$?
  fi
  [ "$triage_actor_jq_rc" -eq 4 ]
}

triage_check_window() {
  triage_force=$1
  if [ "$triage_force" = true ]; then
    return 0
  fi
  triage_now=$(triage_now_hhmm)
  if [[ "$triage_now" < "06:30" || "$triage_now" > "08:00" ]]; then
    nightshift_log INFO "morning-triage: outside execution window ($triage_now)"
    return 2
  fi
}

triage_parse_repo_pin() {
  triage_pin=$1
  printf '%s\n' "$triage_pin" | jq -Rn '
    input as $raw |
    ($raw | capture("^(?<repo>[^=@]+)=(?<sha>[0-9a-f]{7,40})(?:@(?<path>/.*))?$")) as $m |
    {
      ledger_repo: $m.repo,
      sha: ($m.sha | ascii_downcase)
    } + (if ($m.path // "") == "" then {} else {path: $m.path} end)
  ' 2>/dev/null
}

triage_repo_pins_file() {
  printf '%s\n' "$TRIAGE_WORK_DIR/repo-pins.jsonl"
}

triage_append_repo_pin() {
  triage_pin_json=$1
  triage_pin_file=$(triage_repo_pins_file)
  printf '%s\n' "$triage_pin_json" >> "$triage_pin_file"
}

triage_repo_pin_for() {
  triage_repo=$1
  triage_pin_file=$(triage_repo_pins_file)
  [ -f "$triage_pin_file" ] || return 1
  jq -e -c --arg repo "$triage_repo" 'select(.ledger_repo == $repo)' "$triage_pin_file" | tail -n 1
}

triage_target_repo_map_file() {
  printf '%s\n' "$TRIAGE_WORK_DIR/target-repos.jsonl"
}

triage_parse_target_repo_entry() {
  triage_entry=$1
  printf '%s\n' "$triage_entry" | jq -Rn '
    input as $raw |
    ($raw | capture("^(?<repo>[^=@[:space:]]+)=(?<full>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(?:@(?<path>/.*))?$")) as $m |
    {
      ledger_repo: $m.repo,
      repo_full_name: $m.full
    } + (if ($m.path // "") == "" then {} else {path: $m.path} end)
  ' 2>/dev/null
}

triage_parse_target_repo_map() {
  triage_target_file=$(triage_target_repo_map_file)
  : > "$triage_target_file"
  [ -n "$TRIAGE_TARGET_REPOS" ] || return 1
  while IFS= read -r triage_entry || [ -n "$triage_entry" ]; do
    [ -n "$triage_entry" ] || continue
    if ! triage_entry_json=$(triage_parse_target_repo_entry "$triage_entry"); then
      return 1
    fi
    printf '%s\n' "$triage_entry_json" >> "$triage_target_file"
  done <<EOF
$(printf '%s\n' "$TRIAGE_TARGET_REPOS" | tr '[:space:]' '\n')
EOF
}

triage_target_repo_for() {
  triage_repo=$1
  triage_target_file=$(triage_target_repo_map_file)
  jq -e -c --arg repo "$triage_repo" 'select(.ledger_repo == $repo)' "$triage_target_file" | tail -n 1
}

triage_last_run_completed_at() {
  jq -r '.last_run_completed_at // empty' "$(triage_state_file)"
}

triage_verified_at_for() {
  triage_finding_id=$1
  jq -r --arg finding_id "$triage_finding_id" '
    .verified[$finding_id] as $entry |
    if ($entry | type) == "object" then $entry.last_verified_at // empty
    else $entry // empty end
  ' "$(triage_state_file)"
}

triage_update_verified_at() {
  triage_verified_jsonl=$1
  triage_state_path=$(triage_state_file)
  triage_tmp="$TRIAGE_WORK_DIR/triage-state.tmp"
  if [ -s "$triage_verified_jsonl" ]; then
    jq -s '
      .[0] as $state |
      .[1:] as $updates |
      reduce $updates[] as $update ($state;
        .verified[$update.finding_id] = {
          last_verified_at: $update.verified_at,
          verdict: $update.verdict
        }
      )
    ' "$triage_state_path" "$triage_verified_jsonl" > "$triage_tmp"
  else
    cp "$triage_state_path" "$triage_tmp"
  fi
  mv "$triage_tmp" "$triage_state_path"
}

triage_mark_run_completed() {
  triage_state_path=$(triage_state_file)
  triage_tmp="$TRIAGE_WORK_DIR/triage-state.complete.tmp"
  jq --arg completed_at "$(nightshift_iso_now)" '.last_run_completed_at = $completed_at' \
    "$triage_state_path" > "$triage_tmp"
  mv "$triage_tmp" "$triage_state_path"
}

triage_report_repo_full_name() {
  if [ -n "$TRIAGE_REPORT_REPO_FULL_NAME" ]; then
    printf '%s\n' "$TRIAGE_REPORT_REPO_FULL_NAME"
    return 0
  fi
  triage_current_repo_full_name
}

triage_validate_report_issue() {
  triage_validate_uint "$TRIAGE_REPORT_ISSUE" || return 1
  triage_issue_repo=$(triage_report_repo_full_name) || return 1
  triage_issue_json=$("$TRIAGE_GH_BIN" api --method GET \
    "repos/$triage_issue_repo/issues/$TRIAGE_REPORT_ISSUE") || return 1
  printf '%s\n' "$triage_issue_json" | jq -e '
    type == "object" and
    (.number | type == "number") and
    (.pull_request | not)
  ' >/dev/null 2>&1
}

triage_projection_file() {
  printf '%s\n' "$TRIAGE_WORK_DIR/current.jsonl"
}

triage_projection_snapshot() {
  triage_projection=$(triage_projection_file)
  ledger_project_findings > "$triage_projection"
}

triage_stage_stats_file() {
  printf '%s\n' "$TRIAGE_WORK_DIR/stats.json"
}

triage_stats_init() {
  printf '%s\n' '{
    "outside_repo_count": 0,
    "new_findings_total": 0,
    "new_findings_processed": 0,
    "new_findings_carried": 0,
    "verify_total": 0,
    "verify_processed": 0,
    "verify_skipped_recent": 0,
    "verify_carried": 0,
    "verify_invalid_lines": 0,
    "dedup_invalid_lines": 0,
    "decision_drops_target": 0,
    "decision_drops_canonical": 0,
    "decision_deduped": 0,
    "dedup_pool_shrunk": 0,
    "dedup_pool_empty": 0,
    "adapter_failures": 0,
    "closure_incomplete_count": 0,
    "phase_deadline_count": 0,
    "hard_wall_count": 0
  }' > "$(triage_stage_stats_file)"
}

triage_stats_increment() {
  triage_key=$1
  triage_amount=${2:-1}
  triage_stats=$(triage_stage_stats_file)
  triage_tmp="$TRIAGE_WORK_DIR/stats.tmp"
  jq --arg key "$triage_key" --argjson amount "$triage_amount" \
    '.[$key] = ((.[$key] // 0) + $amount)' \
    "$triage_stats" > "$triage_tmp"
  mv "$triage_tmp" "$triage_stats"
}

triage_repo_worktree_json() {
  triage_repo=$1
  triage_target=$(triage_target_repo_for "$triage_repo") || return 1
  triage_pin=$(triage_repo_pin_for "$triage_repo" 2>/dev/null || true)
  printf '%s\n' "$triage_target" | jq -c --argjson pin "${triage_pin:-null}" '
    . + (if $pin == null then {} else {pin: $pin.sha} end)
      + (if $pin == null or ($pin | has("path") | not) then {} else {pin_path: $pin.path} end)
  '
}

triage_clone_repo_for() {
  triage_repo=$1
  triage_target=$(triage_target_repo_for "$triage_repo") || return 1
  triage_clone_dir="$TRIAGE_WORK_DIR/repos/$triage_repo"
  mkdir -p "$TRIAGE_WORK_DIR/repos"
  triage_pin=$(triage_repo_pin_for "$triage_repo" 2>/dev/null || true)
  triage_source_path=$(printf '%s\n' "$triage_target" | jq -r '.path // empty')
  triage_source_repo=$(printf '%s\n' "$triage_target" | jq -r '.repo_full_name')
  triage_pin_sha=
  triage_pin_path=
  if [ -n "$triage_pin" ]; then
    triage_pin_sha=$(printf '%s\n' "$triage_pin" | jq -r '.sha')
    triage_pin_path=$(printf '%s\n' "$triage_pin" | jq -r '.path // empty')
  fi
  if [ -n "$triage_pin_path" ]; then
    triage_source_path=$triage_pin_path
  fi
  rm -rf "$triage_clone_dir"
  if [ -n "$triage_source_path" ]; then
    git clone --filter=blob:none --no-hardlinks "$triage_source_path" \
      "$triage_clone_dir" >/dev/null 2>&1 || return 1
  else
    git clone --filter=blob:none "https://github.com/$triage_source_repo.git" \
      "$triage_clone_dir" >/dev/null 2>&1 || return 1
  fi
  if [ -n "$triage_pin_sha" ]; then
    git -C "$triage_clone_dir" checkout --quiet "$triage_pin_sha" || return 1
  fi
  triage_head_sha=$(git -C "$triage_clone_dir" rev-parse HEAD) || return 1
  jq -n -c \
    --arg ledger_repo "$triage_repo" \
    --arg repo_full_name "$triage_source_repo" \
    --arg clone_dir "$triage_clone_dir" \
    --arg head_sha "$triage_head_sha" \
    --arg source_path "$triage_source_path" \
    '{
      ledger_repo: $ledger_repo,
      repo_full_name: $repo_full_name,
      clone_dir: $clone_dir,
      head_sha: $head_sha
    } + (if $source_path == "" then {} else {source_path: $source_path} end)'
}

triage_normalize_key() {
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'
}

triage_findings_for_repo() {
  triage_repo=$1
  triage_projection=$(triage_projection_file)
  jq -c --arg repo "$triage_repo" '
    select(
      .repo == $repo and
      ((.kind // "") | startswith("org-consistency/") | not)
    )
  ' "$triage_projection"
}

triage_open_findings_for_repo() {
  triage_repo=$1
  triage_projection=$(triage_projection_file)
  jq -c --arg repo "$triage_repo" '
    select(
      .repo == $repo and
      .current_status == "open" and
      ((.kind // "") | startswith("org-consistency/") | not)
    )
  ' "$triage_projection"
}

triage_target_repos_present() {
  triage_projection=$(triage_projection_file)
  jq -r '.repo' "$triage_projection" | LC_ALL=C sort -u
}

triage_new_findings_for_repo() {
  triage_repo=$1
  triage_last_run=$(triage_last_run_completed_at)
  if [ -n "$triage_last_run" ]; then
    jq -c --arg repo "$triage_repo" --arg last_run "$triage_last_run" '
      select(.repo == $repo and .current_status == "open" and .ts > $last_run)
    ' "$(triage_projection_file)"
  else
    triage_open_findings_for_repo "$triage_repo"
  fi
}

triage_dedup_carryover_state_file() {
  printf '%s\n' "$STATE_DIR/triage/state/dedup-carryover.jsonl"
}

triage_dedup_carryover_next_file() {
  printf '%s\n' "$TRIAGE_WORK_DIR/dedup-carryover.next.jsonl"
}

triage_prepare_dedup_carryover() {
  triage_carry_state=$(triage_dedup_carryover_state_file)
  triage_carry_input="$TRIAGE_WORK_DIR/dedup-carryover.previous.jsonl"
  triage_carry_next=$(triage_dedup_carryover_next_file)
  triage_carry_valid=true
  if [ -f "$triage_carry_state" ]; then
    if jq -e -s 'all(.[]; type == "string" and length > 0)' \
      "$triage_carry_state" >/dev/null 2>&1; then
      cp "$triage_carry_state" "$triage_carry_input"
    else
      triage_carry_valid=false
      : > "$triage_carry_input"
    fi
  else
    : > "$triage_carry_input"
  fi
  triage_last_run=$(triage_last_run_completed_at)
  if [ "$triage_carry_valid" = true ]; then
    jq -c --arg last_run "$triage_last_run" \
      --slurpfile carry "$triage_carry_input" '
        .id as $id |
        select(
          .current_status == "open" and
          ((.kind // "") | startswith("org-consistency/") | not) and
          ($last_run == "" or .ts > $last_run or
            (($carry | index($id)) != null))
        ) |
        $id
      ' "$(triage_projection_file)" | LC_ALL=C sort -u > "$triage_carry_next"
  else
    jq -c '
      select(
        .current_status == "open" and
        ((.kind // "") | startswith("org-consistency/") | not)
      ) | .id
    ' \
      "$(triage_projection_file)" | LC_ALL=C sort -u > "$triage_carry_next"
  fi
}

triage_dedup_candidates_for_repo() {
  triage_repo=$1
  jq -c --arg repo "$triage_repo" \
    --slurpfile carry "$(triage_dedup_carryover_next_file)" '
      .id as $id |
      select(
        .repo == $repo and .current_status == "open" and
        (($carry | index($id)) != null)
      )
    ' "$(triage_projection_file)"
}

triage_remove_completed_dedup_ids() {
  triage_completed_file=$1
  triage_carry_next=$(triage_dedup_carryover_next_file)
  triage_carry_tmp="$TRIAGE_WORK_DIR/dedup-carryover.next.tmp"
  jq -c -s --slurpfile completed "$triage_completed_file" '
    .[] as $id |
    select(($completed | index($id)) == null) |
    $id
  ' "$triage_carry_next" > "$triage_carry_tmp"
  mv "$triage_carry_tmp" "$triage_carry_next"
}

triage_publish_dedup_carryover() {
  triage_atomic_publish_file "$(triage_dedup_carryover_next_file)" \
    "$(triage_dedup_carryover_state_file)"
}

triage_verify_candidates_for_repo() {
  triage_repo=$1
  triage_recent_days=$TRIAGE_REVERIFY_INTERVAL_DAYS
  triage_cutoff=$(( $(date -u '+%s') - (triage_recent_days * 86400) ))
  while IFS= read -r triage_line || [ -n "$triage_line" ]; do
    [ -n "$triage_line" ] || continue
    triage_finding_id=$(printf '%s\n' "$triage_line" | jq -r '.id')
    triage_last_verified=$(triage_verified_at_for "$triage_finding_id")
    if [ -n "$triage_last_verified" ]; then
      triage_last_verified_epoch=$(triage_iso_to_epoch "$triage_last_verified") || triage_last_verified_epoch=0
      if [ "$triage_last_verified_epoch" -ge "$triage_cutoff" ]; then
        triage_stats_increment verify_skipped_recent 1
        continue
      fi
    fi
    printf '%s\n' "$triage_line"
  done <<EOF
$(triage_open_findings_for_repo "$triage_repo")
EOF
}

triage_chunk_jsonl() {
  triage_input_file=$1
  triage_chunk_size=$2
  triage_output_dir=$3
  mkdir -p "$triage_output_dir"
  triage_chunk_index=0
  triage_chunk_lines=0
  triage_chunk_file=
  while IFS= read -r triage_line || [ -n "$triage_line" ]; do
    [ -n "$triage_line" ] || continue
    if [ $((triage_chunk_lines % triage_chunk_size)) -eq 0 ]; then
      triage_chunk_index=$((triage_chunk_index + 1))
      triage_chunk_file="$triage_output_dir/chunk-$triage_chunk_index.jsonl"
      : > "$triage_chunk_file"
    fi
    printf '%s\n' "$triage_line" >> "$triage_chunk_file"
    triage_chunk_lines=$((triage_chunk_lines + 1))
  done < "$triage_input_file"
}

triage_template_render() {
  triage_template=$1
  shift
  triage_output=$1
  shift
  triage_template_keys=()
  triage_template_values=()
  triage_template_count=0
  while [ "$#" -gt 0 ]; do
    triage_template_keys[triage_template_count]=$1
    triage_template_values[triage_template_count]=$2
    triage_template_count=$((triage_template_count + 1))
    shift 2
  done
  : > "$triage_output"
  while IFS= read -r triage_template_line || [ -n "$triage_template_line" ]; do
    triage_template_index=0
    while [ "$triage_template_index" -lt "$triage_template_count" ]; do
      triage_key=${triage_template_keys[$triage_template_index]}
      triage_value=${triage_template_values[$triage_template_index]}
      triage_template_line=${triage_template_line//"$triage_key"/"$triage_value"}
      triage_template_index=$((triage_template_index + 1))
    done
    printf '%s\n' "$triage_template_line" >> "$triage_output"
  done < "$triage_template"
}

triage_prompt_hash() {
  shasum -a 256 "$1" | awk '{print $1}'
}

triage_cache_dir() {
  printf '%s\n' "${TRIAGE_LLM_CACHE_DIR:-$TRIAGE_WORK_DIR/cache}"
}

triage_adapter_run() {
  triage_stage=$1
  triage_prompt_file=$2
  triage_workdir=$3
  triage_out_dir=$4
  mkdir -p "$triage_out_dir"
  triage_response_file="$triage_out_dir/response.txt"
  triage_candidates_file="$triage_out_dir/candidates.jsonl"
  triage_prompt_hash_value=$(triage_prompt_hash "$triage_prompt_file")
  triage_adapter_timeout=${TRIAGE_LLM_TIMEOUT_SEC:-300}
  triage_cache_base=$(triage_cache_dir)
  mkdir -p "$triage_cache_base" || return 1
  triage_cache_root="$triage_cache_base/$triage_stage-$triage_prompt_hash_value"
  triage_cache_candidates="$triage_cache_root.jsonl"
  triage_cache_meta="$triage_cache_root.meta.json"
  if [ -f "$triage_cache_candidates" ]; then
    cp "$triage_cache_candidates" "$triage_candidates_file"
    printf '%s\n' "cache-hit:$triage_stage:$triage_prompt_hash_value" > "$triage_response_file"
    jq -n -c \
      --arg stage "$triage_stage" \
      --arg prompt_hash "$triage_prompt_hash_value" \
      --arg adapter "$TRIAGE_ADAPTER" \
      --arg cached_at "$(nightshift_iso_now)" \
      --arg source "cache" \
      '{stage: $stage, prompt_hash: $prompt_hash, adapter: $adapter, cached_at: $cached_at, source: $source}' \
      > "$triage_cache_meta" 2>/dev/null || true
    printf '%s\n' "$triage_candidates_file"
    return 0
  fi

  "$TRIAGE_ADAPTER" \
    "$triage_prompt_file" "$triage_workdir" "$triage_out_dir" \
    > "$triage_response_file" 2>&1 &
  triage_adapter_pid=$!
  triage_adapter_started=$(date '+%s')
  while kill -0 "$triage_adapter_pid" 2>/dev/null; do
    triage_adapter_now=$(date '+%s')
    if [ $((triage_adapter_now - triage_adapter_started)) -ge \
      "$triage_adapter_timeout" ]; then
      kill -TERM "$triage_adapter_pid" 2>/dev/null || true
      wait "$triage_adapter_pid" 2>/dev/null || true
      return 1
    fi
    sleep 1
  done
  wait "$triage_adapter_pid" || return 1
  if [ ! -f "$triage_candidates_file" ]; then
    cp "$triage_response_file" "$triage_candidates_file"
  fi
  cp "$triage_candidates_file" "$triage_cache_candidates"
  jq -n -c \
    --arg stage "$triage_stage" \
    --arg prompt_hash "$triage_prompt_hash_value" \
    --arg adapter "$TRIAGE_ADAPTER" \
    --arg cached_at "$(nightshift_iso_now)" \
    --arg source "fresh" \
    '{stage: $stage, prompt_hash: $prompt_hash, adapter: $adapter, cached_at: $cached_at, source: $source}' \
    > "$triage_cache_meta"
  printf '%s\n' "$triage_candidates_file"
}

triage_adapter_jobs_wait() {
  triage_jobs_file=$1
  while IFS= read -r triage_job_pid || [ -n "$triage_job_pid" ]; do
    [ -n "$triage_job_pid" ] || continue
    wait "$triage_job_pid" || true
  done < "$triage_jobs_file"
  : > "$triage_jobs_file"
}

triage_adapter_job_launch() {
  triage_job_stage=$1
  triage_job_prompt=$2
  triage_job_workdir=$3
  triage_job_out_dir=$4
  triage_job_result=$5
  triage_jobs_file=$6
  (
    if ! triage_adapter_run "$triage_job_stage" "$triage_job_prompt" \
      "$triage_job_workdir" "$triage_job_out_dir" > "$triage_job_result"; then
      : > "$triage_job_result"
    fi
  ) &
  printf '%s\n' "$!" >> "$triage_jobs_file"
  triage_job_count=$(wc -l < "$triage_jobs_file" | tr -d ' ')
  if [ "$triage_job_count" -ge "$TRIAGE_CONCURRENCY" ]; then
    triage_adapter_jobs_wait "$triage_jobs_file"
  fi
}

triage_validate_verify_line() {
  jq -e -S -c '
    def text($min; $max):
      type == "string" and length >= $min and length <= $max and
      (test("[\u0000-\u001F\u007F]") | not);
    select(
      type == "object" and
      ((keys_unsorted - ["finding_id","verdict","file","line","quoted_line","removed_pattern","explanation"]) | length == 0) and
      (.finding_id | text(1; 300)) and
      (.verdict == "CONFIRMED_CURRENT" or .verdict == "ALREADY_FIXED" or .verdict == "NOT_REPRODUCIBLE" or .verdict == "UNCLEAR") and
      (.file | text(1; 500)) and
      (.line | type == "number" and floor == . and . > 0) and
      (.quoted_line | text(1; 2000)) and
      (.explanation | text(1; 1000)) and
      (if .verdict == "ALREADY_FIXED" then
        (.removed_pattern | text(1; 500))
      else
        (has("removed_pattern") and
          (.removed_pattern | type == "string" and length <= 500 and
            (test("[\u0000-\u001F\u007F]") | not)))
      end)
    )
  '
}

triage_validate_dedup_line() {
  jq -e -S -c '
    def text($max): type == "string" and length > 0 and length <= $max and
      (test("[\u0000-\u001F\u007F]") | not);
    select(
      type == "object" and
      ((keys_unsorted - ["finding_id","verdict","canonical_id","confidence","shared_defect"]) | length == 0) and
      (.finding_id | text(300)) and
      (.verdict == "DUPLICATE" or .verdict == "DISTINCT") and
      (.confidence == "high" or .confidence == "medium" or .confidence == "low") and
      (if .verdict == "DUPLICATE" then
        (.canonical_id | text(300)) and
        (.shared_defect | text(1000))
      else
        (has("canonical_id") | not) and
        ((has("shared_defect") | not) or (.shared_defect | text(1000)))
      end)
    )
  '
}

triage_resolve_path_in_clone() {
  triage_clone_root=$1
  triage_rel=$2
  triage_safe_relative_path "$triage_rel" || return 1
  triage_clone_real=$(cd "$triage_clone_root" 2>/dev/null && pwd -P) || return 1
  triage_dir=$(dirname "$triage_rel")
  triage_base=$(basename "$triage_rel")
  triage_abs_dir=$(cd "$triage_clone_real/$triage_dir" 2>/dev/null && pwd -P) || return 1
  case "$triage_abs_dir" in
    "$triage_clone_real"|"$triage_clone_real"/*) ;;
    *) return 1 ;;
  esac
  [ -L "$triage_clone_real/$triage_rel" ] && return 1
  [ -f "$triage_clone_real/$triage_rel" ] || return 1
  printf '%s/%s\n' "$triage_abs_dir" "$triage_base"
}

triage_whitespace_normalize() {
  printf '%s\n' "$1" | awk '{$1=$1; print}'
}

triage_sanitize_anchor() {
  printf '%s\n' "$1" | tr -d '\r\n\t|`' |
    awk '{$1=$1; print substr($0,1,60)}'
}

triage_removed_pattern_absent() {
  triage_pattern=$1
  triage_file=$2
  triage_grep_rc=0
  grep -E -- "$triage_pattern" "$triage_file" >/dev/null 2>&1 ||
    triage_grep_rc=$?
  case "$triage_grep_rc" in
    0) return 1 ;;
    1) return 0 ;;
    *) return 1 ;;
  esac
}

triage_evidence_gate_already_fixed() {
  triage_finding_json=$1
  triage_result_json=$2
  triage_clone_root=$3
  triage_head_sha=$4
  triage_reason_file=$5

  triage_rel_file=$(printf '%s\n' "$triage_result_json" | jq -r '.file')
  triage_abs_file=$(triage_resolve_path_in_clone "$triage_clone_root" "$triage_rel_file") || return 1
  triage_line=$(printf '%s\n' "$triage_result_json" | jq -r '.line')
  triage_quoted=$(printf '%s\n' "$triage_result_json" | jq -r '.quoted_line')
  triage_removed=$(printf '%s\n' "$triage_result_json" | jq -r '.removed_pattern // empty')
  triage_explanation=$(printf '%s\n' "$triage_result_json" | jq -r '.explanation')
  triage_target=$(printf '%s\n' "$triage_finding_json" | jq -r '.target')
  triage_date=$(printf '%s\n' "$triage_finding_json" | jq -r '.date')

  case "$triage_target" in
    *'*'*|*'?'*|*'['*) return 1 ;;
  esac
  triage_target_file=$triage_target
  if triage_target_abs=$(triage_resolve_path_in_clone \
    "$triage_clone_root" "$triage_target_file" 2>/dev/null); then
    :
  else
    triage_target_file=${triage_target%%:*}
    if [ "$triage_target_file" != "$triage_target" ] &&
      triage_target_abs=$(triage_resolve_path_in_clone \
        "$triage_clone_root" "$triage_target_file" 2>/dev/null); then
      :
    else
      case "$triage_target" in
        *+*|*';'*) return 1 ;;
      esac
      return 1
    fi
  fi
  [ "$triage_target_abs" = "$triage_abs_file" ] || return 1
  [ "$triage_target_file" = "$triage_rel_file" ] || return 1

  triage_line_count=$(wc -l < "$triage_abs_file" | tr -d ' ')
  [ "$triage_line" -le "$triage_line_count" ] || return 1
  triage_actual_line=$(sed -n "${triage_line}p" "$triage_abs_file")
  triage_actual_norm=$(triage_whitespace_normalize "$triage_actual_line")
  triage_expected_norm=$(triage_whitespace_normalize "$triage_quoted")
  [ "$triage_actual_norm" = "$triage_expected_norm" ] || return 1
  [ "${#triage_expected_norm}" -ge 20 ] || return 1
  printf '%s\n' "$triage_expected_norm" | grep '[[:alnum:]]' >/dev/null 2>&1 || return 1

  triage_window_start=$((triage_line - 3))
  triage_window_end=$((triage_line + 3))
  [ "$triage_window_start" -lt 1 ] && triage_window_start=1
  triage_matches=$(awk -v start="$triage_window_start" -v end="$triage_window_end" -v expected="$triage_expected_norm" '
    NR >= start && NR <= end {
      line=$0
      gsub(/[[:space:]]+/, " ", line)
      sub(/^ /, "", line)
      sub(/ $/, "", line)
      if (line == expected) { count++ }
    }
    END { print count + 0 }
  ' "$triage_abs_file")
  [ "$triage_matches" -eq 1 ] || return 1

  triage_removed_norm=$(triage_whitespace_normalize "$triage_removed")
  [ "${#triage_removed_norm}" -ge 8 ] || return 1
  triage_removed_pattern_absent "$triage_removed" "$triage_abs_file" || return 1
  git -C "$triage_clone_root" log --since="$triage_date" -- "$triage_rel_file" | grep . >/dev/null 2>&1 || return 1
  triage_anchor="$triage_rel_file:$triage_line"
  printf '%s\n' "$triage_explanation" | tr '\r\n\t|`' '     ' |
    awk '{$1=$1; print substr($0,1,200)}' > "$triage_reason_file.explanation"
  triage_sanitized_explanation=$(sed -n '1p' "$triage_reason_file.explanation")
  printf 'already fixed on main %s: %s (%s); not a false positive\n' \
    "$triage_head_sha" \
    "$triage_sanitized_explanation" \
    "$triage_anchor" > "$triage_reason_file"
}

triage_reason_prefix_class() {
  triage_reason=$1
  case "$triage_reason" in
    already\ fixed\ on\ main*) printf '%s\n' fixed ;;
    deferred*) printf '%s\n' deferred ;;
    duplicate\ of*|duplicate/absorbed*) printf '%s\n' duplicate ;;
    *) printf '%s\n' other ;;
  esac
}

triage_resolve_reference_id() {
  triage_reason=$1
  triage_ids_file=$2
  triage_full_ids=$(printf '%s\n' "$triage_reason" | grep -Eo 'rv-[a-z0-9-]+' | LC_ALL=C sort -u || true)
  triage_full_count=$(printf '%s\n' "$triage_full_ids" | sed '/^$/d' | wc -l | tr -d ' ')
  if [ "$triage_full_count" -eq 1 ]; then
    triage_candidate=$(printf '%s\n' "$triage_full_ids" | sed -n '1p')
    grep -F -x -- "$triage_candidate" "$triage_ids_file" >/dev/null 2>&1 || return 1
    printf '%s\n' "$triage_candidate"
    return 0
  fi
  [ "$triage_full_count" -eq 0 ] || return 1

  triage_suffixes=$(printf '%s\n' "$triage_reason" | grep -Eo '[0-9a-f]{8}' | LC_ALL=C sort -u || true)
  triage_suffix_count=$(printf '%s\n' "$triage_suffixes" | sed '/^$/d' | wc -l | tr -d ' ')
  [ "$triage_suffix_count" -eq 1 ] || return 1
  triage_suffix=$(printf '%s\n' "$triage_suffixes" | sed -n '1p')
  triage_matches=$(awk -v suffix="$triage_suffix" 'substr($0, length($0)-7) == suffix { print }' "$triage_ids_file")
  triage_match_count=$(printf '%s\n' "$triage_matches" | sed '/^$/d' | wc -l | tr -d ' ')
  [ "$triage_match_count" -eq 1 ] || return 1
  printf '%s\n' "$triage_matches" | sed -n '1p'
}

triage_current_ids_file() {
  printf '%s\n' "$TRIAGE_WORK_DIR/current-ids.txt"
}

triage_build_current_ids() {
  jq -r '.id' "$(triage_projection_file)" > "$(triage_current_ids_file)"
}

triage_resolve_canonical_root() {
  triage_finding_id=$1
  triage_projection_file_path=$2
  triage_ids_file=$3
  triage_depth=${4:-0}
  [ "$triage_depth" -lt 10 ] || return 1
  triage_current=$(jq -e -c --arg id "$triage_finding_id" 'select(.id == $id)' "$triage_projection_file_path") || return 1
  triage_status=$(printf '%s\n' "$triage_current" | jq -r '.current_status')
  if [ "$triage_status" != rejected ]; then
    jq -n -c \
      --arg root_id "$triage_finding_id" \
      --arg status "$triage_status" \
      '{root_id: $root_id, status: $status}'
    return 0
  fi
  triage_reason=$(printf '%s\n' "$triage_current" | jq -r '.latest_verdict.rejection_reason // empty')
  [ -n "$triage_reason" ] || return 1
  triage_class=$(triage_reason_prefix_class "$triage_reason")
  if [ "$triage_class" = duplicate ]; then
    triage_ref=$(triage_resolve_reference_id "$triage_reason" "$triage_ids_file") || return 1
    [ "$triage_ref" != "$triage_finding_id" ] || return 1
    triage_root=$(triage_resolve_canonical_root "$triage_ref" "$triage_projection_file_path" "$triage_ids_file" $((triage_depth + 1))) || return 1
    printf '%s\n' "$triage_root"
    return 0
  fi
  jq -n -c \
    --arg root_id "$triage_finding_id" \
    --arg status rejected \
    --arg cause "$triage_class" \
    '{root_id: $root_id, status: $status, cause: $cause}'
}

triage_dedup_exact_key() {
  printf '%s\n' "$1" | jq -r '
    [
      .repo,
      (.target | ascii_downcase | gsub("[[:space:]]+"; " ")),
      (.kind | ascii_downcase | gsub("[[:space:]]+"; " ")),
      (.symptom | ascii_downcase | gsub("[[:space:]]+"; " "))
    ] | join("|")
  '
}

triage_find_exact_duplicate_candidate() {
  triage_finding_json=$1
  triage_repo=$2
  triage_finding_id=$(printf '%s\n' "$triage_finding_json" | jq -r '.id')
  triage_key=$(triage_dedup_exact_key "$triage_finding_json")
  while IFS= read -r triage_candidate || [ -n "$triage_candidate" ]; do
    [ -n "$triage_candidate" ] || continue
    triage_candidate_id=$(printf '%s\n' "$triage_candidate" | jq -r '.id')
    [ "$triage_candidate_id" = "$triage_finding_id" ] && continue
    if [ "$(triage_dedup_exact_key "$triage_candidate")" = "$triage_key" ]; then
      printf '%s\n' "$triage_candidate_id"
      return 0
    fi
  done <<EOF
$(triage_findings_for_repo "$triage_repo")
EOF
  return 1
}

triage_top_pool_for_finding() {
  triage_finding_json=$1
  triage_repo=$2
  triage_finding_id=$(printf '%s\n' "$triage_finding_json" | jq -r '.id')
  triage_symptom=$(printf '%s\n' "$triage_finding_json" | jq -r '.symptom')
  triage_interpretation=$(printf '%s\n' "$triage_finding_json" | jq -r '.interpretation // ""')
  triage_terms=$(triage_normalize_key "$triage_symptom $triage_interpretation")
  while IFS= read -r triage_candidate || [ -n "$triage_candidate" ]; do
    [ -n "$triage_candidate" ] || continue
    [ "$(printf '%s\n' "$triage_candidate" | jq -r '.id')" != "$triage_finding_id" ] || continue
    triage_score=$(printf '%s\n' "$triage_candidate" | jq -r --arg terms "$triage_terms" '
      [.symptom, (.interpretation // "")] | join(" ") | ascii_downcase as $text |
      ($terms | split(" ")) as $parts |
      reduce $parts[] as $part (0; if $part != "" and ($text | contains($part)) then . + 1 else . end)
    ')
    printf '%s\t%s\n' "$triage_score" "$triage_candidate"
  done <<EOF
$(triage_findings_for_repo "$triage_repo")
EOF
}

triage_render_dedup_prompt() {
  local triage_render_candidates_file=$1
  local triage_render_chunk_file=$2
  local triage_render_output=$3
  local triage_pool_text
  local triage_findings_text
  triage_pool_text=$(awk -F'\t' '{print $2}' "$triage_render_candidates_file" |
    jq -s '.')
  triage_findings_text=$(jq -s '.' "$triage_render_chunk_file")
  triage_template_render \
    "$REPO_ROOT/templates/triage-dedup.tmpl.md" \
    "$triage_render_output" \
    '{{CANONICAL_POOL}}' "$triage_pool_text" \
    '{{FINDINGS_BLOCK}}' "$triage_findings_text"
}

triage_render_verify_prompt() {
  local triage_render_chunk_file=$1
  local triage_render_output=$2
  local triage_findings_text
  triage_findings_text=$(jq -s '.' "$triage_render_chunk_file")
  triage_template_render \
    "$REPO_ROOT/templates/triage-verify.tmpl.md" \
    "$triage_render_output" \
    '{{FINDINGS_BLOCK}}' "$triage_findings_text"
}

triage_process_dedup_repo() {
  triage_repo=$1
  triage_clone_json=$2
  triage_repo_dir="$TRIAGE_WORK_DIR/dedup/$triage_repo"
  mkdir -p "$triage_repo_dir"
  triage_new_file="$triage_repo_dir/new-findings.jsonl"
  triage_candidate_meta_file="$triage_repo_dir/candidates.jsonl"
  triage_llm_results="$triage_repo_dir/results.jsonl"
  triage_final_results="$triage_repo_dir/final.jsonl"
  triage_completed_ids="$triage_repo_dir/completed-ids.jsonl"
  : > "$triage_completed_ids"
  triage_dedup_candidates_for_repo "$triage_repo" | sort > "$triage_new_file" || true
  triage_new_total=$(wc -l < "$triage_new_file" | tr -d ' ')
  triage_stats_increment new_findings_total "$triage_new_total"
  if [ "$triage_new_total" -gt "$TRIAGE_MAX_NEW_FOR_DEDUP" ]; then
    if [ "$TRIAGE_MAX_NEW_FOR_DEDUP" -eq 0 ]; then
      : > "$triage_new_file.limited"
    else
      head -n "$TRIAGE_MAX_NEW_FOR_DEDUP" "$triage_new_file" > "$triage_new_file.limited"
    fi
    mv "$triage_new_file.limited" "$triage_new_file"
    triage_stats_increment new_findings_carried $((triage_new_total - TRIAGE_MAX_NEW_FOR_DEDUP))
  fi
  triage_processed=$(wc -l < "$triage_new_file" | tr -d ' ')
  triage_stats_increment new_findings_processed "$triage_processed"
  : > "$triage_candidate_meta_file"
  : > "$triage_llm_results"
  : > "$triage_final_results"

  while IFS= read -r triage_finding || [ -n "$triage_finding" ]; do
    [ -n "$triage_finding" ] || continue
    triage_finding_id=$(printf '%s\n' "$triage_finding" | jq -r '.id')
    if triage_exact_id=$(triage_find_exact_duplicate_candidate "$triage_finding" "$triage_repo" 2>/dev/null); then
      jq -n -c \
        --arg finding_id "$triage_finding_id" \
        --arg canonical_id "$triage_exact_id" \
        '{finding_id: $finding_id, verdict: "DUPLICATE", canonical_id: $canonical_id, confidence: "high", shared_defect: "exact normalized finding match"}' \
        >> "$triage_final_results"
      printf '%s\n' "$triage_finding_id" | jq -R . >> "$triage_completed_ids"
      continue
    fi

    triage_pool_file="$triage_repo_dir/pool-$triage_finding_id.tsv"
    triage_pool_all="$triage_pool_file.all"
    triage_top_pool_for_finding "$triage_finding" "$triage_repo" |
      LC_ALL=C sort -r -n -k1,1 > "$triage_pool_all" || true
    triage_pool_count=$(wc -l < "$triage_pool_all" | tr -d ' ')
    if [ "$triage_pool_count" -gt "$TRIAGE_DEDUP_POOL_MAX" ]; then
      head -n 20 "$triage_pool_all" > "$triage_pool_file"
      triage_stats_increment dedup_pool_shrunk 1
    else
      mv "$triage_pool_all" "$triage_pool_file"
    fi
    rm -f "$triage_pool_all"
    if [ ! -s "$triage_pool_file" ]; then
      triage_stats_increment dedup_pool_empty 1
      printf '%s\n' "$triage_finding_id" | jq -R . >> "$triage_completed_ids"
      continue
    fi
    jq -n -c --arg finding_id "$triage_finding_id" --arg pool_file "$triage_pool_file" '{finding_id: $finding_id, pool_file: $pool_file}' >> "$triage_candidate_meta_file"
  done < "$triage_new_file"

  triage_llm_input="$triage_repo_dir/llm-input.jsonl"
  jq -c --slurpfile new "$triage_new_file" '
    . as $meta |
    $new[] | select(.id == $meta.finding_id)
  ' "$triage_candidate_meta_file" > "$triage_llm_input" 2>/dev/null || true
  if [ -s "$triage_llm_input" ]; then
    triage_chunks="$triage_repo_dir/chunks"
    triage_chunk_jsonl "$triage_llm_input" "$TRIAGE_DEDUP_BATCH" "$triage_chunks"
    triage_jobs_file="$triage_repo_dir/adapter-jobs.txt"
    triage_scheduled_file="$triage_repo_dir/adapter-scheduled.tsv"
    : > "$triage_jobs_file"
    : > "$triage_scheduled_file"
    for triage_chunk in "$triage_chunks"/chunk-*.jsonl; do
      [ -f "$triage_chunk" ] || continue
      if ! triage_phase_budget_available; then
        triage_stats_increment phase_deadline_count 1
        triage_stats_increment closure_incomplete_count 1
        break
      fi
      triage_pool_file="$triage_chunk.pool.tsv"
      : > "$triage_pool_file"
      while IFS= read -r triage_batch_id || [ -n "$triage_batch_id" ]; do
        [ -n "$triage_batch_id" ] || continue
        triage_batch_pool=$(jq -r --arg finding_id "$triage_batch_id" \
          'select(.finding_id == $finding_id) | .pool_file' \
          "$triage_candidate_meta_file" | sed -n '1p')
        [ -n "$triage_batch_pool" ] && [ -f "$triage_batch_pool" ] || continue
        cat "$triage_batch_pool" >> "$triage_pool_file"
      done <<EOF
$(jq -r '.id' "$triage_chunk")
EOF
      LC_ALL=C sort -u "$triage_pool_file" -o "$triage_pool_file"
      triage_prompt="$triage_chunk.prompt.md"
      triage_render_dedup_prompt "$triage_pool_file" "$triage_chunk" "$triage_prompt"
      triage_run_dir="$triage_repo_dir/adapter-$(basename "$triage_chunk" .jsonl)"
      triage_candidate_ref="$triage_run_dir/candidate-path.txt"
      mkdir -p "$triage_run_dir"
      triage_adapter_job_launch dedup "$triage_prompt" \
        "$(printf '%s\n' "$triage_clone_json" | jq -r '.clone_dir')" \
        "$triage_run_dir" "$triage_candidate_ref" "$triage_jobs_file"
      printf '%s\t%s\n' "$triage_chunk" "$triage_candidate_ref" >> "$triage_scheduled_file"
    done
    triage_adapter_jobs_wait "$triage_jobs_file"
    while IFS="$(printf '\t')" read -r triage_chunk triage_candidate_ref ||
      [ -n "$triage_chunk" ]; do
      [ -n "$triage_chunk" ] || continue
      triage_candidate_output=$(sed -n '1p' "$triage_candidate_ref")
      if [ -z "$triage_candidate_output" ] || [ ! -s "$triage_candidate_output" ]; then
        triage_stats_increment adapter_failures 1
        continue
      fi
      while IFS= read -r triage_line || [ -n "$triage_line" ]; do
        [ -n "$triage_line" ] || continue
        if triage_valid=$(printf '%s\n' "$triage_line" | triage_validate_dedup_line 2>/dev/null); then
          triage_valid_id=$(printf '%s\n' "$triage_valid" | jq -r '.finding_id')
          triage_valid_canonical=$(printf '%s\n' "$triage_valid" | jq -r '.canonical_id // empty')
          if ! jq -e --arg id "$triage_valid_id" \
            'select(.id == $id)' "$triage_new_file" >/dev/null 2>&1; then
            triage_stats_increment dedup_invalid_lines 1
            continue
          fi
          if [ -n "$triage_valid_canonical" ] &&
            ! jq -e --arg id "$triage_valid_canonical" --arg repo "$triage_repo" \
              'select(.id == $id and .repo == $repo)' \
              "$(triage_projection_file)" >/dev/null 2>&1; then
            triage_stats_increment dedup_invalid_lines 1
            continue
          fi
          if jq -e --arg id "$triage_valid_id" \
            'select(.finding_id == $id)' "$triage_llm_results" >/dev/null 2>&1; then
            triage_stats_increment dedup_invalid_lines 1
            continue
          fi
          printf '%s\n' "$triage_valid" >> "$triage_llm_results"
        else
          triage_stats_increment dedup_invalid_lines 1
        fi
      done < "$triage_candidate_output"
    done < "$triage_scheduled_file"
  fi
  cat "$triage_llm_results" >> "$triage_final_results"
  jq -c '.finding_id' "$triage_final_results" >> "$triage_completed_ids"
  LC_ALL=C sort -u "$triage_completed_ids" -o "$triage_completed_ids"
  triage_remove_completed_dedup_ids "$triage_completed_ids"
  printf '%s\n' "$triage_final_results"
}

triage_process_verify_repo() {
  triage_repo=$1
  triage_clone_json=$2
  triage_repo_dir="$TRIAGE_WORK_DIR/verify/$triage_repo"
  mkdir -p "$triage_repo_dir"
  triage_verify_file="$triage_repo_dir/verify-findings.jsonl"
  triage_results_file="$triage_repo_dir/results.jsonl"
  triage_validated_file="$triage_repo_dir/validated.jsonl"
  triage_updates_file="$triage_repo_dir/verified-updates.jsonl"
  triage_verify_candidates_for_repo "$triage_repo" |
    jq -s -c 'sort_by(.night_id, .ts, .id)[]' > "$triage_verify_file" || true
  triage_verify_total=$(wc -l < "$triage_verify_file" | tr -d ' ')
  triage_stats_increment verify_total "$triage_verify_total"
  if [ "$triage_verify_total" -gt "$TRIAGE_MAX_VERIFY_PER_RUN" ]; then
    if [ "$TRIAGE_MAX_VERIFY_PER_RUN" -eq 0 ]; then
      : > "$triage_verify_file.limited"
    else
      head -n "$TRIAGE_MAX_VERIFY_PER_RUN" "$triage_verify_file" > "$triage_verify_file.limited"
    fi
    mv "$triage_verify_file.limited" "$triage_verify_file"
    triage_stats_increment verify_carried $((triage_verify_total - TRIAGE_MAX_VERIFY_PER_RUN))
  fi
  triage_processed=$(wc -l < "$triage_verify_file" | tr -d ' ')
  triage_stats_increment verify_processed "$triage_processed"
  : > "$triage_results_file"
  : > "$triage_validated_file"
  : > "$triage_updates_file"
  if [ ! -s "$triage_verify_file" ]; then
    printf '%s\n' "$triage_validated_file"
    return 0
  fi

  triage_chunks="$triage_repo_dir/chunks"
  triage_chunk_jsonl "$triage_verify_file" "$TRIAGE_VERIFY_BATCH" "$triage_chunks"
  triage_jobs_file="$triage_repo_dir/adapter-jobs.txt"
  triage_scheduled_file="$triage_repo_dir/adapter-scheduled.tsv"
  : > "$triage_jobs_file"
  : > "$triage_scheduled_file"
  for triage_chunk in "$triage_chunks"/chunk-*.jsonl; do
    [ -f "$triage_chunk" ] || continue
    if ! triage_phase_budget_available; then
      triage_stats_increment phase_deadline_count 1
      break
    fi
    triage_prompt="$triage_chunk.prompt.md"
    triage_render_verify_prompt "$triage_chunk" "$triage_prompt"
    triage_run_dir="$triage_repo_dir/adapter-$(basename "$triage_chunk" .jsonl)"
    triage_candidate_ref="$triage_run_dir/candidate-path.txt"
    mkdir -p "$triage_run_dir"
    triage_adapter_job_launch verify "$triage_prompt" \
      "$(printf '%s\n' "$triage_clone_json" | jq -r '.clone_dir')" \
      "$triage_run_dir" "$triage_candidate_ref" "$triage_jobs_file"
    printf '%s\t%s\n' "$triage_chunk" "$triage_candidate_ref" >> "$triage_scheduled_file"
  done
  triage_adapter_jobs_wait "$triage_jobs_file"
  while IFS="$(printf '\t')" read -r triage_chunk triage_candidate_ref ||
    [ -n "$triage_chunk" ]; do
    [ -n "$triage_chunk" ] || continue
    triage_candidate_output=$(sed -n '1p' "$triage_candidate_ref")
    if [ -z "$triage_candidate_output" ] || [ ! -s "$triage_candidate_output" ]; then
      triage_stats_increment adapter_failures 1
      continue
    fi
    while IFS= read -r triage_line || [ -n "$triage_line" ]; do
      [ -n "$triage_line" ] || continue
      if triage_valid=$(printf '%s\n' "$triage_line" | triage_validate_verify_line 2>/dev/null); then
        triage_valid_id=$(printf '%s\n' "$triage_valid" | jq -r '.finding_id')
        if ! jq -e --arg id "$triage_valid_id" \
          'select(.id == $id)' "$triage_verify_file" >/dev/null 2>&1 ||
          jq -e --arg id "$triage_valid_id" \
            'select(.finding_id == $id)' "$triage_results_file" >/dev/null 2>&1; then
          triage_stats_increment verify_invalid_lines 1
          continue
        fi
        printf '%s\n' "$triage_valid" >> "$triage_results_file"
      else
        triage_stats_increment verify_invalid_lines 1
      fi
    done < "$triage_candidate_output"
  done < "$triage_scheduled_file"

  triage_clone_dir=$(printf '%s\n' "$triage_clone_json" | jq -r '.clone_dir')
  triage_head_sha=$(printf '%s\n' "$triage_clone_json" | jq -r '.head_sha')
  while IFS= read -r triage_line || [ -n "$triage_line" ]; do
    [ -n "$triage_line" ] || continue
    triage_finding_id=$(printf '%s\n' "$triage_line" | jq -r '.finding_id')
    triage_finding=$(jq -e -c --arg id "$triage_finding_id" 'select(.id == $id)' "$triage_verify_file")
    triage_verdict=$(printf '%s\n' "$triage_line" | jq -r '.verdict')
    triage_verified_at=$(nightshift_iso_now)
    if [ "$triage_verdict" = ALREADY_FIXED ]; then
      triage_reason_path="$triage_repo_dir/reason-$triage_finding_id.txt"
      if triage_evidence_gate_already_fixed "$triage_finding" "$triage_line" "$triage_clone_dir" "$triage_head_sha" "$triage_reason_path"; then
        jq -n -c \
          --arg finding_id "$triage_finding_id" \
          --arg verdict "$triage_verdict" \
          --arg reason "$(sed -n '1p' "$triage_reason_path")" \
          '{finding_id: $finding_id, verdict: $verdict, reason: $reason}' \
          >> "$triage_validated_file"
      fi
    else
      printf '%s\n' "$triage_line" | jq -c \
        --arg verified_at "$triage_verified_at" \
        '. + {verified_at: $verified_at}' >> "$triage_validated_file"
    fi
    jq -n -c \
      --arg finding_id "$triage_finding_id" \
      --arg verified_at "$triage_verified_at" \
      --arg verdict "$triage_verdict" \
      '{finding_id: $finding_id, verified_at: $verified_at, verdict: $verdict}' \
      >> "$triage_updates_file"
  done < "$triage_results_file"
  printf '%s\n' "$triage_validated_file"
}

triage_apply_verified_updates() {
  triage_all_updates="$TRIAGE_WORK_DIR/verified-updates.jsonl"
  : > "$triage_all_updates"
  for triage_updates_file in "$TRIAGE_WORK_DIR"/verify/*/verified-updates.jsonl; do
    [ -f "$triage_updates_file" ] || continue
    cat "$triage_updates_file" >> "$triage_all_updates"
  done
  triage_update_verified_at "$triage_all_updates"
}

triage_decisions_draft_file() {
  printf '%s\n' "$TRIAGE_WORK_DIR/decisions.draft.jsonl"
}

triage_decisions_final_file() {
  printf '%s\n' "$TRIAGE_WORK_DIR/decisions.jsonl"
}

triage_report_file() {
  printf '%s\n' "$TRIAGE_WORK_DIR/report.md"
}

triage_result_comment_file() {
  printf '%s\n' "$TRIAGE_WORK_DIR/result-comment.md"
}

triage_clusters_file() {
  printf '%s\n' "$TRIAGE_WORK_DIR/clusters.jsonl"
}

triage_verify_results_file() {
  printf '%s\n' "$TRIAGE_WORK_DIR/verify-results.jsonl"
}

triage_collect_machine_results() {
  triage_verify_all=$(triage_verify_results_file)
  : > "$triage_verify_all"
  for triage_machine_file in "$TRIAGE_WORK_DIR"/verify/*/validated.jsonl; do
    [ -f "$triage_machine_file" ] || continue
    cat "$triage_machine_file" >> "$triage_verify_all"
  done
}

triage_build_clusters() {
  triage_edges="$TRIAGE_WORK_DIR/cluster-edges.jsonl"
  triage_clusters=$(triage_clusters_file)
  : > "$triage_edges"
  : > "$triage_clusters"
  for triage_dedup_file in "$TRIAGE_WORK_DIR"/dedup/*/final.jsonl; do
    [ -f "$triage_dedup_file" ] || continue
    jq -c 'select(.verdict == "DUPLICATE" and .confidence == "high") |
      {member:.finding_id,canonical:.canonical_id}' \
      "$triage_dedup_file" >> "$triage_edges"
  done
  [ -s "$triage_edges" ] || return 0
  triage_closure_incomplete=$(jq -r '.closure_incomplete_count > 0' \
    "$(triage_stage_stats_file)")
  jq -n -c \
    --slurpfile projected "$(triage_projection_file)" \
    --slurpfile raw_edges "$triage_edges" \
    --argjson closure_incomplete "$triage_closure_incomplete" '
      ($projected | map({key:.id,value:.}) | from_entries) as $by_id |
      ($raw_edges | map(select(
        ($by_id[.member].current_status == "open") and
        (($by_id[.canonical].current_status == "open") or
          ($by_id[.canonical].current_status == "adopted")) and
        ($by_id[.member].repo == $by_id[.canonical].repo)
      ))) as $edges |
      ($edges | map(.member,.canonical) | flatten | unique) as $nodes |
      def component($seed):
        def grow($seen):
          ([$edges[] |
            select((.member as $m | $seen | index($m)) or
                   (.canonical as $c | $seen | index($c))) |
            .member,.canonical] + $seen | flatten | unique) as $next |
          if ($next|length) == ($seen|length) then $next else grow($next) end;
        grow([$seed]);
      reduce $nodes[] as $node
        ({seen:[],components:[]};
          if (.seen | index($node)) then .
          else (component($node)) as $component |
            .seen += $component | .components += [$component]
          end
        ) |
      .components[] |
      map($by_id[.]) as $rows |
      ($rows | map(select(.current_status == "adopted"))) as $adopted |
      ($rows | map(select(.current_status == "open")) |
        sort_by(.night_id,.ts,.id)) as $open |
      (if ($adopted|length) == 1 then $adopted[0].id
       elif ($adopted|length) == 0 and ($open|length) > 0 then $open[0].id
       else null end) as $canonical |
      {
        canonical_id:$canonical,
        members:($rows|map(.id)|sort),
        complete:(($canonical != null) and ($closure_incomplete|not)),
        rediscovery_count:(if $canonical == null then 0 else
          [$projected[] | select(
            .current_status == "rejected" and
            ((.latest_verdict.rejection_reason // "") as $reason |
              ($reason | startswith("duplicate of " + $canonical + " ")) or
              ($reason | startswith("duplicate of " + $canonical + "(")))
          )] | length end)
      }
    ' > "$triage_clusters"
}

triage_atomic_publish_file() {
  triage_publish_source=$1
  triage_publish_target=$2
  triage_publish_tmp="$STATE_DIR/triage/.publish.$$.${RANDOM:-0}"
  cp "$triage_publish_source" "$triage_publish_tmp" || return 1
  mv "$triage_publish_tmp" "$triage_publish_target"
}

triage_publish_artifacts() {
  triage_watermark=$1
  triage_publish_operational_state=${2:-true}
  triage_atomic_publish_file "$(triage_decisions_draft_file)" \
    "$STATE_DIR/triage/decisions.draft.jsonl" || return 1
  triage_atomic_publish_file "$(triage_report_file)" \
    "$STATE_DIR/triage/report.md" || return 1
  triage_atomic_publish_file "$(triage_clusters_file)" \
    "$STATE_DIR/triage/clusters.jsonl" || return 1
  triage_atomic_publish_file "$(triage_verify_results_file)" \
    "$STATE_DIR/triage/verify-results.jsonl" || return 1
  if [ "$triage_publish_operational_state" = true ]; then
    printf '%s\n' "$triage_watermark" > "$TRIAGE_WORK_DIR/last-run-watermark"
    triage_atomic_publish_file "$TRIAGE_WORK_DIR/last-run-watermark" \
      "$STATE_DIR/triage/last-run-watermark"
  fi
  triage_publish_verified_state
}

triage_publish_verified_state() {
  jq -r '.verified | to_entries[] |
    if (.value | type) == "object" then
      {finding_id:.key,last_verified_at:.value.last_verified_at,verdict:.value.verdict}
    else
      {finding_id:.key,last_verified_at:.value,verdict:"UNKNOWN"}
    end | @json' \
    "$(triage_state_file)" > "$TRIAGE_WORK_DIR/verified.jsonl"
  triage_atomic_publish_file "$TRIAGE_WORK_DIR/verified.jsonl" \
    "$STATE_DIR/triage/verified.jsonl"
}

triage_synthesize_decisions() {
  triage_watermark=$1
  triage_dedup_dir="$TRIAGE_WORK_DIR/dedup"
  triage_verify_dir="$TRIAGE_WORK_DIR/verify"
  triage_draft=$(triage_decisions_draft_file)
  triage_seen="$TRIAGE_WORK_DIR/decision-seen.txt"
  triage_branches="$TRIAGE_WORK_DIR/decision-branches.jsonl"
  : > "$triage_draft"
  : > "$triage_seen"
  : > "$triage_branches"
  for triage_repo_dir in "$triage_dedup_dir"/*; do
    [ -d "$triage_repo_dir" ] || continue
    triage_repo=$(basename "$triage_repo_dir")
    triage_dedup_file="$triage_repo_dir/final.jsonl"
    triage_verify_file="$triage_verify_dir/$triage_repo/validated.jsonl"
    triage_clone_json="$TRIAGE_WORK_DIR/clones/$triage_repo.json"
    [ -f "$triage_clone_json" ] || continue
    while IFS= read -r triage_line || [ -n "$triage_line" ]; do
      [ -n "$triage_line" ] || continue
      [ "$(printf '%s\n' "$triage_line" | jq -r '.verdict')" = DUPLICATE ] || continue
      [ "$(printf '%s\n' "$triage_line" | jq -r '.confidence')" = high ] || continue
      triage_finding_id=$(printf '%s\n' "$triage_line" | jq -r '.finding_id')
      triage_canonical_id=$(printf '%s\n' "$triage_line" | jq -r '.canonical_id')
      triage_finding_row=$(jq -e -c --arg id "$triage_finding_id" \
        'select(.id == $id and .current_status == "open")' \
        "$(triage_projection_file)" 2>/dev/null || true)
      triage_canonical_row=$(jq -e -c --arg id "$triage_canonical_id" \
        'select(.id == $id)' "$(triage_projection_file)" 2>/dev/null || true)
      [ -n "$triage_finding_row" ] && [ -n "$triage_canonical_row" ] || continue
      [ "$(printf '%s\n' "$triage_finding_row" | jq -r '.repo')" = \
        "$(printf '%s\n' "$triage_canonical_row" | jq -r '.repo')" ] || continue
      if grep -F -x -- "$triage_finding_id" "$triage_seen" >/dev/null 2>&1; then
        triage_stats_increment decision_deduped 1
        continue
      fi
      triage_root=$(triage_resolve_canonical_root "$triage_canonical_id" "$(triage_projection_file)" "$(triage_current_ids_file)" 0 2>/dev/null || true)
      [ -n "$triage_root" ] || continue
      triage_root_status=$(printf '%s\n' "$triage_root" | jq -r '.status')
      triage_root_id=$(printf '%s\n' "$triage_root" | jq -r '.root_id')
      triage_root_cause=$(printf '%s\n' "$triage_root" | jq -r '.cause // empty')
      if [ "$triage_root_status" = open ]; then
        triage_cluster_canonicals=$(jq -r --arg id "$triage_finding_id" '
          select(
            .complete == true and .canonical_id != null and
            (.members | index($id)) != null
          ) | .canonical_id
        ' "$(triage_clusters_file)" | LC_ALL=C sort -u)
        triage_cluster_count=$(printf '%s\n' "$triage_cluster_canonicals" |
          sed '/^$/d' | wc -l | tr -d ' ')
        if [ "$triage_cluster_count" -eq 1 ]; then
          triage_cluster_canonical=$(printf '%s\n' "$triage_cluster_canonicals" |
            sed -n '1p')
          triage_cluster_root=$(triage_resolve_canonical_root \
            "$triage_cluster_canonical" "$(triage_projection_file)" \
            "$(triage_current_ids_file)" 0 2>/dev/null || true)
          if [ -n "$triage_cluster_root" ] &&
            [ "$(printf '%s\n' "$triage_cluster_root" | jq -r '.status')" = adopted ]; then
            triage_canonical_id=$triage_cluster_canonical
            triage_root=$triage_cluster_root
            triage_root_status=adopted
            triage_root_id=$(printf '%s\n' "$triage_root" | jq -r '.root_id')
            triage_root_cause=$(printf '%s\n' "$triage_root" | jq -r '.cause // empty')
          fi
        fi
      fi
      triage_target=$(jq -r --arg id "$triage_finding_id" \
        'select(.id == $id) | .target' "$(triage_projection_file)")
      triage_anchor=$(triage_sanitize_anchor "$triage_target")
      triage_shared=$(printf '%s\n' "$triage_line" | jq -r '.shared_defect' |
        tr '\r\n\t|`' '     ' | awk '{$1=$1; print substr($0,1,200)}')
      case "$triage_root_status:$triage_root_cause" in
        adopted:*|rejected:deferred|rejected:other|rejected:duplicate)
          jq -n -c \
            --arg finding_id "$triage_finding_id" \
            --arg observed_at "$triage_watermark" \
            --arg status rejected \
            --arg actor "$TRIAGE_ACTOR" \
            --arg source manual-comment \
            --arg reason "duplicate of $triage_root_id ($triage_shared; evidence $triage_anchor$( [ "$triage_root_cause" = deferred ] && printf ', canonical is deferred, 起因 deferred' )$( [ "$triage_root_cause" = other ] && printf ', 起因 その他' )); not a false positive" \
            '{
              finding_id: $finding_id,
              status: $status,
              actor: $actor,
              source: $source,
              observed_at: $observed_at,
              rejection_reason: $reason
            }' >> "$triage_draft"
          printf '%s\n' "$triage_finding_id" >> "$triage_seen"
          jq -n -c \
            --arg finding_id "$triage_finding_id" \
            --arg canonical_id "$triage_canonical_id" \
            --arg root_id "$triage_root_id" \
            --arg root_status "$triage_root_status" \
            --arg root_cause "$triage_root_cause" \
            '{finding_id:$finding_id,canonical_id:$canonical_id,
              root_id:$root_id,root_status:$root_status,root_cause:$root_cause}' \
            >> "$triage_branches"
          ;;
        rejected:fixed|fixed:*)
          :
          ;;
        open:*)
          :
          ;;
      esac
    done < "$triage_dedup_file"

    if [ "$TRIAGE_ALREADY_FIXED_MODE" = reject ] && [ -f "$triage_verify_file" ]; then
      while IFS= read -r triage_line || [ -n "$triage_line" ]; do
        [ -n "$triage_line" ] || continue
        triage_verdict=$(printf '%s\n' "$triage_line" | jq -r '.verdict')
        [ "$triage_verdict" = ALREADY_FIXED ] || continue
        triage_finding_id=$(printf '%s\n' "$triage_line" | jq -r '.finding_id')
        if grep -F -x -- "$triage_finding_id" "$triage_seen" >/dev/null 2>&1; then
          continue
        fi
        jq -n -c \
          --arg finding_id "$triage_finding_id" \
          --arg status rejected \
          --arg actor "$TRIAGE_ACTOR" \
          --arg source manual-comment \
          --arg observed_at "$triage_watermark" \
          --arg reason "$(printf '%s\n' "$triage_line" | jq -r '.reason')" \
          '{
            finding_id: $finding_id,
            status: $status,
            actor: $actor,
            source: $source,
            observed_at: $observed_at,
            rejection_reason: $reason
          }' >> "$triage_draft"
        printf '%s\n' "$triage_finding_id" >> "$triage_seen"
      done < "$triage_verify_file"
    fi
  done
}

triage_revalidate_drafts() {
  triage_draft=$(triage_decisions_draft_file)
  triage_final="$TRIAGE_WORK_DIR/decisions.rechecked.jsonl"
  : > "$triage_final"
  triage_projection_snapshot
  triage_build_current_ids
  while IFS= read -r triage_line || [ -n "$triage_line" ]; do
    [ -n "$triage_line" ] || continue
    triage_finding_id=$(printf '%s\n' "$triage_line" | jq -r '.finding_id')
    triage_current=$(jq -e -c --arg id "$triage_finding_id" 'select(.id == $id)' "$(triage_projection_file)" 2>/dev/null || true)
    if [ -z "$triage_current" ] || [ "$(printf '%s\n' "$triage_current" | jq -r '.current_status')" != open ]; then
      triage_stats_increment decision_drops_target 1
      continue
    fi
    triage_reason=$(printf '%s\n' "$triage_line" | jq -r '.rejection_reason')
    case "$triage_reason" in
      duplicate\ of*)
        triage_branch=
        if [ -f "$TRIAGE_WORK_DIR/decision-branches.jsonl" ]; then
          triage_branch=$(jq -e -c --arg id "$triage_finding_id" \
            'select(.finding_id == $id)' "$TRIAGE_WORK_DIR/decision-branches.jsonl" \
            2>/dev/null || true)
        fi
        if [ -n "$triage_branch" ]; then
          triage_canonical_id=$(printf '%s\n' "$triage_branch" | jq -r '.canonical_id')
          triage_root=$(triage_resolve_canonical_root "$triage_canonical_id" \
            "$(triage_projection_file)" "$(triage_current_ids_file)" 0 \
            2>/dev/null || true)
          if [ -n "$triage_root" ] && printf '%s\n' "$triage_root" | jq -e \
            --arg root_id "$(printf '%s\n' "$triage_branch" | jq -r '.root_id')" \
            --arg status "$(printf '%s\n' "$triage_branch" | jq -r '.root_status')" \
            --arg cause "$(printf '%s\n' "$triage_branch" | jq -r '.root_cause')" '
              .root_id == $root_id and .status == $status and
              (.cause // "") == $cause and .status != "open"
            ' >/dev/null 2>&1; then
            :
          else
            triage_stats_increment decision_drops_canonical 1
            continue
          fi
        else
          triage_root_id=$(printf '%s\n' "$triage_reason" | sed -E 's/^duplicate of ([^ ]+).*/\1/')
          triage_root=$(triage_resolve_canonical_root "$triage_root_id" \
            "$(triage_projection_file)" "$(triage_current_ids_file)" 0 \
            2>/dev/null || true)
          if [ -z "$triage_root" ] || [ "$(printf '%s\n' "$triage_root" | jq -r '.status')" = open ]; then
            triage_stats_increment decision_drops_canonical 1
            continue
          fi
        fi
        ;;
    esac
    printf '%s\n' "$triage_line" >> "$triage_final"
  done < "$triage_draft"
  mv "$triage_final" "$triage_draft"
}

triage_report_nonce() {
  if [ -n "$TRIAGE_REPORT_NONCE" ]; then
    printf '%s\n' "$TRIAGE_REPORT_NONCE"
    return 0
  fi
  TRIAGE_REPORT_NONCE="run:$TRIAGE_RUN_ID:$(printf '%s' "$TRIAGE_RUN_ID" | shasum -a 256 | awk '{print substr($1,1,8)}')"
  printf '%s\n' "$TRIAGE_REPORT_NONCE"
}

triage_report_duplicate_class() {
  triage_wanted_class=$1
  for triage_class_file in "$TRIAGE_WORK_DIR"/dedup/*/final.jsonl; do
    [ -f "$triage_class_file" ] || continue
    while IFS= read -r triage_class_line || [ -n "$triage_class_line" ]; do
      [ -n "$triage_class_line" ] || continue
      triage_class_finding=$(printf '%s\n' "$triage_class_line" | jq -r '.finding_id')
      triage_class_canonical=$(printf '%s\n' "$triage_class_line" | jq -r '.canonical_id')
      triage_class_verify=$(jq -r --arg id "$triage_class_finding" \
        'select(.finding_id == $id) | .verdict' "$(triage_verify_results_file)" |
        sed -n '1p')
      triage_class_root=$(triage_resolve_canonical_root "$triage_class_canonical" \
        "$(triage_projection_file)" "$(triage_current_ids_file)" 0 \
        2>/dev/null || true)
      triage_class_actual=
      if [ -z "$triage_class_root" ]; then
        triage_class_actual=unresolved
      else
        triage_class_status=$(printf '%s\n' "$triage_class_root" | jq -r '.status')
        triage_class_cause=$(printf '%s\n' "$triage_class_root" | jq -r '.cause // empty')
        case "$triage_class_status:$triage_class_cause" in
          fixed:*|regression:*) triage_class_actual=regression ;;
          rejected:fixed)
            triage_class_actual=known-fixed
            if [ "$triage_wanted_class" = regression ] &&
              [ "$triage_class_verify" = CONFIRMED_CURRENT ]; then
              triage_class_actual=regression
            fi
            ;;
        esac
      fi
      [ "$triage_class_actual" = "$triage_wanted_class" ] || continue
      printf -- '- \140%s\140 → \140%s\140 (V=%s)\n' \
        "$triage_class_finding" "$triage_class_canonical" \
        "${triage_class_verify:-not-settled}"
    done < <(jq -c 'select(.verdict == "DUPLICATE" and .confidence == "high")' \
      "$triage_class_file")
  done
}

triage_report_fixed_evidence_failures() {
  for triage_raw_verify in "$TRIAGE_WORK_DIR"/verify/*/results.jsonl; do
    [ -f "$triage_raw_verify" ] || continue
    triage_valid_verify="$(dirname "$triage_raw_verify")/validated.jsonl"
    while IFS= read -r triage_raw_line || [ -n "$triage_raw_line" ]; do
      [ -n "$triage_raw_line" ] || continue
      triage_raw_id=$(printf '%s\n' "$triage_raw_line" | jq -r '.finding_id')
      if ! jq -e --arg id "$triage_raw_id" \
        'select(.finding_id == $id and .verdict == "ALREADY_FIXED")' \
        "$triage_valid_verify" >/dev/null 2>&1; then
        printf -- '- \140%s\140 — fixed 疑い・証拠不一致\n' "$triage_raw_id"
      fi
    done < <(jq -c 'select(.verdict == "ALREADY_FIXED")' "$triage_raw_verify")
  done
}

triage_render_report() {
  triage_watermark=$1
  triage_report=$(triage_report_file)
  triage_stats=$(cat "$(triage_stage_stats_file)")
  triage_branch_lines=
  for triage_clone_file in "$TRIAGE_WORK_DIR"/clones/*.json; do
    [ -f "$triage_clone_file" ] || continue
    triage_repo=$(jq -r '.ledger_repo' "$triage_clone_file")
    triage_full=$(jq -r '.repo_full_name' "$triage_clone_file")
    triage_sha=$(jq -r '.head_sha' "$triage_clone_file")
    triage_branch_lines="${triage_branch_lines}- ${triage_repo}: ${triage_full} @ ${triage_sha}\n"
  done
  triage_decision_count=$(wc -l < "$(triage_decisions_draft_file)" | tr -d ' ')
  triage_rediscovery=$(jq -s -r '[.[] | select(.current_status == "rejected" and
    ((.latest_verdict.rejection_reason // "") | startswith("duplicate of ")))] | length' \
    "$(triage_projection_file)" 2>/dev/null || printf '0')
  triage_report_decisions="$TRIAGE_WORK_DIR/report-decisions.jsonl"
  cp "$(triage_decisions_draft_file)" "$triage_report_decisions"
  triage_auto_rows=$(while IFS= read -r triage_report_decision || [ -n "$triage_report_decision" ]; do
    [ -n "$triage_report_decision" ] || continue
    triage_report_id=$(printf '%s\n' "$triage_report_decision" | jq -r '.finding_id')
    triage_report_reason=$(printf '%s\n' "$triage_report_decision" | jq -r '.rejection_reason' | tr '\r\n\t|' '    ' | cut -c1-240)
    triage_report_root=$(printf '%s\n' "$triage_report_reason" | sed -n 's/^duplicate of \([^ ]*\).*/\1/p')
    triage_report_repeat=0
    if [ -n "$triage_report_root" ]; then
      triage_report_repeat=$(jq -s -r --arg root "$triage_report_root" '[.[] | select(.current_status == "rejected" and ((.latest_verdict.rejection_reason // "") as $reason | ($reason | startswith("duplicate of " + $root + " ")) or ($reason | startswith("duplicate of " + $root + "("))))] | length' "$(triage_projection_file)")
      triage_report_pending=$(jq -s -r --arg root "$triage_report_root" \
        '[.[] | select((.rejection_reason // "") as $reason | ($reason | startswith("duplicate of " + $root + " ")) or ($reason | startswith("duplicate of " + $root + "(")))] | length' \
        "$(triage_decisions_draft_file)")
      triage_report_repeat=$((triage_report_repeat + triage_report_pending))
    fi
    printf '| %s | %s | %s |\n' "$triage_report_id" "$triage_report_reason" "$triage_report_repeat"
  done < "$triage_report_decisions")
  cat > "$triage_report" <<EOF
# morning-triage report

run_id: $TRIAGE_RUN_ID
watermark: $triage_watermark
nonce: $(triage_report_nonce)

## repo pins

$(printf '%b' "$triage_branch_lines")

## counts

- decisions_draft: $triage_decision_count
- outside_repo_count: $(printf '%s\n' "$triage_stats" | jq -r '.outside_repo_count')
- new_findings_total: $(printf '%s\n' "$triage_stats" | jq -r '.new_findings_total')
- new_findings_processed: $(printf '%s\n' "$triage_stats" | jq -r '.new_findings_processed')
- new_findings_carried: $(printf '%s\n' "$triage_stats" | jq -r '.new_findings_carried')
- verify_total: $(printf '%s\n' "$triage_stats" | jq -r '.verify_total')
- verify_processed: $(printf '%s\n' "$triage_stats" | jq -r '.verify_processed')
- verify_skipped_recent: $(printf '%s\n' "$triage_stats" | jq -r '.verify_skipped_recent')
- verify_carried: $(printf '%s\n' "$triage_stats" | jq -r '.verify_carried')
- decision_drops_target: $(printf '%s\n' "$triage_stats" | jq -r '.decision_drops_target')
- decision_drops_canonical: $(printf '%s\n' "$triage_stats" | jq -r '.decision_drops_canonical')
- dedup_pool_shrunk: $(printf '%s\n' "$triage_stats" | jq -r '.dedup_pool_shrunk')
- dedup_pool_empty: $(printf '%s\n' "$triage_stats" | jq -r '.dedup_pool_empty')
- adapter_failures: $(printf '%s\n' "$triage_stats" | jq -r '.adapter_failures')
- closure_incomplete: $(printf '%s\n' "$triage_stats" | jq -r '.closure_incomplete_count')
- phase_deadline: $(printf '%s\n' "$triage_stats" | jq -r '.phase_deadline_count')
- hard_wall: $(printf '%s\n' "$triage_stats" | jq -r '.hard_wall_count')
- rediscovery_rejects: $triage_rediscovery

## 自動却下

| finding | reason | 再発見回数 |
|---|---|---:|
$triage_auto_rows

## fixed 推奨

$(jq -r 'select(.verdict == "ALREADY_FIXED") | "- `" + .finding_id + "` — " + (.reason // .explanation // "")' "$(triage_verify_results_file)" 2>/dev/null || true)

### fixed 疑い・証拠不一致

$(triage_report_fixed_evidence_failures)

## 採用候補

$(jq -r 'select(.verdict == "CONFIRMED_CURRENT") | "- `" + .finding_id + "` — " + (.file // "") + ":" + ((.line // 0)|tostring)' "$(triage_verify_results_file)" 2>/dev/null || true)

## regression 疑い

$(triage_report_duplicate_class regression)

## 既知修正済み同型疑い

$(triage_report_duplicate_class known-fixed)

## クラスタ提示

| canonical | members | complete | 再発見回数 |
|---|---|---|---:|
$(jq -r 'select(.complete == true) | "| " + (.canonical_id // "unresolved") + " | " + (.members|join(", ")) + " | " + (.complete|tostring) + " | " + (.rediscovery_count|tostring) + " |"' "$(triage_clusters_file)" 2>/dev/null || true)

## dup 疑い

$(for triage_report_dedup in "$TRIAGE_WORK_DIR"/dedup/*/final.jsonl; do
  [ -f "$triage_report_dedup" ] || continue
  jq -r 'select(.verdict == "DUPLICATE" and .confidence != "high") | "- `" + .finding_id + "` → `" + .canonical_id + "` (" + .confidence + ")"' "$triage_report_dedup"
done)

## 要人裁定

- invalid verify lines: $(printf '%s\n' "$triage_stats" | jq -r '.verify_invalid_lines')
- invalid dedup lines: $(printf '%s\n' "$triage_stats" | jq -r '.dedup_invalid_lines')
- canonical 解決不能:
$(triage_report_duplicate_class unresolved)
- 人裁定先行 target drops: $(printf '%s\n' "$triage_stats" | jq -r '.decision_drops_target')
- 人裁定先行 canonical drops: $(printf '%s\n' "$triage_stats" | jq -r '.decision_drops_canonical')

## 残差

- コスト繰越: $(printf '%s\n' "$triage_stats" | jq -r '(.new_findings_carried + .verify_carried)')
- 再検証スキップ: $(printf '%s\n' "$triage_stats" | jq -r '.verify_skipped_recent')
- 対象外 repo: $(printf '%s\n' "$triage_stats" | jq -r '.outside_repo_count')
- 閉包未完: $(printf '%s\n' "$triage_stats" | jq -r '.closure_incomplete_count')
- 重複候補プール空: $(printf '%s\n' "$triage_stats" | jq -r '.dedup_pool_empty')
- adapter 完全失敗: $(printf '%s\n' "$triage_stats" | jq -r '.adapter_failures')

## decisions draft

\`\`\`json
$(sed -n '1,200p' "$(triage_decisions_draft_file)")
\`\`\`
EOF
  triage_report_bytes=$(wc -c < "$triage_report" | tr -d ' ')
  if [ "$triage_report_bytes" -gt 60000 ]; then
    awk 'BEGIN{bytes=0} {bytes += length($0)+1; if (bytes < 59000) print}' \
      "$triage_report" > "$triage_report.trimmed"
    printf '\n_Report truncated at 60KB; full machine artifacts remain under state/triage._\n' \
      >> "$triage_report.trimmed"
    mv "$triage_report.trimmed" "$triage_report"
  fi
}

triage_post_issue_comment() {
  triage_body_file=$1
  triage_issue_repo=$(triage_report_repo_full_name) || return 1
  triage_post_json=$(jq -n --rawfile body "$triage_body_file" '{body:$body}' |
    "$TRIAGE_GH_BIN" api --method POST \
      "repos/$triage_issue_repo/issues/$TRIAGE_REPORT_ISSUE/comments" \
      --input -) || return 1
  triage_comment_id=$(printf '%s\n' "$triage_post_json" | jq -r '.id')
  triage_comment_url=$(printf '%s\n' "$triage_post_json" | jq -r '.url')
  [ -n "$triage_comment_id" ] && [ -n "$triage_comment_url" ] || return 1
  triage_verify_json=$("$TRIAGE_GH_BIN" api --method GET "$triage_comment_url") || return 1
  printf '%s\n' "$triage_verify_json" | jq -e \
    --arg id "$triage_comment_id" \
    --arg nonce "$(triage_report_nonce)" '
      (.id | tostring) == $id and
      (.body | type == "string" and contains($nonce))
    ' >/dev/null 2>&1 || return 1
  printf '%s\n' "$triage_verify_json" | jq -r '.html_url'
}

triage_finalize_decisions() {
  triage_source_ref=$1
  triage_draft=$(triage_decisions_draft_file)
  triage_final=$(triage_decisions_final_file)
  : > "$triage_final"
  while IFS= read -r triage_line || [ -n "$triage_line" ]; do
    [ -n "$triage_line" ] || continue
    printf '%s\n' "$triage_line" | jq -c --arg source_ref "$triage_source_ref" \
      '. + {source_ref: $source_ref}' >> "$triage_final"
  done < "$triage_draft"
  triage_atomic_publish_file "$triage_final" \
    "$STATE_DIR/triage/decisions.jsonl"
}

triage_assert_all_rejected() {
  triage_final=$(triage_decisions_final_file)
  [ ! -s "$triage_final" ] ||
    jq -e -s 'length > 0 and all(.[]; .status == "rejected")' \
      "$triage_final" >/dev/null 2>&1
}

triage_run_verdict_sync() {
  triage_final=$(triage_decisions_final_file)
  triage_attempt=1
  triage_output_file="$TRIAGE_WORK_DIR/verdict-sync.output"
  while [ "$triage_attempt" -le "$TRIAGE_SYNC_RETRY_ATTEMPTS" ]; do
    if /bin/bash "$REPO_ROOT/bin/verdict-sync" --input "$triage_final" \
      > "$triage_output_file" 2>&1; then
      printf '%s\n' "$triage_output_file"
      return 0
    fi
    [ "$triage_attempt" -lt "$TRIAGE_SYNC_RETRY_ATTEMPTS" ] || break
    sleep "$TRIAGE_SYNC_RETRY_SEC"
    triage_attempt=$((triage_attempt + 1))
  done
  return 1
}

triage_render_result_comment() {
  triage_status=$1
  triage_sync_output_file=$2
  triage_result_file=$(triage_result_comment_file)
  if [ -f "$triage_sync_output_file" ]; then
    triage_summary=$(sed -n '1,20p' "$triage_sync_output_file" | tr '\n' ' ')
    triage_appended=$(sed -nE 's/.*appended=([0-9]+).*/\1/p' "$triage_sync_output_file" | sed -n '1p')
    triage_idempotent=$(sed -nE 's/.*idempotent=([0-9]+).*/\1/p' "$triage_sync_output_file" | sed -n '1p')
  else
    triage_summary='sync output unavailable'
    triage_appended=0
    triage_idempotent=0
  fi
  triage_dropped=$(jq -r '.decision_drops_target + .decision_drops_canonical' \
    "$(triage_stage_stats_file)")
  triage_decision_count=$(wc -l < "$(triage_decisions_final_file)" | tr -d ' ')
  if [ "$triage_status" != success ]; then
    triage_summary="同期失敗・台帳は open のまま・翌朝再試行; $triage_summary"
  fi
  cat > "$triage_result_file" <<EOF
morning-triage result: $triage_status

nonce: $(triage_report_nonce)
run_id: $TRIAGE_RUN_ID
appended: ${triage_appended:-0}
idempotent: ${triage_idempotent:-0}
dropped: $triage_dropped
decisions: $triage_decision_count 件
summary: $triage_summary
EOF
}

triage_run() {
  triage_dry_run=$1
  triage_force=$2

  triage_window_force=$triage_force
  [ "$triage_dry_run" != true ] || triage_window_force=true
  triage_check_window "$triage_window_force" || {
    triage_rc=$?
    [ "$triage_rc" -eq 2 ] && return 0
    return "$triage_rc"
  }

  [ "$TRIAGE_ENABLED" = 1 ] || [ "$triage_dry_run" = true ] || {
    printf '%s\n' 'morning-triage is disabled (TRIAGE_ENABLED=0)' >&2
    return 1
  }

  nightshift_prepare_state
  triage_acquire_lock || return 1
  triage_prepare_runtime || return 1
  triage_init_state_file
  triage_stats_init
  triage_parse_target_repo_map || return 1
  triage_assert_actor_uniqueness || return 1
  if [ "$triage_dry_run" != true ]; then
    triage_validate_report_issue || return 1
  fi

  : > "$(triage_repo_pins_file)"
  if [ -n "${TRIAGE_REPO_PINS_JSONL:-}" ]; then
    printf '%s' "$TRIAGE_REPO_PINS_JSONL" >> "$(triage_repo_pins_file)"
  fi

  triage_projection_snapshot
  triage_watermark=$(nightshift_iso_now)
  triage_build_current_ids
  triage_prepare_dedup_carryover
  TRIAGE_PHASE_A_END_EPOCH=$(( $(/bin/date '+%s') + TRIAGE_PHASE_A_DEADLINE_SEC ))
  export TRIAGE_PHASE_A_END_EPOCH

  for triage_repo in $(triage_target_repos_present); do
    if ! triage_phase_budget_available; then
      triage_stats_increment phase_deadline_count 1
      triage_stats_increment closure_incomplete_count 1
      break
    fi
    if ! triage_target_repo_for "$triage_repo" >/dev/null 2>&1; then
      triage_outside_count=$(jq -s -r --arg repo "$triage_repo" \
        '[.[] | select(.repo == $repo and .current_status == "open")] | length' \
        "$(triage_projection_file)")
      triage_stats_increment outside_repo_count "$triage_outside_count"
      continue
    fi
    triage_clone_json=$(triage_clone_repo_for "$triage_repo") || return 1
    printf '%s\n' "$triage_clone_json" > "$TRIAGE_WORK_DIR/clones/$triage_repo.json"
    triage_process_dedup_repo "$triage_repo" "$triage_clone_json" >/dev/null
    if ! triage_phase_budget_available; then
      triage_stats_increment phase_deadline_count 1
      break
    fi
    triage_process_verify_repo "$triage_repo" "$triage_clone_json" >/dev/null
  done

  if [ "$triage_dry_run" != true ]; then
    triage_publish_dedup_carryover || return 1
  fi

  triage_collect_machine_results
  triage_build_clusters
  triage_synthesize_decisions "$triage_watermark"
  triage_render_report "$triage_watermark"
  if [ "$triage_dry_run" = true ]; then
    triage_publish_artifacts "$triage_watermark" false
  else
    triage_publish_artifacts "$triage_watermark" true
  fi
  if [ "$triage_dry_run" = true ]; then
    return 0
  fi

  if ! triage_before_hard_wall; then
    triage_stats_increment hard_wall_count 1
    triage_render_report "$triage_watermark"
    triage_publish_artifacts "$triage_watermark"
    return 1
  fi
  triage_revalidate_drafts
  triage_render_report "$triage_watermark"
  triage_publish_artifacts "$triage_watermark"
  triage_source_ref=$(triage_post_issue_comment "$(triage_report_file)") || return 1
  triage_finalize_decisions "$triage_source_ref"
  triage_assert_all_rejected || {
    printf '%s\n' 'B2.5 rejected a non-rejected automatic decision batch' \
      > "$TRIAGE_WORK_DIR/b25.output"
    triage_render_result_comment gate-failed "$TRIAGE_WORK_DIR/b25.output"
    triage_post_issue_comment "$(triage_result_comment_file)" >/dev/null || true
    return 1
  }

  if [ ! -s "$(triage_decisions_final_file)" ]; then
    triage_release_lock
    printf '%s\n' 'decision 0 件; B3 verdict-sync skipped' \
      > "$TRIAGE_WORK_DIR/no-decisions.output"
    triage_render_result_comment success "$TRIAGE_WORK_DIR/no-decisions.output"
    triage_post_issue_comment "$(triage_result_comment_file)" >/dev/null || return 1
    triage_apply_verified_updates
    triage_publish_verified_state
    triage_mark_run_completed
    return 0
  fi

  triage_release_lock
  triage_sync_output=$(triage_run_verdict_sync) || {
    triage_render_result_comment failed "$TRIAGE_WORK_DIR/verdict-sync.output"
    triage_post_issue_comment "$(triage_result_comment_file)" >/dev/null || return 1
    return 1
  }
  triage_render_result_comment success "$triage_sync_output"
  triage_post_issue_comment "$(triage_result_comment_file)" >/dev/null || return 1
  triage_apply_verified_updates
  triage_publish_verified_state
  triage_mark_run_completed
}
