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
        (.date | type == "string" and length > 0)
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
