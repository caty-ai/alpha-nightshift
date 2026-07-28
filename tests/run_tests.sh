#!/bin/bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
passed=0
failed=0

for test_file in "$TEST_DIR"/test_*.sh; do
  test_name=$(basename "$test_file")
  if /bin/bash "$test_file"; then
    printf 'PASS %s\n' "$test_name"
    passed=$((passed + 1))
  else
    printf 'FAIL %s\n' "$test_name"
    failed=$((failed + 1))
  fi
done

printf '\nTests: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
