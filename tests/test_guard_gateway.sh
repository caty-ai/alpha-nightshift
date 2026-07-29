#!/bin/bash
set -euo pipefail

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
ROOT=$(CDPATH= cd -- "$TEST_DIR/.." && pwd -P)
. "$TEST_DIR/helpers.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-gateway.XXXXXX")
cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT
TEST_TMP=$(CDPATH= cd -- "$TEST_TMP" && pwd -P)

"$ROOT/guard/gateway.sh" status > "$TEST_TMP/status.json"
/usr/bin/jq -e '
  .mode == "LOCAL_ONLY_REMOTE_UNPROVEN" and .write_mode == false
' "$TEST_TMP/status.json" >/dev/null || fail "status did not remain inert"

for operation in push publish publish_branch create_draft_pr create_issue merge comment label api graphql; do
  if "$ROOT/guard/gateway.sh" "$operation" > "$TEST_TMP/$operation.out" 2>&1; then
    fail "gateway accepted publication-like operation: $operation"
  fi
  assert_contains 'LOCAL_ONLY_REMOTE_UNPROVEN' "$TEST_TMP/$operation.out"
done

for argv in \
  'scan git push --no-verify' \
  'scan HEAD:main' \
  'scan refs/heads/night/20260730-0001' \
  'scan --push-option=x' \
  'inspect --config=core.hooksPath=/tmp/x'; do
  if "$ROOT/guard/gateway.sh" $argv > "$TEST_TMP/arbitrary.out" 2>&1; then
    fail "gateway accepted free-form argv: $argv"
  fi
  assert_contains 'LOCAL_ONLY_REMOTE_UNPROVEN' "$TEST_TMP/arbitrary.out"
done

proposal=$TEST_TMP/proposal.json
/usr/bin/printf '%s\n' \
  '{"schema":"alpha-nightshift/local-proposal/v1","operation":"validate","request_id":"REQ-20260730-0001-0123456789abcdef","repo_id":"sample/repo","candidate_sha":"0123456789abcdef0123456789abcdef01234567"}' \
  > "$proposal"
"$ROOT/guard/gateway.sh" proposal --json "$proposal" > "$TEST_TMP/verdict.json"
/usr/bin/jq -e '.valid == true and .write_mode == false' "$TEST_TMP/verdict.json" >/dev/null ||
  fail "strict proposal was not validated locally"

/usr/bin/printf '%s\n' \
  '{"schema":"alpha-nightshift/local-proposal/v1","operation":"validate","request_id":"REQ-20260730-0001-0123456789abcdef","repo_id":"sample/repo","candidate_sha":"0123456789abcdef0123456789abcdef01234567","destination_ref":"refs/heads/night/20260730-0001"}' \
  > "$TEST_TMP/ref.json"
if "$ROOT/guard/gateway.sh" proposal --json "$TEST_TMP/ref.json" >/dev/null 2>&1; then
  fail "lane-controlled destination ref was accepted"
fi

/usr/bin/printf '%s\n' \
  '{"schema":"alpha-nightshift/local-proposal/v1","operation":"validate","request_id":"REQ-20260730-0001-0123456789abcdef","repo_id":"sample/repo","repo_id":"other/repo","candidate_sha":"0123456789abcdef0123456789abcdef01234567"}' \
  > "$TEST_TMP/duplicate.json"
if "$ROOT/guard/gateway.sh" proposal --json "$TEST_TMP/duplicate.json" >/dev/null 2>&1; then
  fail "duplicate JSON field was accepted"
fi

for bad_repo in 'Sample/repo' 'sample/../repo' 'sample/repo.git/extra' 'sample/répô'; do
  /usr/bin/jq --arg repo "$bad_repo" '.repo_id=$repo' "$proposal" > "$TEST_TMP/bad.json"
  if "$ROOT/guard/gateway.sh" proposal --json "$TEST_TMP/bad.json" >/dev/null 2>&1; then
    fail "ambiguous repository identifier was accepted: $bad_repo"
  fi
done

printf 'test_guard_gateway: PASS\n'
