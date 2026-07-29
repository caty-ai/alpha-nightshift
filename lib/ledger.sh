#!/bin/bash
set -euo pipefail

ledger_file_path() {
  printf '%s\n' "$STATE_DIR/ledger/ledger.jsonl"
}

ledger_append() {
  input_json=$1
  if ! printf '%s\n' "$input_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    return 1
  fi
  if ! compact_json=$(printf '%s\n' "$input_json" | jq -c . 2>/dev/null); then
    return 1
  fi

  case "$compact_json" in
    *'
'*) return 1 ;;
  esac

  if ! mkdir -p "$STATE_DIR/ledger"; then
    return 1
  fi
  if ! printf '%s\n' "$compact_json" >> "$(ledger_file_path)"; then
    return 1
  fi
}

ledger_append_batch() {
  batch_file=$1
  [ -s "$batch_file" ] || return 0

  if ! awk 'NF == 0 { exit 1 }' "$batch_file"; then
    return 1
  fi
  if ! jq -e -s 'length > 0 and all(.[]; type == "object")' \
    "$batch_file" >/dev/null 2>&1; then
    return 1
  fi

  if ! mkdir -p "$STATE_DIR/ledger"; then
    return 1
  fi
  if ! command cat "$batch_file" >> "$(ledger_file_path)"; then
    return 1
  fi
}

ledger_query_night() {
  query_night_id=$1
  query_type=${2:-}
  ledger_file=$(ledger_file_path)
  [ -f "$ledger_file" ] || return 0

  if [ -n "$query_type" ]; then
    jq -c --arg night_id "$query_night_id" --arg record_type "$query_type" \
      'select(type == "object" and .night_id == $night_id and .type == $record_type)' "$ledger_file"
  else
    jq -c --arg night_id "$query_night_id" \
      'select(type == "object" and .night_id == $night_id)' "$ledger_file"
  fi
}

ledger_validate_jsonl_shape() {
  validate_ledger_file=$(ledger_file_path)
  [ -f "$validate_ledger_file" ] || return 0
  [ -s "$validate_ledger_file" ] || return 0

  if ! awk 'NF == 0 { exit 1 }' "$validate_ledger_file"; then
    return 1
  fi
  validate_last_byte=$(tail -c 1 "$validate_ledger_file" |
    od -An -tx1 |
    tr -d '[:space:]')
  [ "$validate_last_byte" = 0a ] || return 1
  jq -e -s 'all(.[]; type == "object" and (.type | type == "string"))' \
    "$validate_ledger_file" >/dev/null 2>&1
}

ledger_project_findings() {
  project_ledger_file=$(ledger_file_path)
  [ -f "$project_ledger_file" ] || return 0
  ledger_validate_jsonl_shape || return 1

  jq -c -s --arg night_bot_login "${NIGHT_BOT_LOGIN:-night-bot}" '
    def utc_timestamp:
      . as $timestamp |
      type == "string" and
      test("^[0-9]{4}-(0[1-9]|1[0-2])-([0-2][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z$") and
      ((try (fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ"))
        catch null) == $timestamp);
    def nonempty_string:
      type == "string" and length > 0;
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
    def finding_valid:
      type == "object" and
      ((keys_unsorted - [
        "id", "repo", "target", "symptom", "kind", "confirm_cost", "date",
        "interpretation", "persona", "evidence", "ts", "night_id", "type",
        "status"
      ]) | length == 0) and
      .type == "finding" and
      (.id | nonempty_string) and
      (.repo | nonempty_string) and
      (.target | nonempty_string) and
      (.symptom | nonempty_string) and
      (.kind | nonempty_string) and
      (.confirm_cost == "即断" or .confirm_cost == "1分" or
        .confirm_cost == "3分") and
      (.date | nonempty_string) and
      (.ts | nonempty_string) and
      (.night_id | nonempty_string) and
      .status == "open" and
      ((has("interpretation") | not) or
        (.interpretation | type == "string")) and
      ((has("persona") | not) or (.persona | type == "string")) and
      ((has("evidence") | not) or
        (.evidence | type == "array" and all(.[]; safe_relative_path)));
    def verdict_valid:
      . as $verdict |
      type == "object" and
      ((keys_unsorted - [
        "type", "verdict_id", "ts", "finding_id", "status", "actor",
        "source", "source_ref", "observed_at", "rejection_reason",
        "repo_full_name", "issue", "pr", "candidate_sha", "implementer",
        "reviewer", "identity_check", "done_when", "declared_files",
        "diff_stat"
      ]) | length == 0) and
      .type == "verdict" and
      (.verdict_id | nonempty_string) and
      (.ts | utc_timestamp) and
      (.finding_id | nonempty_string) and
      (.status == "adopted" or .status == "fixed" or
        .status == "rejected" or .status == "deferred" or
        .status == "regression") and
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
      all(["implementer", "reviewer", "identity_check", "diff_stat"][];
        . as $name |
        (($verdict | has($name) | not) or
          ($verdict[$name] | nonempty_string))) and
      ((has("done_when") | not) or (.done_when | done_when_valid)) and
      ((has("declared_files") | not) or
        (.declared_files | type == "array" and all(.[]; safe_relative_path)));
    def transition_allowed($from; $to; $actor):
      ($from == "open" and
        ($to == "adopted" or $to == "fixed" or $to == "rejected" or
          $to == "deferred")) or
      ($from == "adopted" and
        ($to == "fixed" or $to == "rejected" or $to == "deferred")) or
      ($from == "deferred" and
        ($to == "adopted" or $to == "fixed" or $to == "rejected")) or
      ($from == "rejected" and $to == "adopted" and
        $actor != $night_bot_login) or
      ($from == "fixed" and $to == "regression") or
      ($from == "regression" and
        ($to == "adopted" or $to == "fixed" or $to == "rejected" or
          $to == "deferred"));

    reduce .[] as $record (
      {findings: {}, verdict_ids: {}, error: null};
      if .error != null then
        .
      elif $record.type == "finding" then
        if (
          ($record | finding_valid) and
          (.findings[$record.id] == null)
        ) then
          .findings[$record.id] = {
            base: $record,
            current_status: "open",
            latest_verdict: null,
            last_observed_at: null
          }
        else
          .error = "malformed or duplicate finding record"
        end
      elif $record.type == "verdict" then
        if ($record | verdict_valid | not) then
          .error = "malformed verdict record"
        elif .verdict_ids[$record.verdict_id] != null then
          .error = "duplicate verdict identity"
        elif .findings[$record.finding_id] == null then
          .error = "verdict references unknown finding"
        elif .findings[$record.finding_id].current_status == $record.status then
          .error = "redundant verdict event"
        elif (
          .findings[$record.finding_id].last_observed_at != null and
          $record.observed_at <=
            .findings[$record.finding_id].last_observed_at
        ) then
          .error = "stale verdict event"
        elif (
          transition_allowed(
            .findings[$record.finding_id].current_status;
            $record.status;
            $record.actor
          ) | not
        ) then
          .error = "illegal verdict transition"
        else
          .verdict_ids[$record.verdict_id] = true |
          .findings[$record.finding_id].current_status = $record.status |
          .findings[$record.finding_id].latest_verdict = $record |
          .findings[$record.finding_id].last_observed_at =
            $record.observed_at
        end
      else
        .
      end
    )
    | if .error != null then
        error(.error)
      else
        [
          .findings[] |
          .base + {
            base_status: .base.status,
            status: .current_status,
            current_status: .current_status,
            latest_verdict: .latest_verdict
          }
        ]
        | sort_by(.id)
        | .[]
      end
  ' "$project_ledger_file"
}

ledger_current_findings() {
  ledger_project_findings
}

ledger_get_current_finding() {
  current_finding_id=$1
  ledger_project_findings |
    jq -e -c --arg finding_id "$current_finding_id" \
      'select(.id == $finding_id)'
}

ledger_ingest_proposals() {
  proposal_file=$1
  LEDGER_INGESTED_COUNT=0
  LEDGER_SKIPPED_COUNT=0
  LEDGER_DUPLICATE_COUNT=0
  [ -f "$proposal_file" ] || return 0

  if ! existing_ids_file=$(mktemp "$STATE_DIR/.finding-ids.XXXXXX"); then
    return 1
  fi
  ledger_file=$(ledger_file_path)
  if [ -f "$ledger_file" ]; then
    if ! jq -r '
      select(
        type == "object" and
        .type == "finding" and
        (.id | type == "string")
      )
      | .id
    ' "$ledger_file" > "$existing_ids_file"; then
      rm -f "$existing_ids_file"
      return 1
    fi
  fi

  while IFS= read -r proposal_line || [ -n "$proposal_line" ]; do
    if [ -z "$proposal_line" ]; then
      continue
    fi

    if ! validated=$(printf '%s\n' "$proposal_line" | jq -e -c '
      select(
        type == "object" and
        (.id | type == "string" and length > 0) and
        (.repo | type == "string" and length > 0) and
        (.target | type == "string" and length > 0) and
        (.symptom | type == "string" and length > 0) and
        (.kind | type == "string" and length > 0) and
        (.confirm_cost | type == "string" and
          (. == "即断" or . == "1分" or . == "3分")) and
        (.date | type == "string" and length > 0) and
        ((has("interpretation") | not) or
          (.interpretation | type == "string")) and
        ((has("persona") | not) or
          (.persona | type == "string")) and
        ((has("evidence") | not) or
          (.evidence | type == "array" and all(.[];
            type == "string" and
            length > 0 and
            (startswith("/") | not) and
            (startswith("//") | not) and
            (test("^[A-Za-z][A-Za-z0-9+.-]*:") | not) and
            (test("(^|/)\\.\\.?(?:/|$)") | not)
          )))
      )
      | {
          id: .id,
          repo: .repo,
          target: .target,
          symptom: .symptom,
          kind: .kind,
          confirm_cost: .confirm_cost,
          date: .date
        }
        + (if has("interpretation") then
            {interpretation: .interpretation}
          else {} end)
        + (if has("persona") then
            {persona: .persona}
          else {} end)
        + (if has("evidence") then
            {evidence: .evidence}
          else {} end)
    ' 2>/dev/null); then
      LEDGER_SKIPPED_COUNT=$((LEDGER_SKIPPED_COUNT + 1))
      nightshift_log WARN "Skipping malformed finding proposal in $proposal_file"
      continue
    fi

    proposal_id=$(printf '%s\n' "$validated" | jq -r '.id')
    if grep -F -x -- "$proposal_id" "$existing_ids_file" >/dev/null 2>&1; then
      LEDGER_DUPLICATE_COUNT=$((LEDGER_DUPLICATE_COUNT + 1))
      continue
    fi

    finding_record=$(printf '%s\n' "$validated" | jq -c \
      --arg ts "$(nightshift_iso_now)" \
      --arg night_id "$NIGHT_ID" \
      '. + {ts: $ts, night_id: $night_id, type: "finding", status: "open"}')
    if ! ledger_append "$finding_record"; then
      rm -f "$existing_ids_file"
      return 1
    fi
    if ! printf '%s\n' "$proposal_id" >> "$existing_ids_file"; then
      rm -f "$existing_ids_file"
      return 1
    fi
    LEDGER_INGESTED_COUNT=$((LEDGER_INGESTED_COUNT + 1))
  done < "$proposal_file"
  rm -f "$existing_ids_file"
}
