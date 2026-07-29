#!/bin/bash
set -euo pipefail

verdict_sha256() {
  shasum -a 256 | awk '{print $1}'
}

verdict_validate_decision() {
  jq -e -S -c '
    def nonempty_string:
      type == "string" and length > 0;
    def utc_timestamp:
      . as $timestamp |
      type == "string" and
      test("^[0-9]{4}-(0[1-9]|1[0-2])-([0-2][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z$") and
      ((try (fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ"))
        catch null) == $timestamp);
    def positive_integer:
      type == "number" and (floor == .) and . > 0;
    def repo_name:
      type == "string" and
      test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") and
      (split("/") | all(.[]; . != "." and . != ".."));
    def safe_relative_path:
      type == "string" and
      length > 0 and
      (test("[\u0000-\u001F\u007F]") | not) and
      (startswith("/") | not) and
      (startswith("//") | not) and
      (test("^[A-Za-z][A-Za-z0-9+.-]*:") | not) and
      (test("(^|/)\\.\\.?(?:/|$)") | not);
    def done_when_valid:
      type == "array" and all(.[];
        type == "object" and
        ((keys_unsorted - ["item", "result", "evidence"]) | length == 0) and
        (.item | nonempty_string) and
        ((has("result") | not) or (.result | nonempty_string)) and
        ((has("evidence") | not) or (.evidence | nonempty_string))
      );
    select(
      type == "object" and
      ((keys_unsorted - [
        "finding_id", "status", "actor", "source", "source_ref",
        "observed_at", "rejection_reason", "repo_full_name", "issue", "pr",
        "candidate_sha", "implementer", "reviewer", "identity_check",
        "done_when", "declared_files", "diff_stat"
      ]) | length == 0) and
      (.finding_id | nonempty_string) and
      (.status == "adopted" or .status == "fixed" or
        .status == "rejected") and
      (.actor | nonempty_string) and
      (.source == "manual-comment" or .source == "manual-label" or
        .source == "github") and
      (.source_ref | nonempty_string) and
      (.observed_at | utc_timestamp) and
      (if .status == "rejected" then
        (.rejection_reason | nonempty_string)
      else
        (has("rejection_reason") | not)
      end) and
      ((has("repo_full_name") | not) or (.repo_full_name | repo_name)) and
      ((has("issue") | not) or (.issue | positive_integer)) and
      ((has("pr") | not) or (.pr | positive_integer)) and
      ((has("candidate_sha") | not) or
        (.candidate_sha | type == "string" and test("^[0-9a-f]{40}$"))) and
      ((has("implementer") | not) or (.implementer | nonempty_string)) and
      ((has("reviewer") | not) or (.reviewer | nonempty_string)) and
      ((has("identity_check") | not) or
        (.identity_check | nonempty_string)) and
      ((has("done_when") | not) or (.done_when | done_when_valid)) and
      ((has("declared_files") | not) or
        (.declared_files |
          type == "array" and all(.[]; safe_relative_path))) and
      ((has("diff_stat") | not) or (.diff_stat | nonempty_string))
    )
    | {
        finding_id, status, actor, source, source_ref, observed_at
      }
      + (if has("rejection_reason") then
          {rejection_reason}
        else {} end)
      + (if has("repo_full_name") then {repo_full_name} else {} end)
      + (if has("issue") then {issue} else {} end)
      + (if has("pr") then {pr} else {} end)
      + (if has("candidate_sha") then {candidate_sha} else {} end)
      + (if has("implementer") then {implementer} else {} end)
      + (if has("reviewer") then {reviewer} else {} end)
      + (if has("identity_check") then {identity_check} else {} end)
      + (if has("done_when") then {done_when} else {} end)
      + (if has("declared_files") then {declared_files} else {} end)
      + (if has("diff_stat") then {diff_stat} else {} end)
  '
}

verdict_validate_link() {
  jq -e -S -c '
    def nonempty_string:
      type == "string" and length > 0;
    def positive_integer:
      type == "number" and (floor == .) and . > 0;
    def repo_name:
      type == "string" and
      test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") and
      (split("/") | all(.[]; . != "." and . != ".."));
    select(
      type == "object" and
      ((keys_unsorted - ["finding_id", "repo_full_name", "issue", "pr"]) |
        length == 0) and
      (.finding_id | nonempty_string) and
      (.repo_full_name | repo_name) and
      ((has("issue") and (.issue | positive_integer)) or
        (has("pr") and (.pr | positive_integer))) and
      ((has("issue") | not) or (.issue | positive_integer)) and
      ((has("pr") | not) or (.pr | positive_integer))
    )
    | {finding_id, repo_full_name}
      + (if has("issue") then {issue} else {} end)
      + (if has("pr") then {pr} else {} end)
  '
}

verdict_require_absolute_file() {
  verdict_source_path=$1
  case "$verdict_source_path" in
    /*) ;;
    *) return 1 ;;
  esac
  [ -f "$verdict_source_path" ] && [ -r "$verdict_source_path" ]
}

verdict_stage_manual_source() {
  verdict_input_file=$1
  verdict_decisions_file=$2
  verdict_seen_file=$3

  : > "$verdict_decisions_file"
  : > "$verdict_seen_file"
  while IFS= read -r verdict_input_line || [ -n "$verdict_input_line" ]; do
    [ -n "$verdict_input_line" ] || return 1
    if ! verdict_decision=$(printf '%s\n' "$verdict_input_line" |
      verdict_validate_decision 2>/dev/null); then
      return 1
    fi
    verdict_finding_key=$(printf '%s\n' "$verdict_decision" |
      jq -r '.finding_id | @base64')
    if grep -F -x -- "$verdict_finding_key" "$verdict_seen_file" \
      >/dev/null 2>&1; then
      return 1
    fi
    printf '%s\n' "$verdict_finding_key" >> "$verdict_seen_file" ||
      return 1
    printf '%s\n' "$verdict_decision" >> "$verdict_decisions_file" ||
      return 1
  done < "$verdict_input_file"
}

verdict_gh_get() {
  verdict_gh_endpoint=$1
  "$VERDICT_GH_BIN" api --method GET "$verdict_gh_endpoint"
}

verdict_github_labels() {
  jq -e -c '
    select(
      type == "object" and
      (.labels | type == "array") and
      all(.labels[]; type == "object" and (.name | type == "string"))
    )
    | [.labels[].name]
  '
}

verdict_github_page_is_complete() {
  verdict_page_file=$1
  jq -e '
    type == "array" and length < 100
  ' "$verdict_page_file" >/dev/null 2>&1
}

verdict_github_label_decision() {
  verdict_label_events_file=$1
  verdict_label_name=$2
  verdict_repo=$3
  verdict_resource_kind=$4
  verdict_resource_number=$5
  verdict_status=$6

  verdict_github_page_is_complete "$verdict_label_events_file" || return 1
  jq -e -S -c \
    --arg label "$verdict_label_name" \
    --arg repo "$verdict_repo" \
    --arg kind "$verdict_resource_kind" \
    --argjson number "$verdict_resource_number" \
    --arg status "$verdict_status" '
      def utc_timestamp:
        . as $timestamp |
        type == "string" and
        test("^[0-9]{4}-(0[1-9]|1[0-2])-([0-2][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z$") and
        ((try (fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ"))
          catch null) == $timestamp);
      [
        .[] |
        select(
          type == "object" and
          .event == "labeled" and
          .label.name == $label and
          (.actor.login | type == "string" and length > 0) and
          (.created_at | utc_timestamp) and
          ((.id | type) == "number" or (.id | type) == "string")
        )
      ]
      | sort_by(.created_at, (.id | tostring))
      | if length == 0 then
          error("missing label event")
        elif (
          length > 1 and
          .[-1].created_at == .[-2].created_at
        ) then
          error("ambiguous label event time")
        else
          .[-1] |
          {
            status: $status,
            actor: .actor.login,
            source: "github",
            source_ref: (
              "github:" + $repo + ":" + $kind + ":" +
              ($number | tostring) + ":label-event:" + (.id | tostring)
            ),
            observed_at: .created_at
          }
        end
    ' "$verdict_label_events_file"
}

verdict_github_rejection_marker() {
  verdict_comments_file=$1
  verdict_finding_id=$2
  verdict_repo=$3
  verdict_resource_kind=$4
  verdict_resource_number=$5

  verdict_github_page_is_complete "$verdict_comments_file" || return 1
  jq -e -S -c \
    --arg finding_id "$verdict_finding_id" \
    --arg repo "$verdict_repo" \
    --arg kind "$verdict_resource_kind" \
    --argjson number "$verdict_resource_number" \
    --arg night_bot_login "$NIGHT_BOT_LOGIN" '
      def utc_timestamp:
        . as $timestamp |
        type == "string" and
        test("^[0-9]{4}-(0[1-9]|1[0-2])-([0-2][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z$") and
        ((try (fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ"))
          catch null) == $timestamp);
      [
        .[] as $comment |
        (try ($comment.body | fromjson) catch null) as $marker |
        select(
          ($comment | type) == "object" and
          ($marker | type) == "object" and
          (($marker | keys_unsorted) - [
            "schema", "finding_id", "status", "rejection_reason"
          ] | length == 0) and
          ($marker | keys_unsorted | length) == 4 and
          $marker.schema == "alpha-nightshift/verdict-marker/v1" and
          $marker.finding_id == $finding_id and
          $marker.status == "rejected" and
          ($marker.rejection_reason | type == "string" and length > 0) and
          $comment.user.type == "User" and
          ($comment.user.login |
            type == "string" and length > 0 and . != $night_bot_login) and
          ($comment.created_at | utc_timestamp) and
          (($comment.id | type) == "number" or
            ($comment.id | type) == "string")
        )
        | {
            marker: $marker,
            actor: $comment.user.login,
            created_at: $comment.created_at,
            id: $comment.id
          }
      ]
      | sort_by(.created_at, (.id | tostring))
      | if length == 0 then
          error("missing human rejection marker")
        elif (
          length > 1 and
          .[-1].created_at == .[-2].created_at
        ) then
          error("ambiguous rejection marker time")
        else
          .[-1] |
          {
            status: "rejected",
            actor: .actor,
            source: "github",
            source_ref: (
              "github:" + $repo + ":" + $kind + ":" +
              ($number | tostring) + ":comment:" + (.id | tostring)
            ),
            observed_at: .created_at,
            rejection_reason: .marker.rejection_reason
          }
        end
    ' "$verdict_comments_file"
}

verdict_github_issue_decision() {
  verdict_link=$1
  verdict_resource_work_dir=$2
  verdict_repo=$(printf '%s\n' "$verdict_link" | jq -r '.repo_full_name')
  verdict_finding_id=$(printf '%s\n' "$verdict_link" | jq -r '.finding_id')
  verdict_issue=$(printf '%s\n' "$verdict_link" | jq -r '.issue')
  verdict_issue_file="$verdict_resource_work_dir/issue-$verdict_issue.json"

  verdict_gh_get "repos/$verdict_repo/issues/$verdict_issue" \
    > "$verdict_issue_file" || return 1
  if ! verdict_labels=$(verdict_github_labels < "$verdict_issue_file"); then
    return 1
  fi
  verdict_has_done=$(printf '%s\n' "$verdict_labels" |
    jq -r 'index("night:done") != null')
  verdict_has_rejected=$(printf '%s\n' "$verdict_labels" |
    jq -r 'index("night:rejected") != null')
  verdict_has_ready=$(printf '%s\n' "$verdict_labels" |
    jq -r 'index("night:ready") != null')

  if [ "$verdict_has_rejected" = true ] &&
    { [ "$verdict_has_done" = true ] || [ "$verdict_has_ready" = true ]; }; then
    return 1
  fi
  if [ "$verdict_has_done" = true ] || [ "$verdict_has_ready" = true ]; then
    verdict_label=night:ready
    verdict_label_status=adopted
    if [ "$verdict_has_done" = true ]; then
      verdict_label=night:done
      verdict_label_status=fixed
    fi
    verdict_events_file="$verdict_resource_work_dir/issue-$verdict_issue-events.json"
    verdict_gh_get \
      "repos/$verdict_repo/issues/$verdict_issue/events?per_page=100" \
      > "$verdict_events_file" || return 1
    verdict_github_label_decision \
      "$verdict_events_file" \
      "$verdict_label" \
      "$verdict_repo" \
      issue \
      "$verdict_issue" \
      "$verdict_label_status"
    return
  fi
  if [ "$verdict_has_rejected" = true ]; then
    verdict_comments_file="$verdict_resource_work_dir/issue-$verdict_issue-comments.json"
    verdict_gh_get \
      "repos/$verdict_repo/issues/$verdict_issue/comments?per_page=100" \
      > "$verdict_comments_file" || return 1
    verdict_github_rejection_marker \
      "$verdict_comments_file" \
      "$verdict_finding_id" \
      "$verdict_repo" \
      issue \
      "$verdict_issue"
    return
  fi
  return 3
}

verdict_github_pr_decision() {
  verdict_link=$1
  verdict_resource_work_dir=$2
  verdict_repo=$(printf '%s\n' "$verdict_link" | jq -r '.repo_full_name')
  verdict_finding_id=$(printf '%s\n' "$verdict_link" | jq -r '.finding_id')
  verdict_pr=$(printf '%s\n' "$verdict_link" | jq -r '.pr')
  verdict_pr_file="$verdict_resource_work_dir/pr-$verdict_pr.json"

  verdict_gh_get "repos/$verdict_repo/pulls/$verdict_pr" \
    > "$verdict_pr_file" || return 1
  if ! verdict_labels=$(verdict_github_labels < "$verdict_pr_file"); then
    return 1
  fi
  verdict_has_done=$(printf '%s\n' "$verdict_labels" |
    jq -r 'index("night:done") != null')
  verdict_has_rejected=$(printf '%s\n' "$verdict_labels" |
    jq -r 'index("night:rejected") != null')
  verdict_has_ready=$(printf '%s\n' "$verdict_labels" |
    jq -r 'index("night:ready") != null')
  if [ "$verdict_has_rejected" = true ] &&
    { [ "$verdict_has_done" = true ] || [ "$verdict_has_ready" = true ]; }; then
    return 1
  fi

  if ! verdict_pr_shape=$(jq -e -S -c '
    select(
      type == "object" and
      (.state == "open" or .state == "closed") and
      (.merged | type == "boolean") and
      (.labels | type == "array") and
      (.html_url | type == "string" and length > 0) and
      (.user.login | type == "string" and length > 0) and
      (.created_at | type == "string") and
      ((.merged_at == null) or (.merged_at | type == "string")) and
      ((.merged_by == null) or
        (.merged_by.login | type == "string" and length > 0)) and
      ((.head.sha == null) or
        (.head.sha | type == "string" and test("^[0-9a-f]{40}$")))
    )
    | {
        state, merged, merged_at, merged_by, html_url, user, created_at,
        candidate_sha: .head.sha
      }
  ' "$verdict_pr_file" 2>/dev/null); then
    return 1
  fi

  verdict_pr_merged=$(printf '%s\n' "$verdict_pr_shape" | jq -r '.merged')
  verdict_pr_state=$(printf '%s\n' "$verdict_pr_shape" | jq -r '.state')
  if [ "$verdict_pr_merged" = true ]; then
    if [ "$verdict_has_rejected" = true ]; then
      return 1
    fi
    if ! verdict_decision=$(printf '%s\n' "$verdict_pr_shape" | jq -e -S -c \
      --arg repo "$verdict_repo" \
      --argjson pr "$verdict_pr" '
        select(
          (.merged_at | type == "string") and
          (.merged_by.login | type == "string" and length > 0)
        )
        | {
            status: "fixed",
            actor: .merged_by.login,
            source: "github",
            source_ref: (
              "github:" + $repo + ":pr:" + ($pr | tostring) + ":merged"
            ),
            observed_at: .merged_at
          }
          + (if .candidate_sha == null then
              {}
            else
              {candidate_sha}
            end)
      ' 2>/dev/null); then
      return 1
    fi
    printf '%s\n' "$verdict_decision"
    return
  fi

  if [ "$verdict_has_done" = true ]; then
    verdict_events_file="$verdict_resource_work_dir/pr-$verdict_pr-events.json"
    verdict_gh_get \
      "repos/$verdict_repo/issues/$verdict_pr/events?per_page=100" \
      > "$verdict_events_file" || return 1
    verdict_github_label_decision \
      "$verdict_events_file" \
      night:done \
      "$verdict_repo" \
      pr \
      "$verdict_pr" \
      fixed
    return
  fi

  if [ "$verdict_has_rejected" = true ] ||
    [ "$verdict_pr_state" = closed ]; then
    verdict_comments_file="$verdict_resource_work_dir/pr-$verdict_pr-comments.json"
    verdict_gh_get \
      "repos/$verdict_repo/issues/$verdict_pr/comments?per_page=100" \
      > "$verdict_comments_file" || return 1
    verdict_github_rejection_marker \
      "$verdict_comments_file" \
      "$verdict_finding_id" \
      "$verdict_repo" \
      pr \
      "$verdict_pr"
    return
  fi

  if [ "$verdict_pr_state" = open ]; then
    printf '%s\n' "$verdict_pr_shape" | jq -e -S -c \
      --arg repo "$verdict_repo" \
      --argjson pr "$verdict_pr" '
        {
          status: "adopted",
          actor: .user.login,
          source: "github",
          source_ref: (
            "github:" + $repo + ":pr:" + ($pr | tostring) + ":opened"
          ),
          observed_at: .created_at
        }
        + (if .candidate_sha == null then
            {}
          else
            {candidate_sha}
          end)
      '
    return
  fi
  return 3
}

verdict_choose_github_decision() {
  verdict_candidates_file=$1
  verdict_candidate_count=$(wc -l < "$verdict_candidates_file" | tr -d ' ')
  [ "$verdict_candidate_count" -gt 0 ] || return 1

  jq -e -S -c -s '
    def nonempty_string:
      type == "string" and length > 0;
    def utc_timestamp:
      . as $timestamp |
      type == "string" and
      test("^[0-9]{4}-(0[1-9]|1[0-2])-([0-2][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z$") and
      ((try (fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ"))
        catch null) == $timestamp);
    def candidate_valid:
      type == "object" and
      ((keys_unsorted - [
        "status", "actor", "source", "source_ref", "observed_at",
        "rejection_reason", "candidate_sha"
      ]) | length == 0) and
      (.status == "adopted" or .status == "fixed" or
        .status == "rejected") and
      (.actor | nonempty_string) and
      .source == "github" and
      (.source_ref | nonempty_string) and
      (.observed_at | utc_timestamp) and
      (if .status == "rejected" then
        (.rejection_reason | nonempty_string)
      else
        (has("rejection_reason") | not)
      end) and
      ((has("candidate_sha") | not) or
        (.candidate_sha |
          type == "string" and test("^[0-9a-f]{40}$")));
    unique as $candidates |
    ($candidates | map(.status) | unique) as $statuses |
    if ($candidates | all(.[]; candidate_valid) | not) then
      error("malformed decision candidate")
    elif ($statuses | length) != 1 then
      error("conflicting candidate statuses")
    else
      ($candidates | map(.observed_at) | max) as $newest |
      ($candidates | map(select(.observed_at == $newest))) as $newest_candidates |
      if ($newest_candidates | length) != 1 then
        error("ambiguous newest candidate time")
      else
        $newest_candidates[0]
      end
    end
  ' "$verdict_candidates_file"
}

verdict_stage_github_source() {
  verdict_links_file=$1
  verdict_decisions_file=$2
  verdict_seen_file=$3
  verdict_github_stage_root=$4

  : > "$verdict_decisions_file"
  : > "$verdict_seen_file"
  verdict_link_number=0
  while IFS= read -r verdict_link_line || [ -n "$verdict_link_line" ]; do
    [ -n "$verdict_link_line" ] || return 1
    if ! verdict_link=$(printf '%s\n' "$verdict_link_line" |
      verdict_validate_link 2>/dev/null); then
      return 1
    fi
    verdict_finding_key=$(printf '%s\n' "$verdict_link" |
      jq -r '.finding_id | @base64')
    if grep -F -x -- "$verdict_finding_key" "$verdict_seen_file" \
      >/dev/null 2>&1; then
      return 1
    fi
    printf '%s\n' "$verdict_finding_key" >> "$verdict_seen_file" ||
      return 1

    verdict_link_number=$((verdict_link_number + 1))
    verdict_link_dir="$verdict_github_stage_root/link-$verdict_link_number"
    mkdir "$verdict_link_dir" || return 1
    verdict_candidates_file="$verdict_link_dir/candidates.jsonl"
    : > "$verdict_candidates_file"

    if [ "$(printf '%s\n' "$verdict_link" | jq -r 'has("issue")')" = true ]; then
      verdict_query_rc=0
      verdict_github_issue_decision "$verdict_link" "$verdict_link_dir" \
        >> "$verdict_candidates_file" || verdict_query_rc=$?
      case "$verdict_query_rc" in
        0|3) ;;
        *) return 1 ;;
      esac
    fi
    if [ "$(printf '%s\n' "$verdict_link" | jq -r 'has("pr")')" = true ]; then
      verdict_query_rc=0
      verdict_github_pr_decision "$verdict_link" "$verdict_link_dir" \
        >> "$verdict_candidates_file" || verdict_query_rc=$?
      case "$verdict_query_rc" in
        0|3) ;;
        *) return 1 ;;
      esac
    fi

    if ! verdict_github_decision=$(verdict_choose_github_decision \
      "$verdict_candidates_file"); then
      return 1
    fi
    verdict_decision=$(printf '%s\n' "$verdict_link" |
      jq -S -c --argjson observed "$verdict_github_decision" '
        {
          finding_id,
          status: $observed.status,
          actor: $observed.actor,
          source: $observed.source,
          source_ref: $observed.source_ref,
          observed_at: $observed.observed_at,
          repo_full_name
        }
        + (if has("issue") then {issue} else {} end)
        + (if has("pr") then {pr} else {} end)
        + (if $observed | has("rejection_reason") then
            {rejection_reason: $observed.rejection_reason}
          else {} end)
        + (if $observed | has("candidate_sha") then
            {candidate_sha: $observed.candidate_sha}
          else {} end)
      ')
    if ! verdict_decision=$(printf '%s\n' "$verdict_decision" |
      verdict_validate_decision 2>/dev/null); then
      return 1
    fi
    printf '%s\n' "$verdict_decision" >> "$verdict_decisions_file" ||
      return 1
  done < "$verdict_links_file"
}

verdict_transition_allowed() {
  verdict_from=$1
  verdict_to=$2
  verdict_actor=$3
  case "$verdict_from:$verdict_to" in
    open:adopted|open:fixed|open:rejected|adopted:fixed|adopted:rejected)
      return 0
      ;;
    rejected:adopted)
      [ "$verdict_actor" != "$NIGHT_BOT_LOGIN" ]
      return
      ;;
  esac
  return 1
}

verdict_stage_events() {
  verdict_decisions_file=$1
  verdict_current_file=$2
  verdict_events_file=$3
  verdict_draft_queue=$4
  verdict_event_ids_file=$5

  : > "$verdict_events_file"
  : > "$verdict_draft_queue"
  : > "$verdict_event_ids_file"
  while IFS= read -r verdict_decision || [ -n "$verdict_decision" ]; do
    [ -n "$verdict_decision" ] || return 1
    verdict_finding_id=$(printf '%s\n' "$verdict_decision" |
      jq -r '.finding_id')
    if ! verdict_current=$(jq -e -c --arg finding_id "$verdict_finding_id" \
      'select(.id == $finding_id)' "$verdict_current_file"); then
      return 1
    fi

    verdict_from=$(printf '%s\n' "$verdict_current" |
      jq -r '.current_status')
    verdict_to=$(printf '%s\n' "$verdict_decision" | jq -r '.status')
    verdict_actor=$(printf '%s\n' "$verdict_decision" | jq -r '.actor')
    verdict_observed_at=$(printf '%s\n' "$verdict_decision" |
      jq -r '.observed_at')

    verdict_canonical=$(printf '%s\n' "$verdict_decision" | jq -S -c .)
    verdict_hash=$(printf '%s' "$verdict_canonical" | verdict_sha256)
    case "$verdict_hash" in
      ''|*[!0-9a-f]*) return 1 ;;
    esac
    [ "${#verdict_hash}" -eq 64 ] || return 1
    verdict_id="verdict-v1-$verdict_hash"

    if grep -F -x -- "$verdict_id" "$verdict_event_ids_file" \
      >/dev/null 2>&1; then
      return 1
    fi
    printf '%s\n' "$verdict_id" >> "$verdict_event_ids_file" || return 1

    verdict_already_recorded=false
    verdict_existing_file=$(ledger_file_path)
    if [ -f "$verdict_existing_file" ]; then
      verdict_existing=$(jq -c --arg verdict_id "$verdict_id" \
        'select(.type == "verdict" and .verdict_id == $verdict_id)' \
        "$verdict_existing_file")
      if [ -n "$verdict_existing" ]; then
        verdict_existing_canonical=$(printf '%s\n' "$verdict_existing" |
          jq -S -c 'del(.type, .verdict_id, .ts)')
        [ "$verdict_existing_canonical" = "$verdict_canonical" ] ||
          return 1
        verdict_already_recorded=true
      fi
    fi

    printf '%s\n' "$verdict_decision" |
      jq -c '{finding_id}' >> "$verdict_draft_queue" || return 1
    if [ "$verdict_from" = "$verdict_to" ]; then
      if [ "$verdict_already_recorded" = true ]; then
        continue
      fi
      return 1
    fi
    verdict_previous_observed=$(printf '%s\n' "$verdict_current" |
      jq -r '.latest_verdict.observed_at // empty')
    if [ -n "$verdict_previous_observed" ] &&
      [[ "$verdict_observed_at" < "$verdict_previous_observed" ||
        "$verdict_observed_at" = "$verdict_previous_observed" ]]; then
      return 1
    fi
    if [ "$verdict_from" = fixed ]; then
      return 1
    fi
    verdict_transition_allowed \
      "$verdict_from" "$verdict_to" "$verdict_actor" || return 1

    if [ "$verdict_already_recorded" = true ]; then
      continue
    fi

    verdict_event=$(printf '%s\n' "$verdict_decision" | jq -S -c \
      --arg verdict_id "$verdict_id" \
      --arg ts "$(nightshift_iso_now)" '
        {
          type: "verdict",
          verdict_id: $verdict_id,
          ts: $ts
        } + .
      ')
    printf '%s\n' "$verdict_event" >> "$verdict_events_file" || return 1
  done < "$verdict_decisions_file"
}

verdict_safe_finding_component() {
  verdict_safe_id=$1
  verdict_safe_hash=$(printf '%s' "$verdict_safe_id" | verdict_sha256)
  case "$verdict_safe_hash" in
    ''|*[!0-9a-f]*) return 1 ;;
  esac
  [ "${#verdict_safe_hash}" -eq 64 ] || return 1
  printf 'finding-%s\n' "$verdict_safe_hash"
}

verdict_markdown_value() {
  verdict_value_json=$1
  verdict_value_key=$2
  printf '%s\n' "$verdict_value_json" |
    jq -r --arg key "$verdict_value_key" '
      .[$key] //
      "TODO / UNVERIFIED"
      | tostring
      | gsub("[\\r\\n\\t]+"; " ")
      | gsub("\\|"; "\\\\|")
    '
}

verdict_render_draft() {
  verdict_projected=$1
  verdict_output=$2
  verdict_template=$3
  verdict_latest=$(printf '%s\n' "$verdict_projected" |
    jq -c '.latest_verdict')
  [ "$verdict_latest" != null ] || return 1

  verdict_finding_id=$(verdict_markdown_value \
    "$verdict_projected" id)
  verdict_status=$(verdict_markdown_value \
    "$verdict_projected" current_status)
  verdict_candidate_sha=$(verdict_markdown_value \
    "$verdict_latest" candidate_sha)
  verdict_implementer=$(verdict_markdown_value \
    "$verdict_latest" implementer)
  verdict_reviewer=$(verdict_markdown_value \
    "$verdict_latest" reviewer)
  verdict_identity_check=$(verdict_markdown_value \
    "$verdict_latest" identity_check)
  verdict_source_ref=$(verdict_markdown_value \
    "$verdict_latest" source_ref)
  verdict_diff_stat=$(verdict_markdown_value \
    "$verdict_latest" diff_stat)

  verdict_done_when_rows=$(printf '%s\n' "$verdict_latest" | jq -r '
    if has("done_when") and (.done_when | length > 0) then
      .done_when[] |
      "| " +
      (.item | gsub("[\\r\\n\\t]+"; " ") | gsub("\\|"; "\\\\|")) +
      " | TODO / UNVERIFIED" +
      (if has("result") then
        " — input hint: " +
        (.result | gsub("[\\r\\n\\t]+"; " ") | gsub("\\|"; "\\\\|"))
      else "" end) +
      " | TODO / UNVERIFIED" +
      (if has("evidence") then
        " — input hint: " +
        (.evidence | gsub("[\\r\\n\\t]+"; " ") | gsub("\\|"; "\\\\|"))
      else "" end) +
      " |"
    else
      "| TODO / UNVERIFIED | TODO / UNVERIFIED | TODO / UNVERIFIED |"
    end
  ')
  verdict_declared_files=$(printf '%s\n' "$verdict_latest" | jq -r '
    if has("declared_files") and (.declared_files | length > 0) then
      .declared_files[] |
      "- `" + (gsub("`"; "\\`")) + "` — TODO / UNVERIFIED against diff"
    else
      "- TODO / UNVERIFIED — no declared files supplied"
    end
  ')

  if (
    while IFS= read -r verdict_template_line ||
      [ -n "$verdict_template_line" ]; do
      case "$verdict_template_line" in
        '{{FINDING_ID}}') printf '%s\n' "$verdict_finding_id" ;;
        '{{CURRENT_STATUS}}') printf '%s\n' "$verdict_status" ;;
        '{{CANDIDATE_SHA}}') printf '%s\n' "$verdict_candidate_sha" ;;
        '{{IMPLEMENTER}}') printf '%s\n' "$verdict_implementer" ;;
        '{{REVIEWER}}') printf '%s\n' "$verdict_reviewer" ;;
        '{{IDENTITY_CHECK}}') printf '%s\n' "$verdict_identity_check" ;;
        '{{SOURCE_REF}}') printf '%s\n' "$verdict_source_ref" ;;
        '{{DONE_WHEN_ROWS}}') printf '%s\n' "$verdict_done_when_rows" ;;
        '{{DECLARED_FILES}}') printf '%s\n' "$verdict_declared_files" ;;
        '{{DIFF_STAT}}') printf '%s\n' "$verdict_diff_stat" ;;
        *) printf '%s\n' "$verdict_template_line" ;;
      esac
    done < "$verdict_template"
  ) > "$verdict_output"; then
    :
  else
    return 1
  fi
}

verdict_publish_drafts() {
  verdict_draft_queue=$1
  verdict_current_file=$2
  verdict_draft_work_dir=$3
  verdict_template=$4
  verdict_publish_manifest="$verdict_draft_work_dir/draft-manifest.jsonl"
  : > "$verdict_publish_manifest"
  verdict_root="$STATE_DIR/verdicts"
  if [ -L "$verdict_root" ]; then
    return 1
  fi
  if [ ! -d "$verdict_root" ]; then
    mkdir "$verdict_root" || return 1
  fi

  while IFS= read -r verdict_draft_item ||
    [ -n "$verdict_draft_item" ]; do
    [ -n "$verdict_draft_item" ] || return 1
    verdict_finding_id=$(printf '%s\n' "$verdict_draft_item" |
      jq -r '.finding_id')
    if ! verdict_projected=$(jq -e -c --arg finding_id \
      "$verdict_finding_id" 'select(.id == $finding_id)' \
      "$verdict_current_file"); then
      return 1
    fi
    verdict_safe_component=$(verdict_safe_finding_component \
      "$verdict_finding_id") || return 1
    verdict_staged_draft="$verdict_draft_work_dir/$verdict_safe_component.md"
    verdict_render_draft \
      "$verdict_projected" \
      "$verdict_staged_draft" \
      "$verdict_template" || return 1
    jq -n -c \
      --arg staged "$verdict_staged_draft" \
      --arg component "$verdict_safe_component" \
      '{staged: $staged, component: $component}' \
      >> "$verdict_publish_manifest" || return 1
  done < "$verdict_draft_queue"

  while IFS= read -r verdict_publish_item ||
    [ -n "$verdict_publish_item" ]; do
    [ -n "$verdict_publish_item" ] || return 1
    verdict_staged_draft=$(printf '%s\n' "$verdict_publish_item" |
      jq -r '.staged')
    verdict_safe_component=$(printf '%s\n' "$verdict_publish_item" |
      jq -r '.component')
    verdict_target_dir="$verdict_root/$verdict_safe_component"
    if [ -L "$verdict_target_dir" ]; then
      return 1
    fi
    if [ ! -d "$verdict_target_dir" ]; then
      mkdir "$verdict_target_dir" || return 1
    fi
    verdict_target_file="$verdict_target_dir/L1-7-draft.md"
    if [ -L "$verdict_target_file" ] || [ -d "$verdict_target_file" ]; then
      return 1
    fi
    mv "$verdict_staged_draft" \
      "$verdict_target_file" || return 1
  done < "$verdict_publish_manifest"
}
