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
