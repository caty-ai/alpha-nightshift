#!/bin/bash
# shellcheck disable=SC2034
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
  lane_status_section=${11}
  lane_status_footer=${12}

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
        '{{LANE_STATUS_SECTION}}') printf '%s\n' "$lane_status_section" ;;
        '{{LANE_STATUS_FOOTER}}') printf '%s\n' "$lane_status_footer" ;;
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

digest_lane_status_validate_config() {
  local lane_status_timeout_sec=$1
  local lane_status_max_rows=$2

  case "$lane_status_timeout_sec" in
    ''|*[!0-9]*|0)
      printf '%s\n' 'LANE_STATUS_TIMEOUT_SEC must be a positive integer' >&2
      return 1
      ;;
  esac
  if [ "${#lane_status_timeout_sec}" -gt 7 ]; then
    printf '%s\n' 'LANE_STATUS_TIMEOUT_SEC is too large' >&2
    return 1
  fi

  case "$lane_status_max_rows" in
    ''|*[!0-9]*|0)
      printf '%s\n' 'LANE_STATUS_MAX_ROWS must be a positive integer' >&2
      return 1
      ;;
  esac
  if [ "${#lane_status_max_rows}" -gt 7 ]; then
    printf '%s\n' 'LANE_STATUS_MAX_ROWS is too large' >&2
    return 1
  fi
}

digest_lane_status_run() {
  local lane_status_cmd=$1
  local lane_status_timeout_sec=$2
  local lane_status_night_dir=$3
  local lane_status_operator_gh_config_dir
  local lane_status_pid
  local lane_status_timeout_ticks
  local lane_status_elapsed_ticks
  local lane_status_launch_ticks

  DIGEST_LANE_STATUS_RUN_DIR=
  DIGEST_LANE_STATUS_STDOUT=
  DIGEST_LANE_STATUS_STDERR=
  DIGEST_LANE_STATUS_RC=1
  DIGEST_LANE_STATUS_TIMED_OUT=false
  DIGEST_LANE_STATUS_SURVIVORS=
  DIGEST_LANE_STATUS_RUN_ERROR=

  if ! mkdir -p "$lane_status_night_dir"; then
    DIGEST_LANE_STATUS_RUN_ERROR='state: mkdir failed'
    return 1
  fi
  if ! chmod 0700 "$lane_status_night_dir"; then
    DIGEST_LANE_STATUS_RUN_ERROR='state: chmod failed'
    return 1
  fi
  if ! DIGEST_LANE_STATUS_RUN_DIR=$(mktemp -d "$lane_status_night_dir/.run.XXXXXX"); then
    DIGEST_LANE_STATUS_RUN_ERROR='state: mktemp failed'
    return 1
  fi
  DIGEST_LANE_STATUS_STDOUT="$DIGEST_LANE_STATUS_RUN_DIR/stdout"
  DIGEST_LANE_STATUS_STDERR="$DIGEST_LANE_STATUS_RUN_DIR/stderr"

  if ! mkdir -p \
    "$DIGEST_LANE_STATUS_RUN_DIR/work" \
    "$DIGEST_LANE_STATUS_RUN_DIR/tmp" \
    "$DIGEST_LANE_STATUS_RUN_DIR/home"; then
    DIGEST_LANE_STATUS_RUN_ERROR='state: environment setup failed'
    return 1
  fi
  if {
    printf '%s\n' '[credential]'
    printf '%s\n' '	helper ='
  } > "$DIGEST_LANE_STATUS_RUN_DIR/home/.gitconfig"; then
    :
  else
    DIGEST_LANE_STATUS_RUN_ERROR='state: git config failed'
    return 1
  fi

  lane_status_operator_gh_config_dir=${GH_CONFIG_DIR:-$HOME/.config/gh}
  NIGHTSHIFT_PROCESS_INSPECTION_FAILED=false
  set -m
  (
    exec 3>&- 4>&-
    ulimit -f 4096 || exit 125
    # Bash 3.2 measures this limit in KiB on macOS; narrow it to 2 MiB.
    ulimit -f 2048 || exit 125
    cd "$DIGEST_LANE_STATUS_RUN_DIR/work" || exit 125
    exec env -i \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin \
      HOME="$DIGEST_LANE_STATUS_RUN_DIR/home" \
      TMPDIR="$DIGEST_LANE_STATUS_RUN_DIR/tmp" \
      LANG="$LANG" TERM=dumb NIGHT_ID="$NIGHT_ID" \
      GIT_CEILING_DIRECTORIES="$DIGEST_LANE_STATUS_RUN_DIR" \
      GH_CONFIG_DIR="$lane_status_operator_gh_config_dir" \
      /bin/bash -c "$lane_status_cmd"
  ) </dev/null >"$DIGEST_LANE_STATUS_STDOUT" 2>"$DIGEST_LANE_STATUS_STDERR" &
  lane_status_pid=$!
  set +m

  DIGEST_LANE_STATUS_TIMED_OUT=false
  lane_status_timeout_ticks=$((lane_status_timeout_sec * 10))
  lane_status_elapsed_ticks=0
  lane_status_launch_ticks=10

  while [ "$lane_status_launch_ticks" -gt 0 ]; do
    nightshift_refresh_process_tree "$lane_status_pid" "$DIGEST_LANE_STATUS_SURVIVORS"
    DIGEST_LANE_STATUS_SURVIVORS=$NIGHTSHIFT_PROCESS_PIDS
    if ! nightshift_pid_alive "$lane_status_pid"; then
      break
    fi
    sleep 0.01
    lane_status_launch_ticks=$((lane_status_launch_ticks - 1))
  done

  while nightshift_process_tree_alive "$lane_status_pid" "$DIGEST_LANE_STATUS_SURVIVORS"; do
    DIGEST_LANE_STATUS_SURVIVORS=$NIGHTSHIFT_PROCESS_KNOWN
    if [ "$lane_status_elapsed_ticks" -ge "$lane_status_timeout_ticks" ]; then
      DIGEST_LANE_STATUS_TIMED_OUT=true
      nightshift_stop_process_tree "$lane_status_pid" "$DIGEST_LANE_STATUS_SURVIVORS"
      DIGEST_LANE_STATUS_SURVIVORS=$NIGHTSHIFT_PROCESS_KNOWN
      break
    fi
    sleep 0.1
    lane_status_elapsed_ticks=$((lane_status_elapsed_ticks + 1))
  done

  if wait "$lane_status_pid"; then
    DIGEST_LANE_STATUS_RC=0
  else
    DIGEST_LANE_STATUS_RC=$?
  fi
  nightshift_stop_process_tree "$lane_status_pid" "$DIGEST_LANE_STATUS_SURVIVORS"
  DIGEST_LANE_STATUS_SURVIVORS=$NIGHTSHIFT_PROCESS_SURVIVORS
}

digest_lane_status_check() {
  local lane_status_stdout=$1

  DIGEST_LANE_STATUS_REASON=
  if jq -e -s 'length == 1' "$lane_status_stdout" >/dev/null 2>&1; then
    :
  else
    if jq -s '.' "$lane_status_stdout" >/dev/null 2>&1; then
      DIGEST_LANE_STATUS_REASON='contract: not a single JSON value'
    else
      DIGEST_LANE_STATUS_REASON='contract: not JSON'
    fi
    return 1
  fi
  if ! jq -e -s '.[0] | type == "object"' "$lane_status_stdout" >/dev/null 2>&1; then
    DIGEST_LANE_STATUS_REASON='contract: not an object'
    return 1
  fi
  if ! jq -e -s '.[0] | has("ci_red")' "$lane_status_stdout" >/dev/null 2>&1; then
    DIGEST_LANE_STATUS_REASON='contract: ci_red missing'
    return 1
  fi
  if ! jq -e -s '.[0].ci_red | type == "array"' "$lane_status_stdout" >/dev/null 2>&1; then
    DIGEST_LANE_STATUS_REASON='contract: ci_red not an array'
    return 1
  fi
  if ! jq -e -s '.[0] | has("lanes")' "$lane_status_stdout" >/dev/null 2>&1; then
    DIGEST_LANE_STATUS_REASON='contract: lanes missing'
    return 1
  fi
  if ! jq -e -s '.[0].lanes | type == "array"' "$lane_status_stdout" >/dev/null 2>&1; then
    DIGEST_LANE_STATUS_REASON='contract: lanes not an array'
    return 1
  fi
  if ! jq -e -s '.[0] | has("roster") and (.roster | type == "object")' \
    "$lane_status_stdout" >/dev/null 2>&1; then
    DIGEST_LANE_STATUS_REASON='contract: roster missing'
    return 1
  fi
  if ! jq -e -s '.[0].roster | has("repos")' "$lane_status_stdout" >/dev/null 2>&1; then
    DIGEST_LANE_STATUS_REASON='contract: roster.repos missing'
    return 1
  fi
  if ! jq -e -s \
    '.[0].roster.repos | type == "array" and all(.[]; type == "string")' \
    "$lane_status_stdout" >/dev/null 2>&1; then
    DIGEST_LANE_STATUS_REASON='contract: roster.repos not an array of strings'
    return 1
  fi
  if ! jq -e -s \
    '.[0] | (has("errors") | not) or (.errors | type == "array")' \
    "$lane_status_stdout" >/dev/null 2>&1; then
    DIGEST_LANE_STATUS_REASON='contract: errors not an array'
    return 1
  fi
  if ! jq -e -s \
    '.[0] | (has("truncated") | not) or (.truncated | type == "array")' \
    "$lane_status_stdout" >/dev/null 2>&1; then
    DIGEST_LANE_STATUS_REASON='contract: truncated not an array'
    return 1
  fi
}

digest_lane_status_render() {
  local lane_status_json=$1
  local lane_status_max_rows=$2
  local lane_status_night_id=$3
  # shellcheck disable=SC2016
  local lane_status_filter='
    def sanitize:
      tostring
      | gsub("[\\r\\n\\t]"; " ")
      | [explode[] | select(. >= 32 and . != 127)]
      | implode
      | if length > 120 then .[0:120] + "…" else . end;
    def valid_ci:
      type == "object" and
      (.repo | type == "string") and
      (.scope | type == "string" and (. == "main" or . == "pr" or . == "branch")) and
      (.branch | type == "string") and
      (.workflow | type == "string") and
      (.conclusion | type == "string") and
      (.since | type == "string");
    def valid_lane:
      type == "object" and
      (.repo | type == "string") and
      (.kind | type == "string" and (. == "pr" or . == "issue")) and
      (.number | type == "number" and . == floor) and
      (.title | type == "string") and
      (.owner | type == "string" and (. == "human" or . == "alpha" or . == "unknown")) and
      (.stale | type == "boolean") and
      (.reason | type == "string") and
      ((has("state") | not) or (.state | type == "string"));
    def capped_ci_lines($rows; $cap):
      ($rows | length) as $count
      | if $count == 0 then
          ["none"]
        else
          ([$rows[0:$cap][] |
            "- \(.repo | sanitize) · \(.workflow | sanitize) · \(.branch | sanitize) · \(.since | sanitize)"]) +
          (if $count > $cap then
             ["… +\(($count - $cap) | tostring) more (see lane-status.json)"]
           else [] end)
        end;
    def capped_lane_lines($rows; $cap):
      ($rows | length) as $count
      | if $count == 0 then
          ["none"]
        else
          ([$rows[0:$cap][] |
            "- \(.repo | sanitize)#\(.number | sanitize) · \(.title | sanitize) · \(.reason | sanitize)"]) +
          (if $count > $cap then
             ["… +\(($count - $cap) | tostring) more (see lane-status.json)"]
           else [] end)
        end;
    .[0] as $root
    | [$root.ci_red[] | select(valid_ci)] as $valid_ci
    | [$root.lanes[] | select(valid_lane)] as $valid_lanes
    | [$valid_ci[] | select(.scope == "main")]
      | sort_by([.repo, .workflow, .branch, .since]) as $main_ci
    | [$valid_lanes[] | select(.owner == "human")]
      | sort_by([.repo, .number, .kind]) as $human_lanes
    | [$valid_lanes[] | select(.stale == true)]
      | sort_by([.repo, .number, .kind]) as $stale_lanes
    | (($root.ci_red | length) - ($valid_ci | length) +
       ($root.lanes | length) - ($valid_lanes | length)) as $malformed
    | ($root.roster.repos | length) as $repos
    | ($root.errors // [] | length) as $errors
    | ($root.truncated // [] | length) as $truncated
    | ($max_rows | tonumber) as $cap
    | [
        "## Lane status",
        "",
        ("repos \($repos) · ci red \($main_ci | length) · human-owned lanes \($human_lanes | length) · stale lanes \($stale_lanes | length) · errors \($errors) · truncated \($truncated)" +
          (if $malformed > 0 then " · malformed rows \($malformed)" else "" end)),
        "",
        "### CI red (default branches)"
      ]
      + capped_ci_lines($main_ci; $cap)
      + ["", "### Human-owned lanes"]
      + capped_lane_lines($human_lanes; $cap)
      + ["", "### Stale lanes"]
      + capped_lane_lines($stale_lanes; $cap)
      + ["", "raw: digests/\($night_id)/lane-status.json"]
      | join("\n")'
  # shellcheck disable=SC2016
  local lane_status_footer_filter='
    def valid_ci:
      type == "object" and
      (.repo | type == "string") and
      (.scope | type == "string" and (. == "main" or . == "pr" or . == "branch")) and
      (.branch | type == "string") and
      (.workflow | type == "string") and
      (.conclusion | type == "string") and
      (.since | type == "string");
    def valid_lane:
      type == "object" and
      (.repo | type == "string") and
      (.kind | type == "string" and (. == "pr" or . == "issue")) and
      (.number | type == "number" and . == floor) and
      (.title | type == "string") and
      (.owner | type == "string" and (. == "human" or . == "alpha" or . == "unknown")) and
      (.stale | type == "boolean") and
      (.reason | type == "string") and
      ((has("state") | not) or (.state | type == "string"));
    .[0] as $root
    | [$root.ci_red[] | select(valid_ci and .scope == "main")] as $main_ci
    | [$root.lanes[] | select(valid_lane)] as $valid_lanes
    | [$valid_lanes[] | select(.owner == "human")] as $human_lanes
    | [$valid_lanes[] | select(.stale == true)] as $stale_lanes
    | "lane status: ok (repos \($root.roster.repos | length) · ci red \($main_ci | length) · human-owned lanes \($human_lanes | length) · stale lanes \($stale_lanes | length))"'

  if ! DIGEST_LANE_STATUS_SECTION=$(jq -r -s \
    --arg max_rows "$lane_status_max_rows" \
    --arg night_id "$lane_status_night_id" \
    "$lane_status_filter" "$lane_status_json" 2>/dev/null); then
    return 1
  fi
  if ! DIGEST_LANE_STATUS_FOOTER=$(jq -r -s \
    "$lane_status_footer_filter" "$lane_status_json" 2>/dev/null); then
    return 1
  fi
}

digest_lane_status_block() {
  local lane_status_cmd=$1
  local lane_status_timeout_sec=$2
  local lane_status_max_rows=$3
  local lane_status_night_dir=$4
  local lane_status_raw="$lane_status_night_dir/lane-status.json"
  local lane_status_stderr="$lane_status_night_dir/lane-status.stderr"
  local lane_status_stdout_size=0
  local lane_status_reason=
  local lane_status_level=WARN
  local lane_status_sigxfsz=153
  local lane_status_stderr_excerpt=
  local lane_status_stderr_line

  DIGEST_LANE_STATUS_SECTION=
  DIGEST_LANE_STATUS_FOOTER='lane status: not configured'
  if [ -z "$lane_status_cmd" ]; then
    return 0
  fi

  if [ -e "$lane_status_raw" ] && ! rm -f "$lane_status_raw"; then
    lane_status_reason='state: raw cleanup failed'
    lane_status_level=ERROR
  elif [ -e "$lane_status_stderr" ] && ! rm -f "$lane_status_stderr"; then
    lane_status_reason='state: stderr cleanup failed'
    lane_status_level=ERROR
  elif digest_lane_status_run \
    "$lane_status_cmd" "$lane_status_timeout_sec" "$lane_status_night_dir"; then
    if [ -f "$DIGEST_LANE_STATUS_STDERR" ]; then
      if cp "$DIGEST_LANE_STATUS_STDERR" "$lane_status_stderr" &&
        chmod 0600 "$lane_status_stderr"; then
        if lane_status_stderr_excerpt=$(LC_ALL=C awk \
          'NR <= 3 { gsub(/[[:cntrl:]]/, ""); print substr($0, 1, 200) }' \
          "$DIGEST_LANE_STATUS_STDERR"); then
          if [ -n "$lane_status_stderr_excerpt" ]; then
            while IFS= read -r lane_status_stderr_line || [ -n "$lane_status_stderr_line" ]; do
              nightshift_log WARN "lane-status stderr: $lane_status_stderr_line"
            done <<EOF
$lane_status_stderr_excerpt
EOF
          fi
        else
          nightshift_log WARN 'Could not read lane-status stderr excerpt'
        fi
      else
        lane_status_reason='state: stderr copy failed'
        lane_status_level=ERROR
      fi
    fi

    if [ -z "$lane_status_reason" ]; then
      if lane_status_stdout_size=$(wc -c < "$DIGEST_LANE_STATUS_STDOUT" 2>/dev/null); then
        if lane_status_stdout_size=$(printf '%s' "$lane_status_stdout_size" |
          tr -d '[:space:]'); then
          :
        else
          lane_status_reason='state: stdout size failed'
          lane_status_level=ERROR
        fi
      else
        lane_status_reason='state: stdout size failed'
        lane_status_level=ERROR
      fi
    fi

    if [ -z "$lane_status_reason" ]; then
      if [ "$NIGHTSHIFT_PROCESS_INSPECTION_FAILED" = true ]; then
        lane_status_reason='process inspection unavailable'
        lane_status_level=ERROR
      elif [ "$DIGEST_LANE_STATUS_TIMED_OUT" = true ]; then
        lane_status_reason="timeout after ${lane_status_timeout_sec}s"
      elif [ "$lane_status_stdout_size" -ge 2097152 ] ||
        [ "$DIGEST_LANE_STATUS_RC" -eq "$lane_status_sigxfsz" ]; then
        lane_status_reason='output too large'
      elif [ "$DIGEST_LANE_STATUS_RC" -eq 127 ]; then
        lane_status_reason='command-not-found'
      elif [ "$DIGEST_LANE_STATUS_RC" -ne 0 ]; then
        lane_status_reason="exit $DIGEST_LANE_STATUS_RC"
      elif [ "$lane_status_stdout_size" -eq 0 ]; then
        lane_status_reason='empty output'
      elif digest_lane_status_check "$DIGEST_LANE_STATUS_STDOUT"; then
        if mv "$DIGEST_LANE_STATUS_STDOUT" "$lane_status_raw" &&
          chmod 0600 "$lane_status_raw"; then
          if ! digest_lane_status_render \
            "$lane_status_raw" "$lane_status_max_rows" "$NIGHT_ID"; then
            rm -f "$lane_status_raw" || true
            lane_status_reason='contract: render failed'
          fi
        else
          rm -f "$lane_status_raw" || true
          lane_status_reason='state: raw write failed'
          lane_status_level=ERROR
        fi
      else
        lane_status_reason=$DIGEST_LANE_STATUS_REASON
      fi
    fi

    case "$DIGEST_LANE_STATUS_SURVIVORS" in
      *[![:space:]]*)
        nightshift_log WARN \
          "Lane-status reporter left survivors after descendant sweep: $DIGEST_LANE_STATUS_SURVIVORS"
        ;;
    esac
  else
    lane_status_reason=$DIGEST_LANE_STATUS_RUN_ERROR
    lane_status_level=ERROR
  fi

  if [ -n "${DIGEST_LANE_STATUS_RUN_DIR:-}" ] &&
    [ -d "$DIGEST_LANE_STATUS_RUN_DIR" ]; then
    if ! rm -rf "$DIGEST_LANE_STATUS_RUN_DIR"; then
      rm -f "$lane_status_raw" || true
      lane_status_reason='state: scratch cleanup failed'
      lane_status_level=ERROR
    fi
  fi

  if [ -n "$lane_status_reason" ]; then
    DIGEST_LANE_STATUS_SECTION=$(printf \
      '## Lane status\n\nlane status: unavailable (%s)' "$lane_status_reason")
    DIGEST_LANE_STATUS_FOOTER="lane status: unavailable ($lane_status_reason)"
    nightshift_log "$lane_status_level" "Lane status unavailable: $lane_status_reason"
  fi
  return 0
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
    # GNU first: BSD stat errors on -c, but GNU stat -f "succeeds" with
    # filesystem info, so the BSD-first order would never fall back on GNU.
    report_mtime=$(stat -c '%Y' "$report_file" 2>/dev/null || stat -f '%m' "$report_file")
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
    printf 'WARNING: org-consistency latest report is %s days old (>%s days)\n' \
      "$age_days" "$max_age_days"
    return 0
  fi

  report_name=${latest_file##*/}
  report_name=${report_name%.json}
  printf 'org-consistency freshness: OK (%s age %sd)\n' "$report_name" "$age_days"
}
