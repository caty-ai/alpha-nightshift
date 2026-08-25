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

# Free-form checker text never becomes an unbounded claim_kind component.
# The parsed path is preferred, with a fixed unknown fallback when no path exists.
/usr/bin/env OC_TEST_MUTATE= /usr/bin/python3 - "$OC_CORE" <<'PY'
import importlib.util
import pathlib
import sys
import tempfile

spec = importlib.util.spec_from_file_location("org_consistency_core", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
runner = module.Runner.__new__(module.Runner)
runner.fp_spec_version = "2"
repo = {"id": 77, "full_name": "caty-ai/family-os"}
with_path = runner.finding_from_failure(repo, "unstructured README.md failure detail")
without_path = runner.finding_from_failure(repo, "unstructured failure detail")
assert with_path["claim_kind"].startswith("regcheck:unknown:readme.md:")
assert without_path["claim_kind"].startswith("regcheck:unknown:unknown:")
assert with_path["claim"] == "unstructured README.md failure detail"
assert without_path["claim"] == "unstructured failure detail"
assert runner.parse_checker_failures("FAILED (2):\n  - first\n\nOK\n  - ghost") == ["first"]
with tempfile.TemporaryDirectory() as root:
    root_path = pathlib.Path(root)
    mirror = root_path / "mirror"
    mirror.mkdir()
    inside = mirror / "README.md"
    inside.write_text("inside", encoding="utf-8")
    outside = root_path / "outside.md"
    outside.write_text("outside", encoding="utf-8")
    linked = mirror / "AGENTS.md"
    linked.symlink_to(outside)
    assert runner.safe_mirror_file(mirror, inside)
    assert not runner.safe_mirror_file(mirror, linked)
runner.night_id = "2026-08-01"
empty_metrics = {check: {"scanned": 0, "extracted": 0, "flagged": 0} for check in module.CHECK_IDS}
markdown = runner.report_markdown({
    "targets_label": "TARGETS-FRESH",
    "complete": True,
    "scope": {
        "target_repos": 0, "excluded": [], "renamed": [], "branch_changed": [],
        "left_scope": [], "left_scope_expired": 0, "no_input": 0, "not_run": 1,
        "stale_input": 0, "invalid_output": 0, "deferred": 0,
    },
    "digest_mapping": {"not_run_many": "ABORTED-equivalent", "all_run_zero_findings": "ZERO-equivalent"},
    "effective_settings": {},
    "check_metrics": empty_metrics,
    "cells": [{"check_id": "OC-A", "repo_id": None, "repo": "family-os", "status": "NOT-RUN", "reason": "absent"}],
    "findings": {"new": [], "resolved_candidates": []},
})
assert "| OC-A | - | family-os |" in markdown
PY

oc_case_init core
case_root=$OC_CASE_ROOT
trap 'rm -rf "$TEST_TMP" "$case_root"' EXIT

# Test-only inputs are refused on the production-shaped entry unless the
# fixture harness explicitly opts in.
test_mode_lane="$OC_CASE_ROOT/test-mode-lane"
mkdir -p "$test_mode_lane/tmp" "$test_mode_lane/home"
test_mode_rc=0
/usr/bin/env -i \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin \
  HOME="$test_mode_lane/home" TMPDIR="$test_mode_lane/tmp" LANG=C TERM=dumb \
  NIGHT_ID=2026-08-01 LANE_DIR="$test_mode_lane" OC_STATE_DIR="$OC_STATE" \
  OC_API_FIXTURE="$OC_API" \
  /bin/bash "$OC_RUN_SH" > "$OC_CASE_ROOT/test-mode.out" 2>&1 || test_mode_rc=$?
[ "$test_mode_rc" -ne 0 ] || fail 'test-only environment was accepted without OC_TEST_MODE=1'
assert_contains 'OC_API_FIXTURE requires OC_TEST_MODE=1' "$OC_CASE_ROOT/test-mode.out"

oc_make_remote family-os main fail
oc_make_remote other main none
oc_write_two_api 101 family-os 202 other
issues_fixture="$OC_CASE_ROOT/issues.json"
printf '%s\n' '[]' > "$issues_fixture"

oc_run 2026-08-02 OC_TEST_ISSUES_FIXTURE="$issues_fixture"
report_one="$OC_STATE/report/2026-08-02.json"
plan_one="$OC_STATE/plan-2026-08-02.json"
journal_one="$OC_STATE/journal/2026-08-02.json"
assert_file_exists "$report_one"
assert_file_exists "$OC_STATE/report/2026-08-02.md"
assert_file_exists "$plan_one"
assert_file_exists "$journal_one"
jq -e '.night_id == "2026-08-02" and .issues == []' "$OC_STATE/issues/family-os-open.json" >/dev/null || fail 'issues snapshot did not persist its capture night'
jq -e '.complete == true and .scope.target_repos == 2 and .scope.no_input == 2 and .scope.not_run == 0' "$report_one" >/dev/null || fail 'scope summary did not expose the expanded layer-1 plan'
jq -e '.check_metrics["OC-A"] == {extracted:2,flagged:2,scanned:1}' "$report_one" >/dev/null || fail 'OC-A coverage counters are wrong'
jq -e '[.cells[] | select(.check_id == "OC-A" and .repo_id == 101 and .status == "RUN" and .fresh == true)] | length == 1' "$report_one" >/dev/null || fail 'FAILED claim text containing skipped incorrectly degraded OC-A'
jq -e '
  (.cells | length) == 6 and
  ([.cells[] | select(.check_id == "OC-A" and .repo_id == 101 and .status == "RUN")] | length) == 1 and
  ([.cells[] | select(.check_id == "OC-B" and .repo_id == 202)] | length) == 1 and
  ([.cells[] | select(.check_id == "OC-C")] | length) == 2 and
  ([.cells[] | select(.check_id == "OC-D")] | length) == 2
' "$report_one" >/dev/null || fail 'expanded OC-A/B/C/D target matrix is wrong'
jq -e '(.cells | length) == 6 and all(.cells[]; has("result"))' "$plan_one" >/dev/null || fail 'final plan did not retain every layer-1 result'
[ -d "$OC_STATE/mirrors/202" ] || fail 'S2 did not mirror the non-family-os target'
jq -e '.findings | length == 2 and all(.[]; .baseline == true and .status == "open")' "$OC_STATE/findings.json" >/dev/null || fail 'baseline findings were not added to the open set'
jq -e '(.findings.new | length) == 2 and (.findings.baseline | length) == 2' "$report_one" >/dev/null || fail 'baseline inventory section is incomplete'
jq -e '.effective_settings.OC_API_MODE == "fixture" and .effective_settings.OC_GIT_TRANSPORT == "fixture" and .effective_settings.OC_FP_SPEC_VERSION == "2"' "$report_one" >/dev/null || fail 'effective settings were not echoed'
assert_contains 'OC-A: scanned=1 extracted=2 flagged=2' "$OC_STATE/report/2026-08-02.md"

first_count=$(jq '.findings | length' "$OC_STATE/findings.json")
first_fp=$(jq -r '.findings[0].fingerprint' "$OC_STATE/findings.json")
[ "$first_count" -ge 1 ] || fail 'dedup precondition: first night produced no OC-A finding'
[ "$first_count" -eq 2 ] || fail 'same-check same-file defects collapsed to one fingerprint'
oc_run 2026-08-03
jq -e '.findings.new | length == 0' "$OC_STATE/report/2026-08-03.json" >/dev/null || fail 'second identical night re-added findings'
[ "$(jq '.findings | length' "$OC_STATE/findings.json")" -eq "$first_count" ] || fail 'dedup changed the open-set size'
jq -e --arg fp "$first_fp" '.findings[] | select(.fingerprint == $fp) | .last_seen == "2026-08-03" and .first_seen == "2026-08-02"' "$OC_STATE/findings.json" >/dev/null || fail 'dedup did not advance last_seen only'

# Config example must preserve contiguous registration and the frozen complete example.
assert_contains 'dispatcher stops scanning at the first missing LANE_CMD_n' "$ROOT/config/nightshift.conf.example"
assert_contains '# LANE_CMD_3="OC_STATE_DIR=' "$ROOT/config/nightshift.conf.example"
assert_contains "OC_SEAT_CMD='codex exec --sandbox read-only --ignore-rules --ignore-user-config --ephemeral --disable multi_agent --skip-git-repo-check -'" "$ROOT/config/nightshift.conf.example"
lane_cmd_numbers=$(grep -Eo 'LANE_CMD_[0-9]+' "$ROOT/config/nightshift.conf.example" | sed 's/.*_//' | sort -nu)
lane_cmd_max=$(printf '%s\n' "$lane_cmd_numbers" | tail -n 1)
expected_lane_cmd_numbers=$(seq 1 "$lane_cmd_max")
[ "$lane_cmd_numbers" = "$expected_lane_cmd_numbers" ] || fail 'conf.example LANE_CMD numbers are not the contiguous set 1..N'

printf 'test_lane_org_consistency_core: PASS\n'
