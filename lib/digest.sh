#!/bin/bash
set -euo pipefail

digest_render_template() {
  template_file=$1
  output_file=$2
  digest_night_id=$3
  generated_at=$4
  digest_mode=$5
  findings_block=$6
  budget_block=$7
  lane_stats=$8
  kpi_block=$9
  org_consistency_freshness=${10}

  output_tmp="${output_file}.tmp.$$"
  if (
    while IFS= read -r template_line || [ -n "$template_line" ]; do
      case "$template_line" in
        '{{NIGHT_ID}}') printf '%s\n' "$digest_night_id" ;;
        '{{GENERATED_AT}}') printf '%s\n' "$generated_at" ;;
        '{{MODE}}') printf '%s\n' "$digest_mode" ;;
        '{{FINDINGS_BLOCK}}') printf '%s\n' "$findings_block" ;;
        '{{BUDGET_SNAPSHOT}}') printf '%s\n' "$budget_block" ;;
        '{{LANE_STATS}}') printf '%s\n' "$lane_stats" ;;
        '{{KPI_BLOCK}}') printf '%s\n' "$kpi_block" ;;
        '{{ORG_CONSISTENCY_FRESHNESS}}') printf '%s\n' "$org_consistency_freshness" ;;
        *) printf '%s\n' "$template_line" ;;
      esac
    done < "$template_file"
  ) > "$output_tmp"; then
    :
  else
    rm -f "$output_tmp"
    return 1
  fi

  if ! mv "$output_tmp" "$output_file"; then
    rm -f "$output_tmp"
    return 1
  fi
}

digest_kpi_block() {
  jq -r -s '
    def count_status($status):
      map(select(.current_status == $status)) | length;
    length as $total |
    count_status("open") as $open |
    count_status("adopted") as $adopted |
    count_status("fixed") as $fixed |
    count_status("rejected") as $rejected |
    count_status("regression") as $regression |
    count_status("deferred") as $deferred |
    ($adopted + $fixed + $rejected) as $decisions |
    [
      "total: \($total)",
      "open: \($open)",
      "adopted: \($adopted)",
      "fixed: \($fixed)",
      "rejected: \($rejected)",
      "regression: \($regression)",
      "deferred: \($deferred)",
      (
        if $total == 0 then
          "decision_rate: 0/0 (not calibrated)"
        else
          "decision_rate: \($decisions)/\($total)"
        end
      ),
      (
        if $total == 0 then
          "completion_rate: 0/0 (not calibrated)"
        else
          "completion_rate: \($fixed)/\($total)"
        end
      ),
      (
        if $decisions == 0 then
          "rejection_rate: 0/0 (not calibrated)"
        else
          "rejection_rate: \($rejected)/\($decisions)"
        end
      ),
      "revert_rate: unavailable (no explicit revert relation)"
    ]
    | join("\n")
  '
}

digest_org_consistency_freshness() {
  local enforce=$1
  local report_dir=$2
  local max_age_days=$3
  local now_epoch=$4
  local latest_file=
  local latest_mtime=0
  local report_file
  local report_mtime
  local age_seconds
  local age_days
  local max_age_seconds
  local report_name
  local threshold_exceeded=false

  case "$max_age_days" in
    ''|*[!0-9]*|0)
      printf '%s\n' 'OC_REPORT_MAX_AGE_DAYS must be a positive integer' >&2
      return 1
      ;;
  esac
  case "$enforce" in
    0|1) ;;
    *)
      printf '%s\n' 'OC_FRESHNESS_ENFORCE must be 0 or 1' >&2
      return 1
      ;;
  esac

  if [ "$enforce" = "0" ]; then
    printf '%s\n' 'org-consistency freshness: disabled'
    return 0
  fi

  if [ ! -d "$report_dir" ]; then
    printf '%s\n' 'WARNING: org-consistency has never published a report'
    return 0
  fi

  while IFS= read -r -d '' report_file; do
    report_mtime=$(stat -f '%m' "$report_file")
    if [ -z "$latest_file" ] || [ "$report_mtime" -gt "$latest_mtime" ]; then
      latest_file=$report_file
      latest_mtime=$report_mtime
    fi
  done < <(find "$report_dir" -type f -name '*.json' -print0)

  if [ -z "$latest_file" ]; then
    printf '%s\n' 'WARNING: org-consistency has never published a report'
    return 0
  fi

  if [ "$now_epoch" -lt "$latest_mtime" ]; then
    age_seconds=0
    age_days=0
  else
    age_seconds=$((now_epoch - latest_mtime))
    age_days=$((age_seconds / 86400))
  fi
  max_age_seconds=$((max_age_days * 86400))

  if [ "${OC_TEST_MODE:-}" = 1 ] && [ "${OC_TEST_MUTATE:-}" = freshness-threshold ]; then
    [ "$age_seconds" -ge "$max_age_seconds" ] && threshold_exceeded=true
  elif [ "$age_seconds" -gt "$max_age_seconds" ]; then
    threshold_exceeded=true
  fi

  if [ "$threshold_exceeded" = true ]; then
    printf 'WARNING: org-consistency latest report is %s days old (max %s)\n' \
      "$age_days" "$max_age_days"
    return 0
  fi

  report_name=${latest_file##*/}
  report_name=${report_name%.json}
  printf 'org-consistency freshness: OK (%s age %sd)\n' "$report_name" "$age_days"
}
