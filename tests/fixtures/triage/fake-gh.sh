#!/bin/bash
set -euo pipefail

fixture_root=${TRIAGE_FAKE_GH_DIR:-${FAKE_GH_FIXTURE_DIR:-}}
[ -n "$fixture_root" ] || exit 2
mkdir -p "$fixture_root/get" "$fixture_root/dynamic" "$fixture_root/fail"

method=GET
endpoint=
body=
while [ "$#" -gt 0 ]; do
  case "$1" in
    api) shift ;;
    --method)
      method=$2
      shift 2
      ;;
    --input)
      if [ "$2" = - ]; then
        body=$(jq -e -r \
          'select(type == "object" and (.body | type == "string")) | .body')
      else
        body=$(jq -e -r \
          'select(type == "object" and (.body | type == "string")) | .body' \
          "$2")
      fi
      shift 2
      ;;
    -F|--field)
      case "$2" in
        body=@*) body=$(cat "${2#body=@}") ;;
        body=*) body=${2#body=} ;;
      esac
      shift 2
      ;;
    -f|--raw-field)
      case "$2" in
        body@-) body=$(cat) ;;
        body=*) body=${2#body=} ;;
      esac
      shift 2
      ;;
    --*) shift ;;
    *) endpoint=$1; shift ;;
  esac
done
[ -n "$endpoint" ] || exit 2

endpoint_sha=$(printf '%s' "$endpoint" | shasum -a 256 | awk '{print $1}')
method_lc=$(printf '%s' "$method" | tr '[:upper:]' '[:lower:]')
if [ -n "${TRIAGE_FAKE_GH_LOG:-${FAKE_GH_LOG:-}}" ]; then
  log_file=${TRIAGE_FAKE_GH_LOG:-${FAKE_GH_LOG:-}}
  jq -n -c \
    --arg method "$method" \
    --arg endpoint "$endpoint" \
    --arg body "$body" \
    '{method:$method,endpoint:$endpoint,body:$body}' >> "$log_file"
fi

if [ -f "$fixture_root/fail/$method_lc-$endpoint_sha.status" ]; then
  [ ! -f "$fixture_root/fail/$method_lc-$endpoint_sha.body" ] ||
    cat "$fixture_root/fail/$method_lc-$endpoint_sha.body"
  exit "$(cat "$fixture_root/fail/$method_lc-$endpoint_sha.status")"
fi

case "$method:$endpoint" in
  GET:repos/*/issues/*)
    if [ "${FAKE_GH_ISSUE_IS_PR:-0}" = 1 ]; then
      jq -n '{id:123,number:123,pull_request:{url:"x"}}'
    elif [ -f "$fixture_root/get/$endpoint_sha.json" ]; then
      cat "$fixture_root/get/$endpoint_sha.json"
    else
      jq -n '{id:123,number:123,title:"auto-triage report sink"}'
    fi
    ;;
  GET:https://api.github.test/comments/*)
    [ "${FAKE_GH_FAIL_GET_COMMENT:-0}" != 1 ] || exit 1
    [ -f "$fixture_root/dynamic/$endpoint_sha.json" ] || exit 1
    cat "$fixture_root/dynamic/$endpoint_sha.json"
    ;;
  POST:repos/*/issues/*/comments)
    [ "${FAKE_GH_FAIL_POST:-0}" != 1 ] || exit 1
    counter_file="$fixture_root/.comment-counter"
    if [ -f "$counter_file" ]; then counter=$(cat "$counter_file"); else counter=0; fi
    counter=$((counter + 1))
    printf '%s\n' "$counter" > "$counter_file"
    api_url="https://api.github.test/comments/$counter"
    html_url="https://github.test/comments/$counter"
    get_sha=$(printf '%s' "$api_url" | shasum -a 256 | awk '{print $1}')
    jq -n \
      --argjson id "$counter" \
      --arg url "$api_url" \
      --arg html_url "$html_url" \
      --arg body "$body" \
      '{id:$id,url:$url,html_url:$html_url,body:$body}' \
      > "$fixture_root/dynamic/$get_sha.json"
    jq -n --argjson id "$counter" --arg url "$api_url" \
      '{id:$id,url:$url}'
    ;;
  *) exit 2 ;;
esac
