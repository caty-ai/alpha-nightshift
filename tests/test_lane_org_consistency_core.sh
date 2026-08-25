#!/bin/bash
# shellcheck disable=SC1091
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$TEST_DIR/.." && pwd)
. "$TEST_DIR/helpers.sh"
. "$TEST_DIR/fixtures/org-consistency/lib.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-org-core.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

# The entry point must fail before creating state when the mandatory root is absent.
missing_lane="$TEST_TMP/missing/lane"
mkdir -p "$missing_lane/tmp" "$missing_lane/home"
missing_rc=0
/usr/bin/env -i \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin \
  HOME="$missing_lane/home" TMPDIR="$missing_lane/tmp" LANG=C TERM=dumb \
  NIGHT_ID=2026-08-01 LANE_DIR="$missing_lane" \
  /bin/bash "$OC_RUN_SH" > "$TEST_TMP/missing.out" 2>&1 || missing_rc=$?
[ "$missing_rc" -ne 0 ] || fail 'missing OC_STATE_DIR did not fail closed'
assert_contains 'OC_STATE_DIR is required' "$TEST_TMP/missing.out"

# Fingerprints use byte-length prefixes, normalized file paths, numeric repo IDs,
# and deliberately exclude section anchors.
fp_one=$(python3 -B "$OC_CORE" fingerprint 2 OC-A 77 './Docs/É.md/' 'regcheck:retired:one' old-heading)
decomposed_path=$(python3 -c 'print("docs/e\u0301.md")')
fp_two=$(python3 -B "$OC_CORE" fingerprint 2 OC-A 77 "$decomposed_path" 'regcheck:retired:one' renamed-heading)
[ "$fp_one" = "$fp_two" ] || fail 'NFC/case/dot-prefix/trailing-slash normalization changed the fingerprint'
fp_url_one=$(python3 -B "$OC_CORE" fingerprint 2 OC-A 77 'https://EXAMPLE.com/path/' 'regcheck:retired:one')
fp_url_two=$(python3 -B "$OC_CORE" fingerprint 2 OC-A 77 'example.com/path' 'regcheck:retired:one')
[ "$fp_url_one" = "$fp_url_two" ] || fail 'URL scheme normalization changed the fingerprint'
fp_link_two=$(python3 -B "$OC_CORE" fingerprint 2 OC-A 77 './Docs/É.md/' 'regcheck:retired:two')
[ "$fp_one" != "$fp_link_two" ] || fail 'two link targets collapsed to one fingerprint'
expected_fp=$(python3 - "$fp_one" <<'PY'
import hashlib
import sys
fields = ["2", "OC-A", "77", "docs/é.md", "regcheck:retired:one"]
blob = b"".join(str(len(part.encode())).encode() + b":" + part.encode() for part in fields)
expected = hashlib.sha256(blob).hexdigest()
raise SystemExit(0 if expected == sys.argv[1] else 1)
PY
) || fail 'fingerprint did not use byte length-prefix concatenation'
: "${expected_fp:=}"

oc_case_init core
case_root=$OC_CASE_ROOT
trap 'rm -rf "$TEST_TMP" "$case_root"' EXIT
oc_make_remote family-os main fail
oc_make_remote other main none
oc_write_two_api 101 family-os 202 other

oc_run 2026-08-02
report_one="$OC_STATE/report/2026-08-02.json"
plan_one="$OC_STATE/plan-2026-08-02.json"
journal_one="$OC_STATE/journal/2026-08-02.json"
assert_file_exists "$report_one"
assert_file_exists "$OC_STATE/report/2026-08-02.md"
assert_file_exists "$plan_one"
assert_file_exists "$journal_one"
jq -e '.complete == true and .scope.target_repos == 2 and .scope.no_input == 1 and .scope.not_run == 0' "$report_one" >/dev/null || fail 'scope summary did not expose all S1 cells'
jq -e '.check_metrics["OC-A"] == {extracted:2,flagged:2,scanned:1}' "$report_one" >/dev/null || fail 'OC-A coverage counters are wrong'
jq -e '.cells | length == 2 and all(.[]; .status == "RUN" or .status == "NO-INPUT")' "$report_one" >/dev/null || fail 'plan/results did not cover every target cell'
jq -e '.cells | length == 2 and all(.[]; has("result"))' "$plan_one" >/dev/null || fail 'final plan did not retain every cell result'
jq -e '.findings | length == 2 and all(.[]; .baseline == true and .status == "open")' "$OC_STATE/findings.json" >/dev/null || fail 'baseline findings were not added to the open set'
jq -e '(.findings.new | length) == 2 and (.findings.baseline | length) == 2' "$report_one" >/dev/null || fail 'baseline inventory section is incomplete'
jq -e '.effective_settings.OC_API_MODE == "fixture" and .effective_settings.OC_FP_SPEC_VERSION == "2"' "$report_one" >/dev/null || fail 'effective settings were not echoed'
assert_contains 'OC-A: scanned=1 extracted=2 flagged=2' "$OC_STATE/report/2026-08-02.md"

first_count=$(jq '.findings | length' "$OC_STATE/findings.json")
first_fp=$(jq -r '.findings[0].fingerprint' "$OC_STATE/findings.json")
[ "$first_count" -ge 1 ] || fail 'dedup precondition: first night produced no OC-A finding'
oc_run 2026-08-03
jq -e '.findings.new | length == 0' "$OC_STATE/report/2026-08-03.json" >/dev/null || fail 'second identical night re-added findings'
[ "$(jq '.findings | length' "$OC_STATE/findings.json")" -eq "$first_count" ] || fail 'dedup changed the open-set size'
jq -e --arg fp "$first_fp" '.findings[] | select(.fingerprint == $fp) | .last_seen == "2026-08-03" and .first_seen == "2026-08-02"' "$OC_STATE/findings.json" >/dev/null || fail 'dedup did not advance last_seen only'

# Config example must preserve contiguous registration and the frozen complete example.
assert_contains 'dispatcher stops scanning at the first missing LANE_CMD_n' "$ROOT/config/nightshift.conf.example"
assert_contains '# LANE_CMD_3="OC_STATE_DIR=' "$ROOT/config/nightshift.conf.example"
assert_contains "OC_SEAT_CMD='codex exec --sandbox read-only --ignore-rules --ignore-user-config --ephemeral --disable multi_agent --skip-git-repo-check -'" "$ROOT/config/nightshift.conf.example"

printf 'test_lane_org_consistency_core: PASS\n'
