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

  output_tmp="${output_file}.tmp.$$"
  if ! (
    while IFS= read -r template_line || [ -n "$template_line" ]; do
      case "$template_line" in
        '{{NIGHT_ID}}') printf '%s\n' "$digest_night_id" ;;
        '{{GENERATED_AT}}') printf '%s\n' "$generated_at" ;;
        '{{MODE}}') printf '%s\n' "$digest_mode" ;;
        '{{FINDINGS_BLOCK}}') printf '%s\n' "$findings_block" ;;
        '{{BUDGET_SNAPSHOT}}') printf '%s\n' "$budget_block" ;;
        '{{LANE_STATS}}') printf '%s\n' "$lane_stats" ;;
        *) printf '%s\n' "$template_line" ;;
      esac
    done < "$template_file"
  ) > "$output_tmp"; then
    rm -f "$output_tmp"
    return 1
  fi

  mv "$output_tmp" "$output_file"
}
