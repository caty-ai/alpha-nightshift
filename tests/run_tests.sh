#!/bin/bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
passed=0
failed=0
executed=0
skipped=0

suite_contracts() {
  case "$1" in
    test_budget_failclosed.sh|test_dispatch_failclosed.sh|test_digest.sh|test_digest_lane_status.sh|test_lock.sh|test_ledger_failclosed.sh|test_run_visibility.sh|test_process_inspection_failclosed.sh)
      printf '%s\n' 'darwin_userland'
      ;;
    test_lane_env_credentials.sh|test_lane_health.sh|test_lane_review_runtime.sh|test_lane_review_selection.sh)
      printf '%s\n' 'darwin_userland'
      ;;
    test_triage_decisions.sh|test_triage_dedup.sh|test_triage_failclosed.sh|test_verdict_sync.sh)
      printf '%s\n' 'darwin_userland'
      ;;
    test_metsuke_readiness.sh)
      printf '%s\n' 'darwin_userland'
      ;;
    test_guard_bypass.sh|test_guard_scan.sh)
      printf '%s\n' 'brew_git pinned_gitleaks system_jq'
      ;;
    test_guard_drift_monitor.sh)
      printf '%s\n' 'darwin_userland system_jq'
      ;;
    test_guard_gateway.sh)
      printf '%s\n' 'system_jq'
      ;;
    test_guard_preflight.sh)
      printf '%s\n' 'darwin_userland pinned_gitleaks system_jq'
      ;;
    test_guard_sandbox.sh)
      printf '%s\n' 'sandbox_exec system_jq'
      ;;
    test_guard_publisher.sh)
      printf '%s\n' 'darwin_userland cellar_git_shim brew_git system_jq'
      ;;
    test_guard_text_policy.sh)
      printf '%s\n' 'brew_git pinned_gitleaks system_jq'
      ;;
    *)
      printf '\n'
      ;;
  esac
}

contract_available() {
  contract_name=$1

  case "$contract_name" in
    darwin_userland) [ "$(uname)" = "Darwin" ] ;;
    cellar_git_shim) [ -x /opt/homebrew/Cellar/git/2.48.1/bin/git ] ;;
    sandbox_exec) command -v sandbox-exec >/dev/null 2>&1 ;;
    pinned_gitleaks) [ -x /opt/homebrew/Cellar/gitleaks/8.30.1/bin/gitleaks ] ;;
    brew_git) [ -x /opt/homebrew/bin/git ] ;;
    system_jq) [ -x /usr/bin/jq ] ;;
    *) return 1 ;;
  esac
}

test_files=("$TEST_DIR"/test_*.sh)
declared=${#test_files[@]}
expected_suite_count_file="$TEST_DIR/expected_suite_count"

if [ ! -r "$expected_suite_count_file" ]; then
  printf 'ERROR: suite census file is missing or unreadable: %s; update this file when adding or removing test_*.sh suites.\n' "$expected_suite_count_file" >&2
  exit 1
fi

if ! expected_suite_count=$(<"$expected_suite_count_file"); then
  printf 'ERROR: suite census file is unreadable: %s; update this file when adding or removing test_*.sh suites.\n' "$expected_suite_count_file" >&2
  exit 1
fi

case "$expected_suite_count" in
  ''|*[!0-9]*)
    printf 'ERROR: suite census file must contain a numeric count: %s; update this file when adding or removing test_*.sh suites.\n' "$expected_suite_count_file" >&2
    exit 1
    ;;
esac

if [ "$declared" -ne "$expected_suite_count" ]; then
  printf 'ERROR: suite census mismatch: declared=%s expected=%s; update %s when adding or removing test_*.sh suites.\n' "$declared" "$expected_suite_count" "$expected_suite_count_file" >&2
  exit 1
fi

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
  # PASS requires exit 0 and either exact '<suite basename without .sh>: PASS'
  # or a line starting with 'PASS ('. Output is captured and replayed after
  # each suite; live streaming is intentionally not provided for portability.
  if suite_out=$(/bin/bash "$test_file" 2>&1); then
    [ -z "$suite_out" ] || printf '%s\n' "$suite_out"
    # Read all output so an early grep match cannot cause SIGPIPE with pipefail.
    if printf '%s\n' "$suite_out" | grep -Fx "${test_name%.sh}: PASS" >/dev/null ||
       printf '%s\n' "$suite_out" | grep -E '^PASS [(]' >/dev/null; then
      printf 'PASS %s\n' "$test_name"
      passed=$((passed + 1))
    else
      printf 'FAIL %s (no verdict line)\n' "$test_name"
      failed=$((failed + 1))
    fi
  else
    [ -z "$suite_out" ] || printf '%s\n' "$suite_out"
    printf 'FAIL %s\n' "$test_name"
    failed=$((failed + 1))
  fi
done

printf '\nTests: %s passed, %s failed\n' "$passed" "$failed"
printf 'suites: declared=%s executed=%s skipped=%s\n' "$declared" "$executed" "$skipped"
[ "$failed" -eq 0 ]
