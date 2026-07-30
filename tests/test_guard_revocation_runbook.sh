#!/bin/bash
# shellcheck disable=SC1090,SC1091,SC2034
set -euo pipefail

TEST_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)
ROOT=$(CDPATH='' cd -- "$TEST_DIR/.." && pwd -P)
. "$TEST_DIR/helpers.sh"

RUNBOOK=$ROOT/docs/night-bot-revocation.md
SNIPPET=$(
  /usr/bin/awk '
    /^```sh$/ { capture=1; next }
    capture && /^```$/ { exit }
    capture { print }
  ' "$RUNBOOK"
)
[ -n "$SNIPPET" ] || fail "runbook did not contain a dry-run shell snippet"

DRY_RUN_LIB=$(
  mktemp "${TMPDIR:-/tmp}/nightshift-runbook-dryrun.XXXXXX"
)
/usr/bin/printf '%s\n' "$SNIPPET" > "$DRY_RUN_LIB"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-runbook-test.XXXXXX")
cleanup() {
  rm -rf "$TEST_TMP" "$DRY_RUN_LIB"
}
trap cleanup EXIT

RUNBOOK_OUT=$TEST_TMP/runbook.out
RUNBOOK_ERR=$TEST_TMP/runbook.err
(
  . "$DRY_RUN_LIB"
  REVOCATION_CASE_ID=CASE-20260730-0001
  NIGHTSHIFT_ROOT=/tmp/nightshift-root
  AUDIT_JSONL=/tmp/nightshift-root/state/audit/MON-20260730T000000Z-1.jsonl
  PUBLISH_POLICY_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  REPRESENTATIVE_REF=refs/heads/night-bot/run-20260730-0099-deadbeef
  export LIVE_INSTALLATION_IAT=SHOULD_NOT_APPEAR_CANARY
  night_bot_revocation_dry_run
) > "$RUNBOOK_OUT" 2> "$RUNBOOK_ERR"

[ "$(/usr/bin/wc -l < "$RUNBOOK_OUT" | /usr/bin/tr -d ' ')" = 9 ] ||
  fail "dry-run output did not contain exactly nine ordered actions"
assert_contains '1. stop/disable local publisher and drift-monitor services' "$RUNBOOK_OUT"
assert_contains '2. quarantine the request spool and preserve redacted evidence' "$RUNBOOK_OUT"
assert_contains '3. revoke the in-flight read IAT if one exists' "$RUNBOOK_OUT"
assert_contains '4. suspend or uninstall the GitHub App installation' "$RUNBOOK_OUT"
assert_contains '5. revoke the compromised App private key in GitHub' "$RUNBOOK_OUT"
assert_contains '6. read back that installation token mint/use is blocked' "$RUNBOOK_OUT"
assert_contains '7. retain the active deny rulesets' "$RUNBOOK_OUT"
assert_contains '8. treat any successful main/tag/delete/force/merge/release mutation as an incident' "$RUNBOOK_OUT"
assert_contains '9. re-enable only after a fresh owner-sealed policy digest' "$RUNBOOK_OUT"
assert_contains 'REDACTED_INSTALLATION_IAT_IF_PRESENT' "$RUNBOOK_OUT"
assert_not_contains 'SHOULD_NOT_APPEAR_CANARY' "$RUNBOOK_OUT"
assert_not_contains 'SHOULD_NOT_APPEAR_CANARY' "$RUNBOOK_ERR"

if (
  . "$DRY_RUN_LIB"
  NIGHTSHIFT_ROOT=/tmp/nightshift-root
  AUDIT_JSONL=/tmp/nightshift-root/state/audit/MON-20260730T000000Z-1.jsonl
  PUBLISH_POLICY_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  REPRESENTATIVE_REF=refs/heads/night-bot/run-20260730-0099-deadbeef
  night_bot_revocation_dry_run
) > "$TEST_TMP/missing.out" 2> "$TEST_TMP/missing.err"; then
  fail "dry-run renderer ignored a missing prerequisite"
fi
[ ! -s "$TEST_TMP/missing.out" ] || fail "missing prerequisite still produced dry-run output"
assert_contains 'REVOCATION_CASE_ID' "$TEST_TMP/missing.err"

printf 'test_guard_revocation_runbook: PASS\n'
