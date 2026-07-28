#!/bin/bash
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_exists() {
  [ -f "$1" ] || fail "expected file: $1"
}

assert_contains() {
  expected=$1
  file=$2
  if ! grep -F "$expected" "$file" >/dev/null 2>&1; then
    printf '%s\n' "--- $file ---" >&2
    sed -n '1,80p' "$file" >&2
    fail "expected '$expected' in $file"
  fi
}

assert_not_contains() {
  unexpected=$1
  file=$2
  if grep -F "$unexpected" "$file" >/dev/null 2>&1; then
    fail "did not expect '$unexpected' in $file"
  fi
}

assert_ledger_record() {
  ledger=$1
  night_id=$2
  record_type=$3
  reason=${4:-}
  if [ -n "$reason" ]; then
    jq -e --arg night_id "$night_id" --arg type "$record_type" --arg reason "$reason" \
      'select(.night_id == $night_id and .type == $type and .reason == $reason)' \
      "$ledger" >/dev/null || fail "missing ledger record $record_type/$reason"
  else
    jq -e --arg night_id "$night_id" --arg type "$record_type" \
      'select(.night_id == $night_id and .type == $type)' \
      "$ledger" >/dev/null || fail "missing ledger record $record_type"
  fi
}
