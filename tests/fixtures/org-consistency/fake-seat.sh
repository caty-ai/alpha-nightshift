#!/bin/bash
# shellcheck disable=SC2016
set -euo pipefail

prompt=$(/bin/cat)
mode=${OC_FAKE_SEAT_MODE:-valid}

seat_launch() {
  if printf '%s\n' "$prompt" | grep -q '"launch": "OC-H"'; then
    printf '%s\n' OC-H
  elif printf '%s\n' "$prompt" | grep -q '"launch": "OC-I/J"'; then
    printf '%s\n' OC-I/J
  else
    printf '%s\n' OC-E/F/G
  fi
}

seat_repository() {
  printf '%s\n' "$prompt" |
    sed -n 's/^[[:space:]]*"name": "\([^"]*\)"[,]*$/\1/p' |
    head -n 1
}

emit_valid_for_launch() {
  launch=$(seat_launch)
  case "$launch" in
    OC-H)
      printf '{"findings":[{"check_id":"OC-H","file":"AGENTS.md","rule_id":"FP-1","target_token":"issue-first","claim":"handbook procedure drift","evidence":"cwd=%s","confidence":"medium"}]}\n' "$PWD"
      ;;
    OC-I/J)
      printf '{"findings":[{"check_id":"OC-I","file":"README.md","gate_item":1,"claim":"environment table is missing","evidence":"fixture","confidence":"medium"},{"check_id":"OC-J","file":"README.md","score":2,"claim":"score 2: purpose is unclear","evidence":"fixture","confidence":"medium"}]}\n'
      ;;
    *)
      printf '{"findings":[{"check_id":"OC-E","file":"README.md","pair":"api-readme","claim":"description drift","evidence":"cwd=%s","confidence":"high"}]}\n' "$PWD"
      ;;
  esac
}

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
  selective-valid)
    repository=$(seat_repository)
    if [ -n "${OC_FAKE_SEAT_FAIL_REPO:-}" ] && [ "$repository" = "$OC_FAKE_SEAT_FAIL_REPO" ]; then
      printf 'permanent fixture failure for %s (%s)\n' "$repository" "$(seat_launch)" >&2
      exit 9
    fi
    emit_valid_for_launch
    ;;
  ij-assert-input)
    [ "$(seat_launch)" = OC-I/J ] || exit 4
    for field in readme_gate readmes repository; do
      printf '%s\n' "$prompt" | grep -q "\"$field\"" || exit 4
    done
    if printf '%s\n' "$prompt" | grep -q '"agent_docs"'; then
      exit 4
    fi
    if ! printf '%s\n' "$prompt" | grep -q '"gate_items"'; then
      exit 4
    fi
    printf '%s\n' "$prompt" | grep -q 'Score honestly; do not consider how the score will be' || exit 4
    if printf '%s\n' "$prompt" | grep -q 'accepts it as a finding'; then
      exit 4
    fi
    printf '%s\n' '{"findings":[]}'
    ;;
  ij-quickstart-fence)
    [ "$(seat_launch)" = OC-I/J ] || exit 4
    for lead in '## Quick start' 'Prerequisite:' '### Installation' '### Minimum configuration' '### First invocation'; do
      printf '%s\n' "$prompt" | grep -q "$lead" || exit 4
    done
    if printf '%s\n' "$prompt" | grep -q './bin/nightshift fixture-command'; then
      printf '%s\n' 'fenced command leaked into OC-I/J input' >&2
      exit 4
    fi
    if printf '%s\n' "$prompt" | grep -q 'copied as written'; then
      printf '%s\n' '{"findings":[{"check_id":"OC-I","file":"README.md","gate_item":9,"claim":"first invocation cannot be copied from the supplied README","evidence":"fenced command body is not supplied","confidence":"high"},{"check_id":"OC-J","file":"README.md","score":3,"claim":"score 3: quick-start leads are understandable","evidence":"fixture","confidence":"medium"}]}'
    else
      printf '%s\n' '{"findings":[{"check_id":"OC-J","file":"README.md","score":3,"claim":"score 3: quick-start leads are understandable","evidence":"fixture","confidence":"medium"}]}'
    fi
    ;;
  ij-score-3)
    [ "$(seat_launch)" = OC-I/J ] || exit 4
    printf '%s\n' '{"findings":[{"check_id":"OC-J","file":"README.md","score":3,"claim":"score 3: understandable after a short scan","evidence":"fixture","confidence":"medium"}]}'
    ;;
  ij-score-2)
    [ "$(seat_launch)" = OC-I/J ] || exit 4
    printf '%s\n' '{"findings":[{"check_id":"OC-J","file":"README.md","score":2,"claim":"score 2: purpose is unclear","evidence":"fixture","confidence":"medium"}]}'
    ;;
  ij-valid)
    [ "$(seat_launch)" = OC-I/J ] || exit 4
    emit_valid_for_launch
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
  bad-target-token)
    if [ "$(seat_launch)" = OC-H ]; then
      printf '%s\n' '{"findings":[{"check_id":"OC-H","file":"AGENTS.md","rule_id":"A1","target_token":"$HOME","claim":"handbook procedure drift","evidence":"fixture","confidence":"medium"}]}'
    else
      printf '%s\n' '{"findings":[{"check_id":"OC-F","file":"README.md","claim_type":"environment","target_token":"$HOME","claim":"environment variable drift","evidence":"fixture","confidence":"high"}]}'
    fi
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
