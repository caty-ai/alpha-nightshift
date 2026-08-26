#!/bin/bash
# shellcheck disable=SC1091
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
. "$TEST_DIR/helpers.sh"
. "$TEST_DIR/fixtures/org-consistency/lib.sh"

CORPUS="$TEST_DIR/fixtures/corpus/family-os/17ab103"
EXPECTED_SHA=17ab1034a964256aac07a0690a880a6592cc2440
[ "$(<"$CORPUS/UPSTREAM_SHA")" = "$EXPECTED_SHA" ] || fail 'real corpus SHA pin changed'
printf '%s  %s\n' \
  a8c63a6dde1769b0f3782aa8346bbb3ca35b7b34b7ae3fe15518f81097a8ebaa "$CORPUS/tools/check_registry.py" \
  8de35f78951cab0a2ff7f3e48d0df13ebae77eaf143137ccc4f63ef711d9859d "$CORPUS/tools/family_common.py" \
  2e9269cecd21d670ffdee4a241cfea7004a857211d8031d2e1d8009c75074b28 "$CORPUS/registry/modules.json" \
  | shasum -a 256 -c >/dev/null || fail 'vendored real corpus drifted from its pinned byte hashes'
jq -e '.retired_repos == [] and .version == 1 and (.modules | length) > 0' "$CORPUS/registry/modules.json" >/dev/null || fail 'minimized registry corpus lost its upstream schema payload'

case_roots=
trap 'rm -rf $case_roots' EXIT

# Run the actual pinned checker, not a test double. The intentionally minimal
# subset must produce at least one parsed OC-A finding under --offline.
oc_case_init real-corpus
case_roots="$case_roots $OC_CASE_ROOT"
mkdir -p "$OC_WORK/family-os"
cp -R "$CORPUS/tools" "$CORPUS/registry" "$CORPUS/CORPUS.md" "$CORPUS/UPSTREAM_SHA" "$OC_WORK/family-os/"
git -C "$OC_WORK/family-os" init -q
git -C "$OC_WORK/family-os" config user.name 'Org Consistency Fixture'
git -C "$OC_WORK/family-os" config user.email 'fixture@example.invalid'
git -C "$OC_WORK/family-os" config core.hooksPath /dev/null
git -C "$OC_WORK/family-os" checkout -qb main
oc_commit "$OC_WORK/family-os" pinned-real-corpus
git clone -q --bare "$OC_WORK/family-os" "$OC_REMOTES/family-os.git"
oc_write_single_api 701 family-os main
oc_run 2026-08-01
real_report="$OC_STATE/report/2026-08-01.json"
[ "$(oc_status 2026-08-01 701)" = RUN ] || fail 'expected offline summary lines incorrectly degraded the real OC-A cell'
jq -e '.cells[0].checker_exit != 0 and .check_metrics["OC-A"].scanned > 1 and .check_metrics["OC-A"].flagged > 0 and (.findings.new | length) > 0 and .effective_settings.OC_GIT_TRANSPORT == "fixture"' "$real_report" >/dev/null || fail 'pinned real corpus did not prove a non-zero OC-A inventory'

# The checker path is trusted only when the configured mirror remote is the
# first-party github.com/caty-ai/family-os URL.
oc_case_init untrusted
case_roots="$case_roots $OC_CASE_ROOT"
oc_make_remote family-os main fail
jq -n --arg remote "file://$OC_REMOTES/family-os.git" '[{id:702,name:"family-os",full_name:"caty-ai/family-os",default_branch:"main",clone_url:$remote,archived:false,private:false}]' > "$OC_API"
oc_run 2026-08-01 OC_TEST_FIXTURE_GIT_ROOT=
[ "$(oc_status 2026-08-01 702)" = NOT-RUN ] || fail 'untrusted family-os remote executed public HEAD code'
jq -e '.cells[0].reason == "family-os-remote-untrusted" and .check_metrics["OC-A"].scanned == 0 and .effective_settings.OC_GIT_TRANSPORT == "origin"' "$OC_STATE/report/2026-08-01.json" >/dev/null || fail 'untrusted remote failure was not visible'

# The old test cleared OC_TEST_FIXTURE_GIT_ROOT and depended on real github.com reachability.
# Ambient Git configuration must not rewrite the hermetic fixture transport.
oc_case_init rewritten-remote
case_roots="$case_roots $OC_CASE_ROOT"
oc_make_remote family-os main fail
oc_write_single_api 705 family-os main
rewrite_root=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve().as_uri().rstrip("/") + "/")' "$OC_REMOTES")
printf '%s\n' \
  '[url "file:///oc-nonexistent-attacker/"]' \
  "  insteadOf = $rewrite_root" \
  > "$OC_CASE_ROOT/malicious.gitconfig"
# Also expose it through HOME so the explicit /dev/null hardening remains
# mutation-observable after Git environment allowlisting.
mkdir -p "$OC_CASE_ROOT/ambient-home"
ln -s "$OC_CASE_ROOT/malicious.gitconfig" "$OC_CASE_ROOT/ambient-home/.gitconfig"
if GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$OC_CASE_ROOT/malicious.gitconfig" \
  git ls-remote -q "${rewrite_root}family-os.git" >/dev/null 2>&1; then
  fail 'malicious rewrite fixture is inert (control failed)'
fi
oc_run 2026-08-01 HOME="$OC_CASE_ROOT/ambient-home" GIT_CONFIG_GLOBAL="$OC_CASE_ROOT/malicious.gitconfig"
[ "$(oc_status 2026-08-01 705)" = RUN ] || fail 'ambient Git URL rewrite leaked into the hardened lane'
[ "$(git -C "$OC_STATE/mirrors/705" rev-parse HEAD)" = "$(git -C "$OC_REMOTES/family-os.git" rev-parse refs/heads/main)" ] || fail 'rewritten-remote did not fetch the canonical fixture HEAD'
jq -e '.check_metrics["OC-A"].scanned >= 1' "$OC_STATE/report/2026-08-01.json" >/dev/null || fail 'rewritten-remote did not scan the canonical fixture'

oc_case_init local-rewrite
case_roots="$case_roots $OC_CASE_ROOT"
oc_make_remote family-os main fail
oc_write_single_api 706 family-os main
mkdir -p "$OC_STATE/mirrors/706"
git -C "$OC_STATE/mirrors/706" init -q
git -C "$OC_STATE/mirrors/706" config 'url.file:///private/tmp/untrusted/.insteadOf' 'https://github.com/caty-ai/'
oc_run 2026-08-01
[ "$(oc_status 2026-08-01 706)" = NOT-RUN ] || fail 'mirror-local Git URL rewrite was accepted'
jq -e '.cells[0].reason == "git-url-rewrite-refused" and .check_metrics["OC-A"].scanned == 0' "$OC_STATE/report/2026-08-01.json" >/dev/null || fail 'local Git rewrite refusal was not visible'

# Unexpected degraded/skipped vocabulary changes the cell freshness and must
# suppress resolution, even when the checker exits zero.
oc_case_init degraded
case_roots="$case_roots $OC_CASE_ROOT"
oc_make_remote family-os main degraded
mkdir -p "$OC_WORK/family-os/registry"
printf '%s\n' '{"version":1,"modules":[]}' > "$OC_WORK/family-os/registry/modules.json"
oc_commit "$OC_WORK/family-os" add-registry
oc_push_work family-os main
oc_write_single_api 703 family-os main
oc_run 2026-08-01
[ "$(oc_status 2026-08-01 703)" = STALE-INPUT ] || fail 'degraded OC-A output was not STALE-INPUT'
jq -e '.scope.stale_input == 1 and .cells[0].fresh == false' "$OC_STATE/report/2026-08-01.json" >/dev/null || fail 'STALE-INPUT freshness was not exposed'

# A future checker output-format change must not turn non-zero execution into
# a silent green cell merely because the FAILED block parser found no rows.
oc_case_init unparsed-nonzero
case_roots="$case_roots $OC_CASE_ROOT"
oc_make_remote family-os main unparsed
oc_write_single_api 704 family-os main
oc_run 2026-08-01
jq -e '.cells[0].checker_exit == 9 and .check_metrics["OC-A"].flagged == 1 and (.findings.new | length) == 1' "$OC_STATE/report/2026-08-01.json" >/dev/null || fail 'unparsed non-zero checker output became silent under-coverage'
assert_contains 'checker contract changed unexpectedly' "$OC_STATE/report/2026-08-01.json"

printf 'test_lane_org_consistency_oc_a: PASS\n'
