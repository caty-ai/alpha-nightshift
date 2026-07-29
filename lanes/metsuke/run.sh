#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
# shellcheck source=lib/evidence.sh
. "$REPO_ROOT/lib/evidence.sh"

METSUKE_PORT=${METSUKE_PORT:-4173}
METSUKE_PERSONAS=${METSUKE_PERSONAS:-"beginner expert impatient"}
METSUKE_CODEX_BIN=${METSUKE_CODEX_BIN:-codex}
T_SERVE=0
T_CAPTURE=0
T_ANALYSIS=0
T_GOALS=0
SERVER_STARTED=false
GOALS_FAILED=false
CAPTURE_FAILED=false
INVALID_FINDINGS=0
PERSONAS_ATTEMPTED=0
PERSONAS_SUCCEEDED=0
PERSONAS_FAILED=0
SERVE_ATTEMPTED=false
SERVE_STATUS=not_attempted
SERVE_CLEANUP_STATUS=not_attempted
CAPTURE_ATTEMPTED=false
CAPTURE_STATUS=not_attempted
ANALYSIS_ATTEMPTED=false
ANALYSIS_STATUS=not_attempted
GOALS_ATTEMPTED=false
GOALS_STATUS=not_attempted
PERSONA_FAILURES_FILE=
CAPTURE_TRUST_DIR=
FINDINGS_STAGING_FILE=
FINDINGS_CONTRACT=

log() {
  printf '%s\n' "metsuke: $*" >&2
}

render_template() {
  local template=$1
  local first_placeholder=${2:-}
  local first_replacement=${3:-}
  local second_placeholder=${4:-}
  local second_replacement=${5:-}
  local template_line
  while IFS= read -r template_line || [ -n "$template_line" ]; do
    case "$template_line" in
      "{{$first_placeholder}}")
        cat "$first_replacement"
        ;;
      "{{$second_placeholder}}")
        cat "$second_replacement"
        ;;
      *)
        printf '%s\n' "$template_line"
        ;;
    esac
  done < "$template"
}

replace_inline_placeholder() {
  local input_file=$1
  local placeholder=$2
  local value=$3
  local output_file=$4
  local escaped_value
  escaped_value=$(printf '%s\n' "$value" | sed 's/[\/&]/\\&/g')
  sed "s/{{$placeholder}}/$escaped_value/g" "$input_file" > "$output_file"
}

render_persona_prompt() {
  local persona_file=$1
  local manifest_file=$2
  local evidence_dir=$3
  local output_path=$4
  local render_tmp_1
  local render_tmp_2
  local render_tmp_3
  render_tmp_1=$(mktemp "$LANE_DIR/.persona-render.XXXXXX")
  render_tmp_2=$(mktemp "$LANE_DIR/.persona-render.XXXXXX")
  render_tmp_3=$(mktemp "$LANE_DIR/.persona-render.XXXXXX")
  render_template "$SCRIPT_DIR/persona-prompt.tmpl.md" \
    PERSONA_CONTENT "$persona_file" \
    MANIFEST "$manifest_file" > "$render_tmp_1"
  replace_inline_placeholder "$render_tmp_1" EVIDENCE_DIR "$evidence_dir" "$render_tmp_2"
  replace_inline_placeholder "$render_tmp_2" OUTPUT_PATH "$output_path" "$render_tmp_3"
  cat "$render_tmp_3"
  rm -f "$render_tmp_1" "$render_tmp_2" "$render_tmp_3"
}

render_goals_prompt() {
  local manifest_file=$1
  local evidence_dir=$2
  local goals_path=$3
  local feature_map_path=$4
  local range_map_path=$5
  local goals_tmp_1
  local goals_tmp_2
  local goals_tmp_3
  local goals_tmp_4
  local goals_tmp_5
  goals_tmp_1=$(mktemp "$LANE_DIR/.goals-render.XXXXXX")
  goals_tmp_2=$(mktemp "$LANE_DIR/.goals-render.XXXXXX")
  goals_tmp_3=$(mktemp "$LANE_DIR/.goals-render.XXXXXX")
  goals_tmp_4=$(mktemp "$LANE_DIR/.goals-render.XXXXXX")
  goals_tmp_5=$(mktemp "$LANE_DIR/.goals-render.XXXXXX")
  render_template "$SCRIPT_DIR/goals-prompt.tmpl.md" \
    MANIFEST "$manifest_file" > "$goals_tmp_1"
  replace_inline_placeholder "$goals_tmp_1" EVIDENCE_DIR "$evidence_dir" "$goals_tmp_2"
  replace_inline_placeholder "$goals_tmp_2" GOALS_OUTPUT_PATH "$goals_path" "$goals_tmp_3"
  replace_inline_placeholder "$goals_tmp_3" FEATURE_MAP_OUTPUT_PATH "$feature_map_path" "$goals_tmp_4"
  replace_inline_placeholder "$goals_tmp_4" RANGE_MAP_OUTPUT_PATH "$range_map_path" "$goals_tmp_5"
  cat "$goals_tmp_5"
  rm -f \
    "$goals_tmp_1" \
    "$goals_tmp_2" \
    "$goals_tmp_3" \
    "$goals_tmp_4" \
    "$goals_tmp_5"
}

finding_candidate_is_valid() {
  local candidate_line=$1
  local candidate
  local symptom
  if ! candidate=$(printf '%s\n' "$candidate_line" | jq -e -c '
    select(
      type == "object" and
      (.target | type == "string" and length > 0) and
      (.symptom | type == "string" and length > 0) and
      (.interpretation | type == "string" and length > 0) and
      (.confirm_cost | type == "string" and
        (. == "即断" or . == "1分" or . == "3分")) and
      (.evidence | type == "array" and length > 0 and all(.[];
        type == "string" and
        length > 0 and
        (startswith("/") | not) and
        (startswith("//") | not) and
        (test("^[A-Za-z][A-Za-z0-9+.-]*:") | not) and
        (test("(^|/)\\.\\.?(?:/|$)") | not)
      ))
    )
    | {
        target: .target,
        symptom: .symptom,
        interpretation: .interpretation,
        confirm_cost: .confirm_cost,
        evidence: .evidence
      }
  ' 2>/dev/null); then
    return 1
  fi
  symptom=$(printf '%s\n' "$candidate" | jq -r '.symptom')
  if printf '%s\n' "$symptom" |
    grep -E -i 'かも|思われ|感じ|probably|maybe' >/dev/null 2>&1; then
    return 1
  fi
  VALIDATED_CANDIDATE=$candidate
  return 0
}

normalize_finding() {
  local candidate_line=$1
  local persona=$2
  local sequence=$3
  local evidence_json
  local target
  local finding_id
  finding_candidate_is_valid "$candidate_line" || return 1
  evidence_json=$(printf '%s\n' "$VALIDATED_CANDIDATE" | jq -c '.evidence')
  target=$(printf '%s\n' "$VALIDATED_CANDIDATE" | jq -r '.target')
  evidence_refs_match_target \
    "$evidence_json" \
    "$target" \
    "$CAPTURE_TRUST_DIR/manifest.json" \
    "$CAPTURE_TRUST_DIR/digests.json" || return 1
  finding_id=$(printf 'mk-%s-%03d' "$NIGHT_ID" "$sequence")
  printf '%s\n' "$VALIDATED_CANDIDATE" | jq -c \
    --arg id "$finding_id" \
    --arg persona "$persona" \
    --arg date "$NIGHT_ID" \
    '{
      id: $id,
      repo: "caty-talk-LP",
      target: .target,
      kind: "ux",
      symptom: .symptom,
      interpretation: .interpretation,
      persona: $persona,
      confirm_cost: .confirm_cost,
      evidence: .evidence,
      status: "open",
      date: $date
    }'
}

stage_normalized_finding() {
  local normalized_finding=$1
  local persona=$2
  local sequence=$3
  local finding_digest
  local finding_contract
  finding_digest=$(printf '%s\n' "$normalized_finding" |
    shasum -a 256 | awk '{print $1}') || return 1
  finding_contract=$(jq -n -c \
    --argjson sequence "$sequence" \
    --arg persona "$persona" \
    --arg digest "$finding_digest" \
    '{sequence: $sequence, persona: $persona, digest: $digest}') || return 1
  printf '%s\n' "$normalized_finding" >> "$FINDINGS_STAGING_FILE" || return 1
  if [ -n "$FINDINGS_CONTRACT" ]; then
    FINDINGS_CONTRACT="$FINDINGS_CONTRACT
$finding_contract"
  else
    FINDINGS_CONTRACT=$finding_contract
  fi
}

publish_staged_findings() {
  local findings_tmp
  local staged_line
  local compact_line
  local contract_line
  local contract
  local expected_sequence
  local expected_persona
  local expected_digest
  local actual_digest
  local canonical_finding
  local publication_sequence=1
  local publication_failed=0
  local extra_contract

  findings_tmp=$(mktemp "$LANE_DIR/.findings-publication.XXXXXX") || return 1
  : > "$findings_tmp"
  if [ -n "$FINDINGS_CONTRACT" ]; then
    exec 3<<EOF
$FINDINGS_CONTRACT
EOF
  else
    exec 3< /dev/null
  fi
  while IFS= read -r staged_line || [ -n "$staged_line" ]; do
    if ! IFS= read -r contract_line <&3; then
      log "in-memory finding contract ended before the staged findings"
      publication_failed=1
      break
    fi
    if ! contract=$(printf '%s\n' "$contract_line" | jq -e -c '
      select(
        type == "object" and
        (.sequence | type == "number" and floor == . and . > 0) and
        (.persona | type == "string" and length > 0) and
        (.digest | type == "string" and test("^[0-9a-f]{64}$"))
      )
      | {sequence: .sequence, persona: .persona, digest: .digest}
    ' 2>/dev/null); then
      log "rejected staged finding with malformed in-memory shell contract"
      INVALID_FINDINGS=$((INVALID_FINDINGS + 1))
      publication_failed=1
      continue
    fi
    expected_sequence=$(printf '%s\n' "$contract" | jq -r '.sequence')
    expected_persona=$(printf '%s\n' "$contract" | jq -r '.persona')
    expected_digest=$(printf '%s\n' "$contract" | jq -r '.digest')
    case "$expected_persona" in
      beginner|expert|impatient) ;;
      *)
        log "rejected staged finding with an invalid shell-assigned persona"
        INVALID_FINDINGS=$((INVALID_FINDINGS + 1))
        publication_failed=1
        continue
        ;;
    esac
    if [ "$expected_sequence" -ne "$publication_sequence" ]; then
      log "rejected staged finding with a mismatched shell-assigned sequence"
      INVALID_FINDINGS=$((INVALID_FINDINGS + 1))
      publication_failed=1
      publication_sequence=$((publication_sequence + 1))
      continue
    fi
    actual_digest=$(printf '%s\n' "$staged_line" |
      shasum -a 256 | awk '{print $1}') || {
      publication_failed=1
      break
    }
    if [ "$actual_digest" != "$expected_digest" ]; then
      log "rejected staged finding whose shell-normalized content was tampered"
      INVALID_FINDINGS=$((INVALID_FINDINGS + 1))
      publication_failed=1
      publication_sequence=$((publication_sequence + 1))
      continue
    fi
    if ! compact_line=$(printf '%s\n' "$staged_line" |
      jq -e -c 'select(type == "object")' 2>/dev/null); then
      log "rejected staged finding that is no longer valid JSON"
      INVALID_FINDINGS=$((INVALID_FINDINGS + 1))
      publication_failed=1
      publication_sequence=$((publication_sequence + 1))
      continue
    fi
    if ! canonical_finding=$(normalize_finding \
      "$compact_line" "$expected_persona" "$expected_sequence"); then
      log "rejected staged finding that failed final evidence or hedge validation"
      INVALID_FINDINGS=$((INVALID_FINDINGS + 1))
      publication_failed=1
      publication_sequence=$((publication_sequence + 1))
      continue
    fi
    if [ "$canonical_finding" != "$compact_line" ]; then
      log "rejected staged finding with mismatched shell-assigned contract fields"
      INVALID_FINDINGS=$((INVALID_FINDINGS + 1))
      publication_failed=1
      publication_sequence=$((publication_sequence + 1))
      continue
    fi
    printf '%s\n' "$canonical_finding" >> "$findings_tmp" || {
      publication_failed=1
      break
    }
    publication_sequence=$((publication_sequence + 1))
  done < "$FINDINGS_STAGING_FILE"
  if IFS= read -r extra_contract <&3; then
    log "in-memory finding contract contains entries without staged findings"
    publication_failed=1
  fi
  exec 3<&-

  if ! mv "$findings_tmp" "$LANE_DIR/findings.jsonl"; then
    rm -f "$findings_tmp"
    return 1
  fi
  [ "$publication_failed" -eq 0 ]
}

record_persona_failure() {
  local failed_persona=$1
  jq -n -c --arg persona "$failed_persona" '$persona' >> "$PERSONA_FAILURES_FILE"
}

capture_preflight() {
  local playwright_module_dir=$1
  if [ ! -d "$playwright_module_dir" ]; then
    CAPTURE_FAILED=true
    log "Playwright dependency is missing at $playwright_module_dir; run daytime npm ci --ignore-scripts in $SCRIPT_DIR before the night run"
    return 1
  fi
  if [ -z "${PLAYWRIGHT_BROWSERS_PATH_REAL:-}" ]; then
    CAPTURE_FAILED=true
    log "PLAYWRIGHT_BROWSERS_PATH_REAL is required; set it to the absolute ms-playwright cache directory"
    return 1
  fi
  case "$PLAYWRIGHT_BROWSERS_PATH_REAL" in
    /*) ;;
    *)
      CAPTURE_FAILED=true
      log "PLAYWRIGHT_BROWSERS_PATH_REAL must be an absolute path: $PLAYWRIGHT_BROWSERS_PATH_REAL"
      return 1
      ;;
  esac
  if [ ! -d "$PLAYWRIGHT_BROWSERS_PATH_REAL" ]; then
    CAPTURE_FAILED=true
    log "PLAYWRIGHT_BROWSERS_PATH_REAL does not exist or is not a directory: $PLAYWRIGHT_BROWSERS_PATH_REAL"
    return 1
  fi
  export PLAYWRIGHT_BROWSERS_PATH="$PLAYWRIGHT_BROWSERS_PATH_REAL"
}

prepare_codex_work_dir() {
  local label=$1
  local codex_root="$LANE_DIR/codex-work"
  if [ -L "$codex_root" ] || { [ -e "$codex_root" ] && [ ! -d "$codex_root" ]; }; then
    log "unsafe Codex work root refused: $codex_root"
    return 1
  fi
  mkdir -p "$codex_root"
  mktemp -d "$codex_root/$label.XXXXXX"
}

run_codex_prompt() {
  local work_dir=$1
  local prompt_path=$2
  (
    cd "$work_dir"
    "$METSUKE_CODEX_BIN" exec \
      --ignore-user-config \
      --ignore-rules \
      --disable multi_agent \
      --profile sol \
      --full-auto \
      --skip-git-repo-check \
      --ephemeral \
      - < "$prompt_path"
  )
}

goals_set_complete() {
  local goals_dir=$1
  [ -f "$goals_dir/GOALS-draft.md" ] &&
    [ ! -L "$goals_dir/GOALS-draft.md" ] &&
    [ -f "$goals_dir/feature-map.md" ] &&
    [ ! -L "$goals_dir/feature-map.md" ] &&
    [ -f "$goals_dir/range-map.md" ] &&
    [ ! -L "$goals_dir/range-map.md" ]
}

prepare_goals_directory() {
  local goals_dir=$1
  if [ -L "$goals_dir" ] || { [ -e "$goals_dir" ] && [ ! -d "$goals_dir" ]; }; then
    log "unsafe goals directory refused: $goals_dir"
    return 1
  fi
  mkdir -p "$goals_dir"
}

validate_goals_destinations() {
  local goals_dir=$1
  local destination
  for destination in \
    "$goals_dir/GOALS-draft.md" \
    "$goals_dir/feature-map.md" \
    "$goals_dir/range-map.md"; do
    if [ -L "$destination" ]; then
      log "goals destination is unexpectedly a symlink: $destination"
      return 1
    fi
    if [ -e "$destination" ] && [ ! -f "$destination" ]; then
      log "goals destination is unexpectedly not a regular file: $destination"
      return 1
    fi
  done
}

clear_goals_destinations() {
  local goals_dir=$1
  local destination
  for destination in \
    "$goals_dir/GOALS-draft.md" \
    "$goals_dir/feature-map.md" \
    "$goals_dir/range-map.md"; do
    if [ -d "$destination" ] && [ ! -L "$destination" ]; then
      log "cannot clear goals destination directory during publication: $destination"
      return 1
    fi
  done
  rm -f \
    "$goals_dir/GOALS-draft.md" \
    "$goals_dir/feature-map.md" \
    "$goals_dir/range-map.md"
}

restore_goals_set() {
  local backup_dir=$1
  local goals_dir=$2
  local file_name
  local restore_failed=0
  clear_goals_destinations "$goals_dir" || restore_failed=1
  for file_name in GOALS-draft.md feature-map.md range-map.md; do
    if [ -f "$backup_dir/$file_name" ]; then
      if ! cp -p "$backup_dir/$file_name" "$goals_dir/$file_name"; then
        restore_failed=1
      elif ! cmp -s "$backup_dir/$file_name" "$goals_dir/$file_name"; then
        restore_failed=1
      fi
    fi
  done
  [ "$restore_failed" -eq 0 ]
}

remove_goals_backup() {
  local backup_dir=$1
  rm -f \
    "$backup_dir/GOALS-draft.md" \
    "$backup_dir/feature-map.md" \
    "$backup_dir/range-map.md"
  rmdir "$backup_dir"
}

publish_goals_set() {
  local staged_dir=$1
  local goals_dir=$2
  local source_path
  local file_name
  local backup_dir
  local publication_failed=0
  for file_name in GOALS-draft.md feature-map.md range-map.md; do
    source_path="$staged_dir/$file_name"
    [ -f "$source_path" ] && [ ! -L "$source_path" ] || return 1
  done
  validate_goals_destinations "$goals_dir" || return 1
  backup_dir=$(mktemp -d "$goals_dir/.goals-backup.XXXXXX") || return 1
  for file_name in GOALS-draft.md feature-map.md range-map.md; do
    if [ -f "$goals_dir/$file_name" ]; then
      if ! cp -p "$goals_dir/$file_name" "$backup_dir/$file_name"; then
        remove_goals_backup "$backup_dir" || true
        return 1
      fi
    fi
  done
  if ! clear_goals_destinations "$goals_dir"; then
    if restore_goals_set "$backup_dir" "$goals_dir"; then
      remove_goals_backup "$backup_dir" || true
    else
      log "goals destinations could not be cleared; recovery backup retained at $backup_dir"
    fi
    return 1
  fi
  for file_name in GOALS-draft.md feature-map.md range-map.md; do
    if ! mv "$staged_dir/$file_name" "$goals_dir/$file_name"; then
      publication_failed=1
      break
    fi
  done
  if [ "$publication_failed" -ne 0 ] || ! goals_set_complete "$goals_dir"; then
    if restore_goals_set "$backup_dir" "$goals_dir"; then
      remove_goals_backup "$backup_dir" || true
    else
      log "goals/map publication failed; recovery backup retained at $backup_dir"
    fi
    return 1
  fi
  remove_goals_backup "$backup_dir" || true
}

write_metrics() {
  local metrics_tmp="$LANE_DIR/.metrics.$$.json"
  local persona_failures
  if [ -s "$PERSONA_FAILURES_FILE" ]; then
    persona_failures=$(jq -s . "$PERSONA_FAILURES_FILE")
  else
    persona_failures='[]'
  fi
  jq -n \
    --argjson t_serve "$T_SERVE" \
    --argjson t_capture "$T_CAPTURE" \
    --argjson t_analysis "$T_ANALYSIS" \
    --argjson t_goals "$T_GOALS" \
    --argjson persona_failures "$persona_failures" \
    --argjson personas_attempted "$PERSONAS_ATTEMPTED" \
    --argjson personas_succeeded "$PERSONAS_SUCCEEDED" \
    --argjson personas_failed "$PERSONAS_FAILED" \
    --argjson invalid_findings "$INVALID_FINDINGS" \
    --argjson capture_failed "$CAPTURE_FAILED" \
    --argjson goals_failed "$GOALS_FAILED" \
    --argjson serve_attempted "$SERVE_ATTEMPTED" \
    --arg serve_status "$SERVE_STATUS" \
    --arg serve_cleanup_status "$SERVE_CLEANUP_STATUS" \
    --argjson capture_attempted "$CAPTURE_ATTEMPTED" \
    --arg capture_status "$CAPTURE_STATUS" \
    --argjson analysis_attempted "$ANALYSIS_ATTEMPTED" \
    --arg analysis_status "$ANALYSIS_STATUS" \
    --argjson goals_attempted "$GOALS_ATTEMPTED" \
    --arg goals_status "$GOALS_STATUS" \
    '{
      t_serve: $t_serve,
      t_capture: $t_capture,
      t_analysis: $t_analysis,
      t_goals: $t_goals,
      persona_failures: $persona_failures,
      personas_attempted: $personas_attempted,
      personas_succeeded: $personas_succeeded,
      personas_failed: $personas_failed,
      invalid_findings: $invalid_findings,
      capture_failed: $capture_failed,
      goals_failed: $goals_failed,
      stages: {
        serve: {
          attempted: $serve_attempted,
          status: $serve_status,
          cleanup_status: $serve_cleanup_status
        },
        capture: {attempted: $capture_attempted, status: $capture_status},
        analysis: {attempted: $analysis_attempted, status: $analysis_status},
        goals: {attempted: $goals_attempted, status: $goals_status}
      }
    }' > "$metrics_tmp" || return 1
  mv "$metrics_tmp" "$LANE_DIR/metrics.json"
}

on_exit() {
  local original_status=$1
  local final_status=0
  local action_status=0
  trap - EXIT
  if ! publish_staged_findings; then
    [ "$action_status" -ne 0 ] || action_status=1
    log "final findings publication rejected tampered staging or failed"
  fi
  if [ "$SERVER_STARTED" = true ]; then
    if "$SCRIPT_DIR/serve-lp.sh" stop; then
      SERVE_CLEANUP_STATUS=succeeded
    else
      action_status=$?
      SERVE_CLEANUP_STATUS=failed
    fi
  fi
  if ! write_metrics; then
    [ "$action_status" -ne 0 ] || action_status=1
  fi
  rm -f \
    "$PERSONA_FAILURES_FILE" \
    "$FINDINGS_STAGING_FILE"
  if [ "$original_status" -ne 0 ]; then
    final_status=$original_status
  else
    final_status=$action_status
  fi
  exit "$final_status"
}

run_lane() {
  local phase_started
  local base_url
  local serve_rc
  local capture_rc
  local finding_sequence
  local persona
  local persona_work_dir
  local persona_output
  local persona_prompt
  local persona_rc
  local persona_candidates
  local persona_valid
  local candidate_line
  local finding
  local goals_dir
  local goals_work_dir
  local staged_goals_path
  local staged_feature_map_path
  local staged_range_map_path
  local goals_prompt
  local goals_rc
  local analysis_total_failure=false

  LANE_DIR=${LANE_DIR:?LANE_DIR is required}
  NIGHT_ID=${NIGHT_ID:?NIGHT_ID is required}
  if [ -z "${STATE_DIR-}" ]; then
    STATE_DIR=$(cd "$LANE_DIR/../../.." && pwd)
  fi
  export LANE_DIR NIGHT_ID STATE_DIR
  goals_dir="$STATE_DIR/goals"
  PERSONA_FAILURES_FILE="$LANE_DIR/.persona-failures.jsonl"
  CAPTURE_TRUST_DIR="$LANE_DIR/capture-trust"
  : > "$PERSONA_FAILURES_FILE"
  : > "$LANE_DIR/findings.jsonl"
  FINDINGS_STAGING_FILE=$(mktemp "$LANE_DIR/.accepted-findings.XXXXXX")
  FINDINGS_CONTRACT=
  trap 'on_exit $?' EXIT

  evidence_prepare_dir

  phase_started=$(date '+%s')
  if [ -n "${METSUKE_TARGET_URL:-}" ]; then
    base_url=$METSUKE_TARGET_URL
    SERVE_STATUS=skipped
    SERVE_CLEANUP_STATUS=skipped
    log "using configured target URL $base_url"
  else
    SERVE_ATTEMPTED=true
    serve_rc=0
    "$SCRIPT_DIR/serve-lp.sh" start || serve_rc=$?
    if [ "$serve_rc" -ne 0 ]; then
      SERVE_STATUS=failed
      T_SERVE=$(( $(date '+%s') - phase_started ))
      log "local LP build/serve failed with exit $serve_rc"
      return "$serve_rc"
    fi
    SERVER_STARTED=true
    SERVE_STATUS=succeeded
    base_url="http://127.0.0.1:$METSUKE_PORT"
  fi
  T_SERVE=$(( $(date '+%s') - phase_started ))

  CAPTURE_ATTEMPTED=true
  if ! capture_preflight "$SCRIPT_DIR/node_modules/playwright"; then
    CAPTURE_STATUS=failed
    return 1
  fi

  phase_started=$(date '+%s')
  capture_rc=0
  node "$SCRIPT_DIR/capture.mjs" \
    --base-url "$base_url" \
    --flows "$SCRIPT_DIR/flows.json" \
    --out "$(evidence_dir_path)" || capture_rc=$?
  T_CAPTURE=$(( $(date '+%s') - phase_started ))
  if [ "$capture_rc" -ne 0 ] || [ ! -f "$(evidence_manifest_path)" ]; then
    CAPTURE_FAILED=true
    CAPTURE_STATUS=failed
    log "mechanical capture failed with exit $capture_rc"
    return 1
  fi
  if ! jq -e '
    type == "object" and
    (.files | type == "object") and
    (.steps | type == "array")
  ' "$(evidence_manifest_path)" >/dev/null; then
    CAPTURE_FAILED=true
    CAPTURE_STATUS=failed
    log "capture manifest is malformed"
    return 1
  fi
  if ! evidence_freeze_capture "$CAPTURE_TRUST_DIR"; then
    CAPTURE_FAILED=true
    CAPTURE_STATUS=failed
    log "capture evidence could not be frozen into a trusted manifest/digest set"
    return 1
  fi
  CAPTURE_STATUS=succeeded

  ANALYSIS_ATTEMPTED=true
  phase_started=$(date '+%s')
  finding_sequence=1
  for persona in $METSUKE_PERSONAS; do
    case "$persona" in
      beginner|expert|impatient) ;;
      *)
        log "unknown persona skipped: $persona"
        record_persona_failure "$persona"
        continue
        ;;
    esac
    PERSONAS_ATTEMPTED=$((PERSONAS_ATTEMPTED + 1))
    persona_work_dir=$(prepare_codex_work_dir "persona-$persona") || {
      record_persona_failure "$persona"
      PERSONAS_FAILED=$((PERSONAS_FAILED + 1))
      continue
    }
    persona_output="$persona_work_dir/findings.jsonl"
    persona_prompt="$persona_work_dir/prompt.md"
    render_persona_prompt \
      "$SCRIPT_DIR/personas/$persona.md" \
      "$CAPTURE_TRUST_DIR/manifest.json" \
      "$(evidence_dir_path)" \
      "$persona_output" > "$persona_prompt"
    persona_rc=0
    run_codex_prompt "$persona_work_dir" "$persona_prompt" || persona_rc=$?
    if ! evidence_verify_frozen_capture "$CAPTURE_TRUST_DIR"; then
      ANALYSIS_STATUS=failed
      T_ANALYSIS=$(( $(date '+%s') - phase_started ))
      log "captured manifest/evidence changed during persona analysis; lane is failing closed"
      return 1
    fi
    if [ "$persona_rc" -ne 0 ] || [ ! -f "$persona_output" ]; then
      log "persona analysis failed for $persona (exit=$persona_rc)"
      record_persona_failure "$persona"
      PERSONAS_FAILED=$((PERSONAS_FAILED + 1))
      continue
    fi

    persona_candidates=0
    persona_valid=0
    while IFS= read -r candidate_line || [ -n "$candidate_line" ]; do
      [ -n "$candidate_line" ] || continue
      persona_candidates=$((persona_candidates + 1))
      if finding=$(normalize_finding "$candidate_line" "$persona" "$finding_sequence"); then
        if ! stage_normalized_finding "$finding" "$persona" "$finding_sequence"; then
          ANALYSIS_STATUS=failed
          T_ANALYSIS=$(( $(date '+%s') - phase_started ))
          log "failed to stage a shell-normalized finding"
          return 1
        fi
        finding_sequence=$((finding_sequence + 1))
        persona_valid=$((persona_valid + 1))
      else
        INVALID_FINDINGS=$((INVALID_FINDINGS + 1))
        log "rejected malformed, hedged, invented-target, cross-step, or untrusted finding from $persona"
      fi
    done < "$persona_output"
    if [ "$persona_candidates" -gt 0 ] && [ "$persona_valid" -eq 0 ]; then
      log "persona $persona produced only invalid findings"
      record_persona_failure "$persona"
      PERSONAS_FAILED=$((PERSONAS_FAILED + 1))
    else
      if [ "$persona_candidates" -eq 0 ]; then
        log "persona $persona completed with a valid empty output"
      fi
      PERSONAS_SUCCEEDED=$((PERSONAS_SUCCEEDED + 1))
    fi
  done
  T_ANALYSIS=$(( $(date '+%s') - phase_started ))
  if [ "$PERSONAS_ATTEMPTED" -eq 0 ] || [ "$PERSONAS_SUCCEEDED" -eq 0 ]; then
    ANALYSIS_STATUS=failed
    analysis_total_failure=true
    log "no configured valid persona completed successfully; lane will fail after goals cleanup"
  elif [ "$PERSONAS_FAILED" -gt 0 ]; then
    ANALYSIS_STATUS=degraded
  else
    ANALYSIS_STATUS=succeeded
  fi

  phase_started=$(date '+%s')
  if ! prepare_goals_directory "$goals_dir"; then
    GOALS_ATTEMPTED=true
    GOALS_FAILED=true
    GOALS_STATUS=failed
  elif goals_set_complete "$goals_dir"; then
    GOALS_STATUS=skipped
  else
    GOALS_ATTEMPTED=true
    if ! goals_work_dir=$(prepare_codex_work_dir goals); then
      GOALS_FAILED=true
      GOALS_STATUS=failed
    else
      staged_goals_path="$goals_work_dir/GOALS-draft.md"
      staged_feature_map_path="$goals_work_dir/feature-map.md"
      staged_range_map_path="$goals_work_dir/range-map.md"
      goals_prompt="$goals_work_dir/prompt.md"
      if ! validate_goals_destinations "$goals_dir"; then
        GOALS_FAILED=true
        GOALS_STATUS=failed
        log "unsafe partial goals destination prevented regeneration"
      else
        render_goals_prompt \
          "$CAPTURE_TRUST_DIR/manifest.json" \
          "$(evidence_dir_path)" \
          "$staged_goals_path" \
          "$staged_feature_map_path" \
          "$staged_range_map_path" > "$goals_prompt"
        goals_rc=0
        run_codex_prompt "$goals_work_dir" "$goals_prompt" || goals_rc=$?
        if ! evidence_verify_frozen_capture "$CAPTURE_TRUST_DIR"; then
          GOALS_FAILED=true
          GOALS_STATUS=failed
          T_GOALS=$(( $(date '+%s') - phase_started ))
          log "captured manifest/evidence changed during goals analysis; lane is failing closed"
          return 1
        fi
        if [ "$goals_rc" -ne 0 ] ||
          [ ! -f "$staged_goals_path" ] ||
          [ ! -f "$staged_feature_map_path" ] ||
          [ ! -f "$staged_range_map_path" ]; then
          GOALS_FAILED=true
          GOALS_STATUS=failed
          log "goals/map generation failed (exit=$goals_rc); findings are retained"
        elif ! publish_goals_set "$goals_work_dir" "$goals_dir"; then
          GOALS_FAILED=true
          GOALS_STATUS=failed
          log "goals/map publication failed and partial destinations were rolled back; findings are retained"
        else
          GOALS_STATUS=succeeded
        fi
      fi
    fi
  fi
  T_GOALS=$(( $(date '+%s') - phase_started ))

  if [ "$analysis_total_failure" = true ]; then
    return 1
  fi
}

case "${1:-run}" in
  run)
    run_lane
    ;;
  validate-finding)
    validation_line=$(sed -n '1p')
    finding_candidate_is_valid "$validation_line"
    printf '%s\n' "$VALIDATED_CANDIDATE"
    ;;
  render-persona)
    [ "$#" -eq 5 ] || exit 2
    LANE_DIR=${LANE_DIR:?LANE_DIR is required}
    render_persona_prompt "$2" "$3" "$4" "$5"
    ;;
  render-goals)
    [ "$#" -eq 6 ] || exit 2
    LANE_DIR=${LANE_DIR:?LANE_DIR is required}
    render_goals_prompt "$2" "$3" "$4" "$5" "$6"
    ;;
  check-capture-preflight)
    [ "$#" -eq 2 ] || exit 2
    capture_preflight "$2"
    ;;
  *)
    printf '%s\n' \
      "Usage: $0 {run|validate-finding|render-persona|render-goals|check-capture-preflight}" >&2
    exit 2
    ;;
esac
