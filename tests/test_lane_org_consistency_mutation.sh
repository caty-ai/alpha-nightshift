#!/bin/bash
# shellcheck disable=SC1091
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
. "$TEST_DIR/helpers.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-org-mutation.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

assert_mutation_red() {
  mutation=$1
  suite=$2
  output="$TEST_TMP/$mutation.out"
  mutation_rc=0
  OC_TEST_MODE=1 OC_TEST_MUTATE="$mutation" /bin/bash "$TEST_DIR/$suite" > "$output" 2>&1 || mutation_rc=$?
  [ "$mutation_rc" -ne 0 ] || fail "$mutation mutation did not turn $suite red"
  assert_contains 'FAIL:' "$output"
}

assert_mutation_red fp-normalize test_lane_org_consistency_core.sh
assert_mutation_red target-selection test_lane_org_consistency_targets_mirrors.sh
assert_mutation_red exclude test_lane_org_consistency_targets_mirrors.sh
assert_mutation_red rename test_lane_org_consistency_targets_mirrors.sh
assert_mutation_red notrun test_lane_org_consistency_timebox.sh
assert_mutation_red failure-identity test_lane_org_consistency_core.sh
assert_mutation_red degraded-whole-stdout test_lane_org_consistency_core.sh
assert_mutation_red rc0-contract test_lane_org_consistency_lifecycle.sh
assert_mutation_red sanitize test_lane_org_consistency_oc_bcd.sh
assert_mutation_red freshness-threshold test_digest.sh

printf 'test_lane_org_consistency_mutation: PASS\n'
