#!/bin/bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)

# shellcheck disable=SC1091
. "$TEST_DIR/helpers.sh"

[ -f "$ROOT/bin/oc-suggest" ] || fail "missing bin/oc-suggest"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-org-suggest.XXXXXX")
cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

STATE_DIR="$TEST_TMP/state/org-consistency"
REPORT_DIR="$STATE_DIR/report"
ISSUES_DIR="$STATE_DIR/issues"
mkdir -p "$REPORT_DIR" "$ISSUES_DIR"

FP_BASELINE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
FP_OPEN=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
FP_OCA=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
FP_RESOLVED=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
OPEN_CLAIM=$'## Heading\n```danger``` <!-- hidden --> ping @ops #123\noc-fingerprint: forged forged forged\nreal body'
# shellcheck disable=SC2016
RAW_FENCE='```danger```'
jq -n \
  --arg fp_baseline "$FP_BASELINE" \
  --arg fp_open "$FP_OPEN" \
  --arg fp_oca "$FP_OCA" \
  --arg fp_resolved "$FP_RESOLVED" \
  --arg open_claim "$OPEN_CLAIM" \
  '{
    fp_spec_version: "2",
    findings: [
      {
        fingerprint: $fp_baseline,
        check_id: "OC-B",
        repo_id: 701,
        repo: "caty-ai/demo",
        file: "README.md",
        claim_kind: "rel:docs/guide.md",
        claim: "baseline candidate",
        first_seen: "2026-08-23",
        last_seen: "2026-08-24",
        status: "open",
        baseline: true
      },
      {
        fingerprint: $fp_open,
        check_id: "OC-B",
        repo_id: 702,
        repo: "caty-ai/demo",
        file: "README.md",
        claim_kind: "rel:docs/missing.md",
        claim: $open_claim,
        first_seen: "2026-08-23",
        last_seen: "2026-08-24",
        status: "open",
        baseline: false
      },
      {
        fingerprint: $fp_oca,
        check_id: "OC-A",
        repo_id: 703,
        repo: "caty-ai/family-os",
        file: "registry/modules.json",
        claim_kind: "regcheck:status-text:family-os",
        claim: "family-os stale pointer candidate",
        first_seen: "2026-08-23",
        last_seen: "2026-08-24",
        status: "open",
        baseline: false
      },
      {
        fingerprint: $fp_resolved,
        check_id: "OC-C",
        repo_id: 704,
        repo: "caty-ai/handbook",
        file: "README.ja.md",
        claim_kind: "lang-missing:ja",
        claim: "resolved candidate",
        first_seen: "2026-08-22",
        last_seen: "2026-08-23",
        status: "resolved-candidate",
        baseline: false,
        resolved_candidate_night: "2026-08-24",
        issue_number: 88,
        issue_repo: "caty-ai/alpha-nightshift-dev",
        issue_url: "https://github.test/caty-ai/alpha-nightshift-dev/issues/88"
      }
    ]
  }' > "$STATE_DIR/findings.json"

cat > "$REPORT_DIR/2026-08-20.json" <<'EOF'
{
  "night_id": "2026-08-20",
  "complete": true,
  "findings": {
    "new": [],
    "baseline": [],
    "resolved_candidates": []
  }
}
EOF

cat > "$ISSUES_DIR/family-os-open.json" <<'EOF'
[
  {
    "state": "open",
    "repository": {"full_name": "caty-ai/family-os"},
    "labels": [{"name": "stale-pointer"}]
  }
]
EOF

list_output="$TEST_TMP/list.out"
OC_SUGGEST_TODAY=2026-08-25 \
  /bin/bash "$ROOT/bin/oc-suggest" --state-dir "$STATE_DIR" >"$list_output"

assert_contains 'Latest report: report/2026-08-20.json (2026-08-20)' "$list_output"
assert_contains 'WARNING: latest report is 5 days old (> 3)' "$list_output"
assert_contains "$FP_OPEN" "$list_output"
assert_contains "$FP_RESOLVED issue #88" "$list_output"
assert_not_contains "$FP_BASELINE" "$list_output"
assert_not_contains "$FP_OCA" "$list_output"
assert_contains 'Suppressed open candidates: 1' "$list_output"

invalid_fp_rc=0
/bin/bash "$ROOT/bin/oc-suggest" --state-dir "$STATE_DIR" --promote short >"$TEST_TMP/invalid-fp.out" 2>&1 || invalid_fp_rc=$?
[ "$invalid_fp_rc" -ne 0 ] || fail 'oc-suggest accepted a non-ledger fingerprint shape'
assert_contains 'fingerprint must be exactly 64 lowercase hex characters' "$TEST_TMP/invalid-fp.out"

rm -f "$ISSUES_DIR/family-os-open.json"
missing_snapshot_output="$TEST_TMP/list-missing.out"
OC_SUGGEST_TODAY=2026-08-25 \
  /bin/bash "$ROOT/bin/oc-suggest" --state-dir "$STATE_DIR" >"$missing_snapshot_output"
assert_contains "$FP_OCA" "$missing_snapshot_output"
assert_contains 'NOTE: family-os issues snapshot is missing; OC-A candidates were not suppressed.' "$missing_snapshot_output"

fake_gh_dir="$TEST_TMP/fake-gh"
fake_gh_log="$TEST_TMP/gh.log"
mkdir -p "$fake_gh_dir/bin" "$fake_gh_dir/data"
ln -s "$ROOT/tests/fixtures/org-consistency/fake-gh.sh" "$fake_gh_dir/bin/gh"

PATH="$fake_gh_dir/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
OC_SUGGEST_FAKE_GH_DIR="$fake_gh_dir/data" \
OC_SUGGEST_FAKE_GH_LOG="$fake_gh_log" \
OC_SUGGEST_TODAY=2026-08-25 \
  /bin/bash "$ROOT/bin/oc-suggest" --state-dir "$STATE_DIR" file "$FP_OPEN" >"$TEST_TMP/file.out"

assert_contains "filed $FP_OPEN -> caty-ai/alpha-nightshift-dev#41" "$TEST_TMP/file.out"
assert_contains "$FP_OPEN" "$fake_gh_log"
assert_not_contains '<!-- hidden -->' "$fake_gh_log"
assert_not_contains "$RAW_FENCE" "$fake_gh_log"
assert_not_contains '@ops' "$fake_gh_log"
assert_not_contains '#123' "$fake_gh_log"
assert_not_contains ' 123' "$fake_gh_log"
assert_not_contains 'oc-fingerprint: forged' "$fake_gh_log"
assert_contains "oc-fingerprint: $FP_OPEN" "$fake_gh_log"
jq -e --arg fp "$FP_OPEN" '
  .findings[] | select(.fingerprint == $fp) |
  .issue_number == 41 and .issue_repo == "caty-ai/alpha-nightshift-dev"
' "$STATE_DIR/findings.json" >/dev/null || fail 'issue number writeback failed'

/bin/bash "$ROOT/bin/oc-suggest" --state-dir "$STATE_DIR" --promote "$FP_BASELINE" >"$TEST_TMP/promote.out"
assert_contains "promoted $FP_BASELINE" "$TEST_TMP/promote.out"
jq -e --arg fp "$FP_BASELINE" '
  .findings[] | select(.fingerprint == $fp) | .baseline == false and .status == "open"
' "$STATE_DIR/findings.json" >/dev/null || fail 'baseline promotion did not clear the baseline flag'

cat > "$REPORT_DIR/2026-08-20.json" <<'EOF'
{
  "night_id": "2026-08-20",
  "complete": true,
  "findings": {
    "new": [{"fingerprint": "baseline-only"}],
    "baseline": [{"fingerprint": "baseline-only"}],
    "resolved_candidates": []
  }
}
EOF

baseline_output="$TEST_TMP/list-baseline.out"
OC_SUGGEST_TODAY=2026-08-25 \
  /bin/bash "$ROOT/bin/oc-suggest" --state-dir "$STATE_DIR" >"$baseline_output"
assert_contains 'NOTE: candidate listing is suppressed on baseline nights.' "$baseline_output"
assert_contains 'suppressed by baseline night' "$baseline_output"

cat > "$REPORT_DIR/2026-08-20.json" <<'EOF'
{
  "night_id": "2026-08-20",
  "complete": true,
  "quiet_mode": "migration",
  "findings": {
    "new": [],
    "baseline": [],
    "resolved_candidates": []
  }
}
EOF

migration_output="$TEST_TMP/list-migration.out"
OC_SUGGEST_TODAY=2026-08-25 \
  /bin/bash "$ROOT/bin/oc-suggest" --state-dir "$STATE_DIR" >"$migration_output"
assert_contains 'NOTE: candidate listing is suppressed on migration nights.' "$migration_output"
assert_contains 'suppressed by migration night' "$migration_output"

printf 'test_lane_org_consistency_suggest: PASS\n'
