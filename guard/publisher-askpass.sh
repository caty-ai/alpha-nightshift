#!/bin/bash -p
set -euo pipefail

prompt=${1-}
IFS= read -r expected_prompt <&3 || {
  printf '%s: %s\n' "LOCAL_ONLY_REMOTE_UNPROVEN" \
    "missing inherited Git prompt expectation" >&2
  exit 1
}
[ "$prompt" = "$expected_prompt" ] || {
  printf '%s: %s\n' "LOCAL_ONLY_REMOTE_UNPROVEN" \
    "unexpected Git askpass prompt" >&2
  exit 1
}

IFS= read -r token <&3 || {
  printf '%s: %s\n' "LOCAL_ONLY_REMOTE_UNPROVEN" \
    "missing inherited Git credential payload" >&2
  exit 1
}

printf '%s\n' "$token"
