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
PERSONA_FAILURES_FILE=

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
  input_file=$1
  placeholder=$2
  value=$3
  output_file=$4
  escaped_value=$(printf '%s\n' "$value" | sed 's/[\/&]/\\&/g')
  sed "s/{{$placeholder}}/$escaped_value/g" "$input_file" > "$output_file"
}

render_persona_prompt() {
  persona_file=$1
  manifest_file=$2
  evidence_dir=$3
  output_path=$4
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
  manifest_file=$1
  evidence_dir=$2
  goals_path=$3
  feature_map_path=$4
  range_map_path=$5
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
  rm -f "$goals_tmp_1" "$goals_tmp_2" "$goals_tmp_3" "$goals_tmp_4" "$goals_tmp_5"
}

finding_candidate_is_valid() {
  candidate_line=$1
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
  candidate_line=$1
  persona=$2
  sequence=$3
  finding_candidate_is_valid "$candidate_line" || return 1
  evidence_json=$(printf '%s\n' "$VALIDATED_CANDIDATE" | jq -c '.evidence')
  evidence_refs_are_manifested "$evidence_json" || return 1
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

record_persona_failure() {
  failed_persona=$1
  jq -n -c --arg persona "$failed_persona" '$persona' >> "$PERSONA_FAILURES_FILE"
}

write_metrics() {
  metrics_tmp="$LANE_DIR/.metrics.$$.json"
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
    --argjson invalid_findings "$INVALID_FINDINGS" \
    --argjson capture_failed "$CAPTURE_FAILED" \
    --argjson goals_failed "$GOALS_FAILED" \
    '{
      t_serve: $t_serve,
      t_capture: $t_capture,
      t_analysis: $t_analysis,
      t_goals: $t_goals,
      persona_failures: $persona_failures,
      invalid_findings: $invalid_findings,
      capture_failed: $capture_failed,
      goals_failed: $goals_failed
    }' > "$metrics_tmp" || return 1
  mv "$metrics_tmp" "$LANE_DIR/metrics.json"
}

on_exit() {
  original_status=$1
  trap - EXIT
  cleanup_status=0
  if [ "$SERVER_STARTED" = true ]; then
    "$SCRIPT_DIR/serve-lp.sh" stop || cleanup_status=$?
  fi
  write_metrics || cleanup_status=$?
  rm -f "$PERSONA_FAILURES_FILE"
  if [ "$original_status" -ne 0 ]; then
    exit "$original_status"
  fi
  exit "$cleanup_status"
}

run_lane() {
  LANE_DIR=${LANE_DIR:?LANE_DIR is required}
  NIGHT_ID=${NIGHT_ID:?NIGHT_ID is required}
  if [ -z "${STATE_DIR-}" ]; then
    STATE_DIR=$(cd "$LANE_DIR/../../.." && pwd)
  fi
  export LANE_DIR NIGHT_ID STATE_DIR
  PERSONA_FAILURES_FILE="$LANE_DIR/.persona-failures.jsonl"
  : > "$PERSONA_FAILURES_FILE"
  trap 'on_exit $?' EXIT

  mkdir -p "$LANE_DIR/proposals" "$STATE_DIR/goals"
  : > "$LANE_DIR/findings.jsonl"
  evidence_prepare_dir

  phase_started=$(date '+%s')
  if [ -n "${METSUKE_TARGET_URL:-}" ]; then
    base_url=$METSUKE_TARGET_URL
    log "using configured target URL $base_url"
  else
    serve_rc=0
    "$SCRIPT_DIR/serve-lp.sh" start || serve_rc=$?
    T_SERVE=$(( $(date '+%s') - phase_started ))
    if [ "$serve_rc" -ne 0 ]; then
      log "local LP build/serve failed with exit $serve_rc"
      return "$serve_rc"
    fi
    SERVER_STARTED=true
    base_url="http://127.0.0.1:$METSUKE_PORT"
  fi
  T_SERVE=$(( $(date '+%s') - phase_started ))

  if [ -n "${PLAYWRIGHT_BROWSERS_PATH_REAL:-}" ]; then
    case "$PLAYWRIGHT_BROWSERS_PATH_REAL" in
      /*) ;;
      *)
        CAPTURE_FAILED=true
        log "PLAYWRIGHT_BROWSERS_PATH_REAL must be absolute"
        return 1
        ;;
    esac
    export PLAYWRIGHT_BROWSERS_PATH="$PLAYWRIGHT_BROWSERS_PATH_REAL"
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
    log "mechanical capture failed with exit $capture_rc"
    return 1
  fi
  if ! jq -e '.files | type == "object"' "$(evidence_manifest_path)" >/dev/null; then
    CAPTURE_FAILED=true
    log "capture manifest is malformed"
    return 1
  fi

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
    persona_output="$LANE_DIR/proposals/$persona.jsonl"
    persona_prompt="$LANE_DIR/proposals/$persona-prompt.md"
    rm -f "$persona_output"
    render_persona_prompt \
      "$SCRIPT_DIR/personas/$persona.md" \
      "$(evidence_manifest_path)" \
      "$(evidence_dir_path)" \
      "$persona_output" > "$persona_prompt"
    persona_rc=0
    (
      cd "$LANE_DIR"
      "$METSUKE_CODEX_BIN" exec \
        --profile sol \
        --full-auto \
        --skip-git-repo-check \
        --ephemeral \
        - < "$persona_prompt"
    ) || persona_rc=$?
    if [ "$persona_rc" -ne 0 ] || [ ! -f "$persona_output" ]; then
      log "persona analysis failed for $persona (exit=$persona_rc)"
      record_persona_failure "$persona"
      continue
    fi

    persona_candidates=0
    persona_valid=0
    while IFS= read -r candidate_line || [ -n "$candidate_line" ]; do
      [ -n "$candidate_line" ] || continue
      persona_candidates=$((persona_candidates + 1))
      if finding=$(normalize_finding "$candidate_line" "$persona" "$finding_sequence"); then
        printf '%s\n' "$finding" >> "$LANE_DIR/findings.jsonl"
        finding_sequence=$((finding_sequence + 1))
        persona_valid=$((persona_valid + 1))
      else
        INVALID_FINDINGS=$((INVALID_FINDINGS + 1))
        log "rejected malformed, hedged, or unmanifested finding from $persona"
      fi
    done < "$persona_output"
    if [ "$persona_candidates" -eq 0 ]; then
      log "persona $persona produced no findings"
    elif [ "$persona_valid" -eq 0 ]; then
      record_persona_failure "$persona"
    fi
  done
  T_ANALYSIS=$(( $(date '+%s') - phase_started ))

  phase_started=$(date '+%s')
  goals_path="$STATE_DIR/goals/GOALS-draft.md"
  feature_map_path="$STATE_DIR/goals/feature-map.md"
  range_map_path="$STATE_DIR/goals/range-map.md"
  if [ ! -f "$goals_path" ]; then
    goals_stage_dir="$LANE_DIR/goals-output"
    mkdir -p "$goals_stage_dir"
    staged_goals_path="$goals_stage_dir/GOALS-draft.md"
    staged_feature_map_path="$goals_stage_dir/feature-map.md"
    staged_range_map_path="$goals_stage_dir/range-map.md"
    rm -f \
      "$staged_goals_path" \
      "$staged_feature_map_path" \
      "$staged_range_map_path"
    goals_prompt="$LANE_DIR/goals-prompt.md"
    render_goals_prompt \
      "$(evidence_manifest_path)" \
      "$(evidence_dir_path)" \
      "$staged_goals_path" \
      "$staged_feature_map_path" \
      "$staged_range_map_path" > "$goals_prompt"
    goals_rc=0
    (
      cd "$LANE_DIR"
      "$METSUKE_CODEX_BIN" exec \
        --profile sol \
        --full-auto \
        --skip-git-repo-check \
        --ephemeral \
        - < "$goals_prompt"
    ) || goals_rc=$?
    if [ "$goals_rc" -ne 0 ] ||
      [ ! -f "$staged_goals_path" ] ||
      [ ! -f "$staged_feature_map_path" ] ||
      [ ! -f "$staged_range_map_path" ]; then
      GOALS_FAILED=true
      log "goals/map generation failed (exit=$goals_rc); findings are retained"
    elif ! mv \
      "$staged_goals_path" \
      "$staged_feature_map_path" \
      "$staged_range_map_path" \
      "$STATE_DIR/goals/"; then
      GOALS_FAILED=true
      log "goals/map publication to the state dir failed; findings are retained"
    fi
  fi
  T_GOALS=$(( $(date '+%s') - phase_started ))
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
  *)
    printf 'Usage: %s {run|validate-finding|render-persona|render-goals}\n' "$0" >&2
    exit 2
    ;;
esac
