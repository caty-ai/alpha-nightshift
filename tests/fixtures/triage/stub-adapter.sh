#!/bin/bash
set -euo pipefail

[ "$#" -eq 3 ] || exit 2
prompt_file=$1
workdir=$2
out_dir=$3

[ -f "$prompt_file" ] && [ -d "$workdir" ] && [ -d "$out_dir" ] || exit 2

if [ "${TRIAGE_STUB_SLEEP_SEC:-0}" -gt 0 ]; then
  sleep "$TRIAGE_STUB_SLEEP_SEC"
fi
[ "${TRIAGE_STUB_FAIL:-0}" != 1 ] || exit 97

candidate_file="$out_dir/candidates.jsonl"
response_file="$out_dir/response.txt"
[ ! -L "$candidate_file" ] && [ ! -L "$response_file" ] || exit 2

: > "$candidate_file"
if [ -n "${TRIAGE_STUB_QUEUE_FILE:-}" ]; then
  [ -f "$TRIAGE_STUB_QUEUE_FILE" ] || exit 2
  queue_lock="$TRIAGE_STUB_QUEUE_FILE.lock"
  queue_tries=0
  until mkdir "$queue_lock" 2>/dev/null; do
    queue_tries=$((queue_tries + 1))
    [ "$queue_tries" -lt 200 ] || exit 2
    sleep 0.05
  done
  response_path=$(sed -n '1p' "$TRIAGE_STUB_QUEUE_FILE")
  if [ -z "$response_path" ] || [ ! -f "$response_path" ]; then
    rmdir "$queue_lock" 2>/dev/null || true
    exit 98
  fi
  queue_tmp="$TRIAGE_STUB_QUEUE_FILE.tmp.$$"
  sed '1d' "$TRIAGE_STUB_QUEUE_FILE" > "$queue_tmp"
  mv "$queue_tmp" "$TRIAGE_STUB_QUEUE_FILE"
  rmdir "$queue_lock" 2>/dev/null || true
  cp "$response_path" "$candidate_file"
elif [ -n "${TRIAGE_STUB_RESPONSE_TABLE:-}" ]; then
  [ -f "$TRIAGE_STUB_RESPONSE_TABLE" ] || exit 2
  while IFS="$(printf '\t')" read -r phase finding_id response ||
    [ -n "$phase$finding_id$response" ]; do
    [ -n "$finding_id" ] || continue
    grep -F -- "\"$finding_id\"" "$prompt_file" >/dev/null 2>&1 || continue
    case "$phase" in
      verify)
        grep -F 'ALREADY_FIXED' "$prompt_file" >/dev/null 2>&1 || continue
        ;;
      dedup)
        grep -F 'DUPLICATE' "$prompt_file" >/dev/null 2>&1 || continue
        ;;
      *) exit 2 ;;
    esac
    printf '%s\n' "$response" >> "$candidate_file"
  done < "$TRIAGE_STUB_RESPONSE_TABLE"
elif [ -n "${TRIAGE_STUB_RESPONSES:-}" ]; then
  [ -f "$TRIAGE_STUB_RESPONSES" ] || exit 2
  jq -r --rawfile prompt "$prompt_file" '
    select($prompt | contains("\"" + .finding_id + "\"")) |
    if has("raw") then .raw else (.response | tojson) end
  ' "$TRIAGE_STUB_RESPONSES" > "$candidate_file"
elif [ -n "${TRIAGE_STUB_DEFAULT_RESPONSE:-}" ]; then
  cp "$TRIAGE_STUB_DEFAULT_RESPONSE" "$candidate_file"
else
  exit 99
fi
cp "$candidate_file" "$response_file"

if [ -n "${TRIAGE_STUB_LOG_FILE:-}" ]; then
  jq -n -c \
    --arg prompt_file "$prompt_file" \
    --arg workdir "$workdir" \
    --arg out_dir "$out_dir" \
    '{prompt_file:$prompt_file,workdir:$workdir,out_dir:$out_dir}' \
    >> "$TRIAGE_STUB_LOG_FILE"
fi
