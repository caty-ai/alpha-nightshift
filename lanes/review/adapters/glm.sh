#!/bin/bash
set -euo pipefail

[ "$#" -eq 3 ] || exit 2
prompt_file=$1
workdir=$2
out_dir=$3
candidate_file="$out_dir/candidates.jsonl"
request_file="$out_dir/glm-request.json"
response_file="$out_dir/glm-response.json"
key_file=${GLM_KEY_FILE:-}
api_url=https://api.z.ai/api/anthropic/v1/messages
max_tokens=${REVIEW_GLM_MAX_TOKENS:-4096}
model=${REVIEW_GLM_MODEL:-glm-5.3}
curl_bin=${REVIEW_CURL_BIN:-/usr/bin/curl}

[ -d "$out_dir" ] && [ ! -L "$out_dir" ] || exit 2
[ -d "$workdir" ] && [ ! -L "$workdir" ] || exit 2
for adapter_path in "$request_file" "$response_file" "$candidate_file"; do
  [ ! -L "$adapter_path" ] || exit 2
  if [ -e "$adapter_path" ] && [ ! -f "$adapter_path" ]; then exit 2; fi
done

case "$key_file" in
  /*) ;;
  *) printf '%s\n' 'glm: GLM_KEY_FILE must be absolute' >&2; exit 2 ;;
esac
[ -f "$key_file" ] && [ ! -L "$key_file" ] || {
  printf '%s\n' 'glm: GLM_KEY_FILE must be a regular non-symlink file' >&2
  exit 2
}
[[ "$model" =~ ^[A-Za-z0-9._-]+$ ]] || {
  printf '%s\n' 'glm: REVIEW_GLM_MODEL contains unsupported characters' >&2
  exit 2
}
case "$max_tokens" in
  ''|*[!0-9]*) printf '%s\n' 'glm: max tokens must be an integer' >&2; exit 2 ;;
esac
[ "$max_tokens" -gt 0 ] && [ "$max_tokens" -le 16384 ] || {
  printf '%s\n' 'glm: max tokens must be between 1 and 16384' >&2
  exit 2
}
if ! key_mode=$(stat -f '%Lp' "$key_file" 2>/dev/null); then
  printf '%s\n' 'glm: cannot inspect GLM_KEY_FILE permissions' >&2
  exit 2
fi
group_world_digits=${key_mode#?}
case "$group_world_digits" in
  ??) ;;
  *)
    printf '%s\n' 'glm: cannot interpret GLM_KEY_FILE permissions' >&2
    exit 2
    ;;
esac
group_digit=${group_world_digits%?}
world_digit=${group_world_digits#?}
case "$group_digit$world_digit" in
  [4-7]?|?[4-7])
    printf '%s\n' 'glm: GLM_KEY_FILE must not be group- or world-readable' >&2
    exit 2
    ;;
esac

glm_key=$(sed -n '1p' "$key_file")
case "$glm_key" in
  'export '*)
    printf '%s\n' 'glm: GLM_KEY_FILE must not use an export prefix' >&2
    exit 2
    ;;
  *=*=*)
    printf '%s\n' 'glm: GLM_KEY_FILE must not contain more than one equals sign' >&2
    exit 2
    ;;
  *=*)
    [[ "${glm_key%%=*}" =~ ^[A-Z][A-Z0-9_]*$ ]] || {
      printf '%s\n' 'glm: GLM_KEY_FILE NAME must match ^[A-Z][A-Z0-9_]*$' >&2
      exit 2
    }
    glm_key=${glm_key#*=}
    ;;
esac
[ -n "$glm_key" ] || {
  printf '%s\n' 'glm: GLM_KEY_FILE has an empty value' >&2
  exit 2
}
case "$glm_key" in
  *\"*|*\'*)
    printf '%s\n' 'glm: GLM_KEY_FILE must not use a quoted value' >&2
    exit 2
    ;;
  *[!A-Za-z0-9._-]*)
    printf '%s\n' 'glm: GLM_KEY_FILE contains unsupported characters' >&2
    exit 2
    ;;
esac

jq -n \
  --arg model "$model" \
  --arg prompt "$(cat "$prompt_file")" \
  --argjson max_tokens "$max_tokens" \
  '{model:$model,max_tokens:$max_tokens,messages:[{role:"user",content:$prompt}]}' \
  > "$request_file"

rc=0
set +e
(
  cd "$out_dir"
  printf '%s\n' \
    'silent' \
    'show-error' \
    'fail' \
    "url = \"$api_url\"" \
    'request = "POST"' \
    'header = "content-type: application/json"' \
    'header = "anthropic-version: 2023-06-01"' \
    "header = \"x-api-key: $glm_key\"" \
    'data-binary = "@glm-request.json"' |
    "$curl_bin" -q --config -
) | tee "$response_file"
rc=$?
set -e
unset glm_key

if [ "$rc" -ne 0 ]; then
  exit "$rc"
fi
[ ! -L "$candidate_file" ] || exit 2
if [ -e "$candidate_file" ] && [ ! -f "$candidate_file" ]; then exit 2; fi
if ! jq -e -r '
  select(type == "object")
  | .content
  | select(type == "array")
  | map(select(type == "object" and .type == "text" and (.text | type == "string")) | .text)
  | select(length > 0)
  | join("\n")
' "$response_file" > "$candidate_file"; then
  printf '%s\n' 'glm: response did not contain Anthropic-compatible text content' >&2
  exit 1
fi
