#!/bin/bash
set -euo pipefail

fixture_root=${OC_SUGGEST_FAKE_GH_DIR:-}
[ -n "$fixture_root" ] || exit 2
mkdir -p "$fixture_root"

method=GET
endpoint=
input_path=

while [ "$#" -gt 0 ]; do
  case "$1" in
    api)
      shift
      ;;
    --method)
      method=$2
      shift 2
      ;;
    --input)
      input_path=$2
      shift 2
      ;;
    --*)
      shift
      ;;
    *)
      endpoint=$1
      shift
      ;;
  esac
done

[ "$method" = POST ] || exit 2
case "$endpoint" in
  repos/*/issues) ;;
  *) exit 2 ;;
esac
[ -n "$input_path" ] || exit 2

body=$(jq -r '.body // ""' "$input_path")
title=$(jq -r '.title // ""' "$input_path")
repo=${endpoint#repos/}
repo=${repo%/issues}

counter_file="$fixture_root/.issue-counter"
if [ -f "$counter_file" ]; then
  counter=$(cat "$counter_file")
else
  counter=40
fi
counter=$((counter + 1))
printf '%s\n' "$counter" > "$counter_file"

if [ -n "${OC_SUGGEST_FAKE_GH_LOG:-}" ]; then
  jq -n -c \
    --arg method "$method" \
    --arg endpoint "$endpoint" \
    --arg title "$title" \
    --arg body "$body" \
    '{method:$method, endpoint:$endpoint, title:$title, body:$body}' \
    >> "$OC_SUGGEST_FAKE_GH_LOG"
fi

jq -n \
  --argjson number "$counter" \
  --arg html_url "https://github.test/$repo/issues/$counter" \
  '{number:$number, html_url:$html_url}'
