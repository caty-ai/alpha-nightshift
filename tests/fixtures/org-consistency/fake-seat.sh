#!/bin/bash
set -euo pipefail

prompt=$(/bin/cat)
mode=${OC_FAKE_SEAT_MODE:-valid}

case "$mode" in
  assert-input)
    if printf '%s\n' "$prompt" | grep -q '{{INPUT_JSON}}'; then
      printf '%s\n' 'unexpanded prompt placeholder' >&2
      exit 3
    fi
    if printf '%s\n' "$prompt" | grep -q '"launch": "OC-H"'; then
      for field in agent_docs handbook_index repository; do
        printf '%s\n' "$prompt" | grep -q "\"$field\"" || exit 4
      done
    else
      for field in api_description registry_entry readme_hero tree make_targets workflows; do
        printf '%s\n' "$prompt" | grep -q "\"$field\"" || exit 4
      done
    fi
    printf '%s\n' '{"findings":[]}'
    ;;
  valid|valid-ja|cwd)
    if printf '%s\n' "$prompt" | grep -q '"launch": "OC-H"'; then
      printf '{"findings":[{"check_id":"OC-H","file":"AGENTS.md","rule_id":"A1","target_token":"commit-check","claim":"handbook procedure drift","evidence":"cwd=%s","confidence":"medium"}]}\n' "$PWD"
    else
      e_file=README.md
      [ "$mode" = valid-ja ] && e_file=README.ja.md
      printf '{"findings":[{"check_id":"OC-E","file":"%s","pair":"api-readme","claim":"description drift","evidence":"cwd=%s","confidence":"high"}]}\n' "$e_file" "$PWD"
    fi
    ;;
  empty)
    printf '%s\n' '{"findings":[]}'
    ;;
  invalid-json)
    printf '%s\n' '{broken'
    ;;
  extra-field)
    printf '%s\n' '{"findings":[],"fingerprint":"forged"}'
    ;;
  fake-fingerprint)
    printf '%s\n' '{"findings":[{"check_id":"OC-E","file":"README.md","pair":"api-readme","claim":"description drift","evidence":"fixture","confidence":"high","fingerprint":"forged"}]}'
    ;;
  huge-claim)
    /usr/bin/python3 - <<'PY'
import json
print(json.dumps({"findings": [{
    "check_id": "OC-E",
    "file": "README.md",
    "pair": "api-readme",
    "claim": "x" * 501,
    "evidence": "fixture",
    "confidence": "high",
}]}))
PY
    ;;
  non-utf8)
    /usr/bin/python3 -c 'import sys; sys.stdout.buffer.write(b"\xff\xfe not-json")'
    ;;
  deep-nest)
    /usr/bin/python3 -c 'print("[" * 100000)'
    ;;
  timeout)
    sleep 3
    printf '%s\n' '{"findings":[]}'
    ;;
  *)
    printf 'unknown fake seat mode: %s\n' "$mode" >&2
    exit 2
    ;;
esac
