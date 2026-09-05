#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

log() {
  printf '%s\n' "rotation: $*" >&2
}

invalid_target() {
  log "invalid REVIEW_ROTATION_TARGETS entry: $1"
  exit 1
}

attempt_is_older() {
  local LC_ALL=C
  [[ "$1" < "$2" ]]
}

write_state() {
  state_result=$1
  state_tmp=$(mktemp "$state_parent/.review-rotation-state.XXXXXX") || return 1
  if ! printf '%s\n' "$state_json" |
    jq --arg name "$selected_name" \
      --arg night_id "$NIGHT_ID" \
      --arg result "$state_result" \
      '.targets[$name] = {last_attempt:$night_id,last_result:$result}' \
      > "$state_tmp"; then
    rm -f "$state_tmp"
    return 1
  fi
  if ! mv "$state_tmp" "$state_file"; then
    rm -f "$state_tmp"
    return 1
  fi
  state_json=$(<"$state_file")
}

write_evidence() {
  evidence_refresh=$1
  evidence_tmp=$(mktemp "$LANE_DIR/.rotation.XXXXXX") || return 1
  if ! jq -n \
    --arg night_id "$NIGHT_ID" \
    --arg selected "$selected_name" \
    --arg path "$selected_path" \
    --arg reason "$selection_reason" \
    --arg previous_last_attempt "$selected_last_attempt" \
    --arg refresh "$evidence_refresh" \
    --argjson candidates "$candidates_json" \
    '{night_id:$night_id,selected:$selected,path:$path,reason:$reason,
      previous_last_attempt:(if $previous_last_attempt == "" then null else $previous_last_attempt end),
      refresh:$refresh,candidates:$candidates}' > "$evidence_tmp"; then
    rm -f "$evidence_tmp"
    return 1
  fi
  if ! mv "$evidence_tmp" "$LANE_DIR/rotation.json"; then
    rm -f "$evidence_tmp"
    return 1
  fi
}

LANE_DIR=${LANE_DIR:?LANE_DIR is required}
NIGHT_ID=${NIGHT_ID:?NIGHT_ID is required}
rotation_targets=${REVIEW_ROTATION_TARGETS-}
state_file=${REVIEW_ROTATION_STATE-}
rotation_refresh=${REVIEW_ROTATION_REFRESH:-1}
rotation_run=${REVIEW_ROTATION_RUN:-"$SCRIPT_DIR/run.sh"}

target_names=()
target_paths=()
target_count=0
while IFS= read -r target_entry; do
  [ -n "$target_entry" ] || continue
  case "$target_entry" in
    *=*) ;;
    *) invalid_target "$target_entry" ;;
  esac
  target_name=${target_entry%%=*}
  target_path=${target_entry#*=}
  [ -n "$target_name" ] && [ -n "$target_path" ] || invalid_target "$target_entry"
  case "$target_path" in
    /*) ;;
    *) invalid_target "$target_entry" ;;
  esac
  [ "$(basename "$target_path")" = "$target_name" ] || invalid_target "$target_entry"
  seen_index=0
  while [ "$seen_index" -lt "$target_count" ]; do
    [ "${target_names[$seen_index]}" != "$target_name" ] || invalid_target "$target_entry"
    seen_index=$((seen_index + 1))
  done
  target_names+=("$target_name")
  target_paths+=("$target_path")
  target_count=$((target_count + 1))
done < <(printf '%s\n' "$rotation_targets" | tr '[:space:]' '\n')

[ "$target_count" -gt 0 ] || invalid_target '<empty>'

case "$state_file" in
  /*) ;;
  *) log 'REVIEW_ROTATION_STATE must be an absolute path'; exit 1 ;;
esac
state_parent=$(dirname "$state_file")
[ -d "$state_parent" ] || {
  log "REVIEW_ROTATION_STATE parent directory does not exist: $state_parent"
  exit 1
}
case "$rotation_refresh" in
  0|1) ;;
  *) log "invalid REVIEW_ROTATION_REFRESH: $rotation_refresh"; exit 1 ;;
esac

if [ -e "$state_file" ]; then
  if ! state_json=$(jq -e -c '
    select(
      type == "object" and
      .schema_version == 1 and
      (.targets | type == "object") and
      ([.targets[] |
        type == "object" and
        ((has("last_attempt") | not) or (.last_attempt | type == "string")) and
        ((has("last_result") | not) or
          (.last_result == "run" or
           .last_result == "missing-mirror" or
           .last_result == "refresh-failed"))
      ] | all)
    )
  ' "$state_file"); then
    log "invalid REVIEW_ROTATION_STATE JSON: $state_file"
    exit 1
  fi
else
  state_json='{"schema_version":1,"targets":{}}'
fi

candidates_json='[]'
selected_index=0
selected_last_attempt=
index=0
while [ "$index" -lt "$target_count" ]; do
  candidate_name=${target_names[$index]}
  candidate_last_attempt=$(printf '%s\n' "$state_json" |
    jq -r --arg name "$candidate_name" '.targets | .[$name].last_attempt // empty')
  candidates_json=$(printf '%s\n' "$candidates_json" |
    jq -c --arg name "$candidate_name" \
      --arg last_attempt "$candidate_last_attempt" \
      '. + [{name:$name,last_attempt:(if $last_attempt == "" then null else $last_attempt end)}]')
  if [ "$index" -eq 0 ] ||
    { [ -z "$candidate_last_attempt" ] && [ -n "$selected_last_attempt" ]; } ||
    { [ -n "$candidate_last_attempt" ] && [ -n "$selected_last_attempt" ] &&
      attempt_is_older "$candidate_last_attempt" "$selected_last_attempt"; }; then
    selected_index=$index
    selected_last_attempt=$candidate_last_attempt
  fi
  index=$((index + 1))
done

selected_name=${target_names[$selected_index]}
selected_path=${target_paths[$selected_index]}
if [ -z "$selected_last_attempt" ]; then
  selection_reason=never-attempted
  previous_display=none
else
  selection_reason=oldest-last-attempt
  previous_display=$selected_last_attempt
fi

if [ ! -d "$selected_path" ] ||
  ! git -C "$selected_path" rev-parse --git-dir >/dev/null 2>&1 ||
  [ "$(git -C "$selected_path" rev-parse --is-bare-repository 2>/dev/null || true)" != false ]; then
  write_state missing-mirror
  write_evidence skipped
  log "NOT-RUN reason=missing-mirror target=$selected_name path=$selected_path"
  exit 1
fi

refresh_result=skipped
write_state run
if [ "$rotation_refresh" = 1 ]; then
  if GIT_TERMINAL_PROMPT=0 git -C "$selected_path" pull --ff-only --quiet; then
    refresh_result=ok
  else
    refresh_result=failed
    write_state refresh-failed
    log "refresh failed target=$selected_name path=$selected_path; continuing with current HEAD"
  fi
fi

write_evidence "$refresh_result"
log "selected=$selected_name path=$selected_path previous_last_attempt=$previous_display refresh=$refresh_result"

exec env REVIEW_TARGET_SOURCE="$selected_path" /bin/bash "$rotation_run"
