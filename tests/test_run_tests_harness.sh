#!/bin/bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/helpers.sh
source "$TEST_DIR/helpers.sh"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-run-tests-harness.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/tests"
mkdir "$tmp/suite-tmp"
# Keep the destructive fixture away from the caller's shared temporary files.
export TMPDIR="$tmp/suite-tmp"
cp "$TEST_DIR/run_tests.sh" "$TEST_DIR/helpers.sh" "$tmp/tests/"
printf '6\n' > "$tmp/tests/expected_suite_count"

cat > "$tmp/tests/test_a.sh" <<'EOF'
#!/bin/bash
printf 'stdout remains visible\n'
printf 'stderr remains visible\n' >&2
printf 'test_a: PASS\n'
EOF
cat > "$tmp/tests/test_b.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$tmp/tests/test_c.sh" <<'EOF'
#!/bin/bash
printf 'test_c: PASS\n'
exit 1
EOF
cat > "$tmp/tests/test_d.sh" <<'EOF'
#!/bin/bash
printf 'PASS (paren form)\n'
EOF
cat > "$tmp/tests/test_e.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
rm -rf "${TMPDIR:-/tmp}"/run-tests.*
rm -rf "$TMPDIR"/harness-*
printf 'test_e: PASS\n'
EOF
cat > "$tmp/tests/test_f.sh" <<'EOF'
#!/bin/bash
printf 'PASS test_other.sh\n'
printf 'FAIL: real assertion blew up\n' >&2
exit 0
EOF

status=0
/bin/bash "$tmp/tests/run_tests.sh" > "$tmp/output" 2> "$tmp/error" || status=$?
[ "$status" -eq 1 ] || fail "mixed run exited $status instead of 1"
assert_contains 'PASS test_a.sh' "$tmp/output"
assert_contains 'FAIL test_b.sh (no verdict line)' "$tmp/output"
grep -Fxq 'FAIL test_c.sh' "$tmp/output" || fail 'nonzero suite must fail'
assert_contains 'PASS test_d.sh' "$tmp/output"
assert_contains 'PASS test_e.sh' "$tmp/output"
assert_contains 'FAIL test_f.sh (no verdict line)' "$tmp/output"
assert_contains 'Tests: 3 passed, 3 failed' "$tmp/output"
assert_contains 'suites: declared=6 executed=6 skipped=0' "$tmp/output"
assert_contains 'stdout remains visible' "$tmp/output"
assert_contains 'stderr remains visible' "$tmp/output"
assert_contains 'test_a: PASS' "$tmp/output"
assert_contains 'test_c: PASS' "$tmp/output"
assert_contains 'PASS (paren form)' "$tmp/output"
assert_contains 'test_e: PASS' "$tmp/output"
assert_contains 'PASS test_other.sh' "$tmp/output"
assert_contains 'FAIL: real assertion blew up' "$tmp/output"
[ ! -s "$tmp/error" ] || fail 'suite output must stay on harness stdout'
awk '
  $0 == "stdout remains visible" { stdout_line = NR }
  $0 == "stderr remains visible" { stderr_line = NR }
  $0 == "test_a: PASS" { suite_line = NR }
  $0 == "PASS test_a.sh" { verdict_line = NR }
  END {
    exit !(stdout_line > 0 && stdout_line < stderr_line &&
           stderr_line < suite_line && suite_line < verdict_line)
  }
' "$tmp/output" || fail 'suite output must precede its harness verdict in order'

rm "$tmp/tests/test_b.sh" "$tmp/tests/test_c.sh" "$tmp/tests/test_e.sh" "$tmp/tests/test_f.sh"
printf '2\n' > "$tmp/tests/expected_suite_count"
status=0
/bin/bash "$tmp/tests/run_tests.sh" > "$tmp/output" 2>&1 || status=$?
[ "$status" -eq 0 ] || fail "passing run exited $status instead of 0"
assert_contains 'Tests: 2 passed, 0 failed' "$tmp/output"
assert_contains 'suites: declared=2 executed=2 skipped=0' "$tmp/output"

# Similar-looking text is not a verdict, nor is another suite's verdict.
cat > "$tmp/tests/test_b.sh" <<'EOF'
#!/bin/bash
printf '%s\n' 'PASSWORD' 'a sentence with PASS' 'FAIL' 'test_a: PASS' 'test_b: PASS extra'
EOF
printf '3\n' > "$tmp/tests/expected_suite_count"
status=0
/bin/bash "$tmp/tests/run_tests.sh" > "$tmp/output" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "invalid verdict run exited $status instead of 1"
assert_contains 'FAIL test_b.sh (no verdict line)' "$tmp/output"
assert_contains 'Tests: 2 passed, 1 failed' "$tmp/output"

# Suites must not inherit a descriptor opened by the harness for output routing.
rm "$tmp/tests/test_b.sh"
cat > "$tmp/tests/test_f.sh" <<'EOF'
#!/bin/bash
if { true >&3; } 2>/dev/null; then echo 'fd3 leaked'; fi
printf 'test_f: PASS\n'
EOF
status=0
# Close the caller's fd 3 so only descriptors opened by the harness are tested.
/bin/bash "$tmp/tests/run_tests.sh" 3>&- > "$tmp/output" 2> "$tmp/error" || status=$?
[ "$status" -eq 0 ] || fail "fd isolation run exited $status instead of 0"
assert_not_contains 'fd3 leaked' "$tmp/output" "$tmp/error"
assert_contains 'test_f: PASS' "$tmp/output"
assert_contains 'PASS test_f.sh' "$tmp/output"
assert_contains 'Tests: 3 passed, 0 failed' "$tmp/output"
[ ! -s "$tmp/error" ] || fail 'fd isolation run must keep harness stderr empty'

# Negative control: the fixture must detect an fd 3 opened by the harness itself.
awk 'NR == 2 { print "exec 3>&1" } { print }' "$tmp/tests/run_tests.sh" > "$tmp/tests/run_tests-leaky.sh"
status=0
/bin/bash "$tmp/tests/run_tests-leaky.sh" 3>&- > "$tmp/output" 2>&1 || status=$?
[ "$status" -eq 0 ] || fail "fd leak control exited $status instead of 0"
assert_contains 'fd3 leaked' "$tmp/output"

printf 'test_run_tests_harness: PASS\n'
