#!/bin/bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
passed=0
failed=0
executed=0
skipped=0

suite_contracts() {
  case "$1" in
    test_guard_bypass.sh)
      printf '%s\n' 'brew_git pinned_gitleaks system_jq'
      ;;
    test_guard_drift_monitor.sh|test_guard_gateway.sh|test_metsuke_readiness.sh)
      printf '%s\n' 'system_jq'
      ;;
    test_guard_preflight.sh)
      printf '%s\n' 'pinned_gitleaks system_jq'
      ;;
    test_guard_sandbox.sh)
      printf '%s\n' 'sandbox_exec system_jq'
      ;;
    test_guard_publisher.sh)
      printf '%s\n' 'brew_git system_jq'
      ;;
    test_guard_scan.sh|test_guard_text_policy.sh)
      printf '%s\n' 'brew_git pinned_gitleaks system_jq'
      ;;
    *)
      printf '\n'
      ;;
  esac
}

contract_available() {
  contract_name=$1

  # Test-only override for exercising skip accounting; unset in normal runs.
  if [ "${RUN_TESTS_FORCE_MISSING:-}" = "$contract_name" ]; then
    return 1
  fi

  case "$contract_name" in
    sandbox_exec) command -v sandbox-exec >/dev/null 2>&1 ;;
    pinned_gitleaks) [ -x /opt/homebrew/Cellar/gitleaks/8.30.1/bin/gitleaks ] ;;
    brew_git) [ -x /opt/homebrew/bin/git ] ;;
    system_jq) [ -x /usr/bin/jq ] ;;
    launchd) command -v launchctl >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

test_files=("$TEST_DIR"/test_*.sh)
declared=${#test_files[@]}

for test_file in "${test_files[@]}"; do
  test_name=$(basename "$test_file")
  required_contracts=$(suite_contracts "$test_name")
  missing_contract=
  for required_contract in $required_contracts; do
    if ! contract_available "$required_contract"; then
      missing_contract=$required_contract
      break
    fi
  done

  if [ -n "$missing_contract" ]; then
    printf 'SKIP %s: missing contract %s\n' "$test_name" "$missing_contract"
    skipped=$((skipped + 1))
    continue
  fi

  executed=$((executed + 1))
  if /bin/bash "$test_file"; then
    printf 'PASS %s\n' "$test_name"
    passed=$((passed + 1))
  else
    printf 'FAIL %s\n' "$test_name"
    failed=$((failed + 1))
  fi
done

printf '\nTests: %s passed, %s failed\n' "$passed" "$failed"
printf 'suites: declared=%s executed=%s skipped=%s\n' "$declared" "$executed" "$skipped"
[ "$failed" -eq 0 ]
