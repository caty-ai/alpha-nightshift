#!/bin/bash
# shellcheck disable=SC1091
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
. "$TEST_DIR/helpers.sh"
. "$TEST_DIR/fixtures/org-consistency/lib.sh"
. "$OC_REPO_ROOT/lib/common.sh"
. "$OC_REPO_ROOT/lib/ledger.sh"

oc_case_init bcd
case_roots=("$OC_CASE_ROOT")
cleanup() {
  rm -rf "${case_roots[@]}"
}
trap cleanup EXIT

oc_make_remote family-os main fail
oc_make_remote demo main none
oc_make_remote missing-lang main none

mkdir -p "$OC_WORK/family-os/registry"
cat > "$OC_WORK/family-os/registry/modules.json" <<'EOF'
{
  "version": 1,
  "languages": ["en", "ja", "zh", "th"],
  "modules": [
    {"repo": "caty-ai/demo"},
    {"repo": "caty-ai/missing-lang"}
  ],
  "retired_repos": ["outside-owner/retired-one"],
  "adjacent": [
    {"repo": "legacy/known-neighbor"},
    {"repo": "caty-ai/family-dev-handbook"}
  ]
}
EOF
oc_commit "$OC_WORK/family-os" registry
oc_push_work family-os main

demo="$OC_WORK/demo"
mkdir -p "$demo/docs" "$demo/scripts"
printf '%s\n' '# Fixture' '' '### Install' > "$demo/README.ja.md"
cat >> "$demo/README.md" <<'EOF'

[missing doc](docs/missing.md)
[missing anchor](#not-there)
[reference missing]: docs/reference-missing.md
[reference ghost]: https://github.com/ref-owner/ref-ghost
[^1]: docs/footnote-definition-is-not-a-link.md
https://github.com/outside-owner/demo
https://github.com/no-owner/ghost
https://github.com/legacy/known-neighbor

```markdown
[fenced missing](docs/fenced-missing.md)
[fenced reference]: docs/fenced-reference.md
https://github.com/no-owner/fenced-ghost
```
EOF
mkdir -p "$demo/.claude"
printf '%s\n' '[claude missing](../docs/claude-missing.md)' > "$demo/.claude/notes.md"
printf '%s\n' '[json missing](../docs/json-missing.md)' > "$demo/.claude/settings.json"
printf '%s\n' \
  '# Agent notes' \
  'Use scripts/existing and scripts/missing.' \
  'Read docs/ghost.md.' \
  'Handbook: https://github.com/caty-ai/family-dev-handbook/blob/main/AGENTS.md' \
  'Ignore docs/*.md and README.md#install.' \
  '```text' \
  'Ignore scripts/fenced-missing and docs/fenced-agent.md.' \
  '```' > "$demo/AGENTS.md"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$demo/scripts/existing"
chmod +x "$demo/scripts/existing"
oc_commit "$demo" bcd-defects
oc_push_work demo main

rm "$OC_WORK/missing-lang/README.th.md"
oc_commit "$OC_WORK/missing-lang" missing-thai
oc_push_work missing-lang main

oc_git_init_work noinput main
printf '%s\n' fixture > "$OC_WORK/noinput/LICENSE"
oc_commit "$OC_WORK/noinput" no-markdown
git clone -q --bare "$OC_WORK/noinput" "$OC_REMOTES/noinput.git"

jq -n '[
  {id:901,name:"family-os",full_name:"caty-ai/family-os",default_branch:"main",clone_url:"https://github.com/caty-ai/family-os.git",archived:false,private:false},
  {id:902,name:"demo",full_name:"caty-ai/demo",default_branch:"main",clone_url:"https://github.com/caty-ai/demo.git",archived:false,private:false},
  {id:903,name:"missing-lang",full_name:"caty-ai/missing-lang",default_branch:"main",clone_url:"https://github.com/caty-ai/missing-lang.git",archived:false,private:false},
  {id:904,name:"noinput",full_name:"caty-ai/noinput",default_branch:"main",clone_url:"https://github.com/caty-ai/noinput.git",archived:false,private:false}
]' > "$OC_API"

oc_run 2026-08-01
report="$OC_STATE/report/2026-08-01.json"
jq -e '
  .complete == true and
  ([.cells[] | select(.check_id == "OC-A")] | length) == 1 and
  ([.cells[] | select(.check_id == "OC-B")] | length) == 3 and
  ([.cells[] | select(.check_id == "OC-C")] | length) == 4 and
  ([.cells[] | select(.check_id == "OC-D")] | length) == 4
' "$report" >/dev/null || fail 'OC-A/B/C/D write-ahead plan has the wrong target matrix'
jq -e '
  [.cells[] | select(.repo_id == 904) | .status] == ["NO-INPUT","NO-INPUT","NO-INPUT"]
' "$report" >/dev/null || fail 'empty OC-B/C/D inputs were not explicit NO-INPUT cells'
for check_id in OC-A OC-B OC-C OC-D; do
  jq -e --arg check_id "$check_id" '
    [.findings.new[] | select(.check_id == $check_id)] | length > 0
  ' "$report" >/dev/null || fail "dedup precondition: $check_id produced no finding"
  jq -e --arg check_id "$check_id" '.check_metrics[$check_id].flagged > 0' "$report" >/dev/null ||
    fail "$check_id metrics did not expose a non-zero flagged count"
done
jq -e '[.findings.new[] | select(.check_id == "OC-B" and .claim_kind == "xrepo:legacy/known-neighbor")] | length == 0' "$report" >/dev/null || fail 'known adjacent repo was not suppressed from OC-B'
jq -e '[.findings.new[] | select(.check_id == "OC-B" and .claim_kind == "xrepo:outside-owner/demo")] | length == 1' "$report" >/dev/null || fail 'OC-B owner mismatch was not independently fingerprinted'
jq -e '[.findings.new[] | select(.check_id == "OC-B" and .claim_kind == "rel:docs/reference-missing.md")] | length == 1' "$report" >/dev/null || fail 'OC-B did not extract a broken reference-style relative link'
jq -e '[.findings.new[] | select(.check_id == "OC-B" and .claim_kind == "xrepo:ref-owner/ref-ghost")] | length == 1' "$report" >/dev/null || fail 'OC-B did not route a reference-style GitHub target through xrepo'
jq -e '[.findings.new[] | select(.check_id == "OC-B" and .claim_kind == "rel:../docs/claude-missing.md")] | length == 1' "$report" >/dev/null || fail 'OC-B did not scan .claude markdown input'
jq -e '[.findings.new[] | select(.check_id == "OC-B" and (.claim_kind == "rel:docs/footnote-definition-is-not-a-link.md" or .claim_kind == "rel:../docs/json-missing.md"))] | length == 0' "$report" >/dev/null || fail 'OC-B treated a GFM footnote or .claude non-Markdown file as a link input'
jq -e '[.findings.new[] | select(.check_id == "OC-C" and .claim_kind == "lang-missing:th")] | length == 1' "$report" >/dev/null || fail 'OC-C language absence was not detected'
jq -e '[.findings.new[] | select(.check_id == "OC-C" and (.claim_kind | startswith("heading-drift:ja:")))] | length > 0' "$report" >/dev/null || fail 'OC-C heading tree drift was not detected'
jq -e '[.findings.new[] | select(.check_id == "OC-D" and .claim_kind == "ref:scripts/missing")] | length == 1' "$report" >/dev/null || fail 'OC-D extensionless scripts reference was not detected'
jq -e '[.findings.new[] | select(.check_id == "OC-D" and (.claim_kind | contains("*")))] | length == 0' "$report" >/dev/null || fail 'OC-D accepted an out-of-scope glob token'
jq -e '[.findings.new[] | select(.claim_kind == "rel:docs/fenced-missing.md" or .claim_kind == "rel:docs/fenced-reference.md" or .claim_kind == "xrepo:no-owner/fenced-ghost")] | length == 0' "$report" >/dev/null || fail 'OC-B scanned fenced examples'
jq -e '[.findings.new[] | select(.check_id == "OC-D" and (.claim_kind == "ref:scripts/fenced-missing" or .claim_kind == "ref:docs/fenced-agent.md" or (.claim_kind | contains("github.com"))))] | length == 0' "$report" >/dev/null || fail 'OC-D scanned fenced paths or URL host segments'
[ ! -s "$OC_CASE_ROOT/lanes/2026-08-01/findings.jsonl" ] || fail 'baseline findings leaked into findings.jsonl'

first_count=$(jq '.findings | length' "$OC_STATE/findings.json")
oc_run 2026-08-02
jq -e '.findings.new | length == 0' "$OC_STATE/report/2026-08-02.json" >/dev/null || fail 'second identical night re-opened deduplicated findings'
[ "$(jq '.findings | length' "$OC_STATE/findings.json")" -eq "$first_count" ] || fail 'second night changed the fingerprint open-set size'

# Losing the family-os registry makes registry-dependent OC-B/C observations
# stale; it cannot create findings or resolve the existing inventory.
rm "$OC_WORK/family-os/registry/modules.json"
oc_commit "$OC_WORK/family-os" remove-registry
oc_push_work family-os main
oc_run 2026-08-03
jq -e '
  ([.cells[] | select(.check_id == "OC-B" or .check_id == "OC-C")] | all(.status == "STALE-INPUT" and .fresh == false and .metrics.flagged == 0)) and
  (.findings.resolved_candidates | length == 0)
' "$OC_STATE/report/2026-08-03.json" >/dev/null || fail 'registry loss did not stale OC-B/C without findings or resolutions'
jq -e '[.findings[] | select(.check_id == "OC-B" or .check_id == "OC-C")] | all(.status == "open")' "$OC_STATE/findings.json" >/dev/null || fail 'registry loss resolved existing OC-B/C findings'

oc_write_checker "$OC_WORK/family-os" pass
tmp_registry="$OC_CASE_ROOT/registry.tmp"
cat > "$tmp_registry" <<'EOF'
{
  "version": 2,
  "languages": ["en", "ja", "zh", "th"],
  "modules": [
    {"repo": "caty-ai/demo"},
    {"repo": "caty-ai/missing-lang"}
  ],
  "retired_repos": ["outside-owner/retired-one"],
  "adjacent": [
    {"repo": "legacy/known-neighbor"},
    {"repo": "caty-ai/family-dev-handbook"}
  ]
}
EOF
mv "$tmp_registry" "$OC_WORK/family-os/registry/modules.json"
oc_commit "$OC_WORK/family-os" fix-registry-check
oc_push_work family-os main
cat > "$demo/README.md" <<'EOF'
# Fixture

## Install

[existing doc](docs/missing.md#not-there)
https://github.com/caty-ai/demo
EOF
oc_write_readmes "$demo"
mkdir -p "$demo/docs"
printf '%s\n' '# Existing' '' '## not there' > "$demo/docs/missing.md"
printf '%s\n' present > "$demo/docs/ghost.md"
printf '%s\n' present > "$demo/docs/claude-missing.md"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$demo/scripts/missing"
chmod +x "$demo/scripts/missing"
oc_commit "$demo" fix-bcd
oc_push_work demo main
oc_write_readmes "$OC_WORK/missing-lang"
oc_commit "$OC_WORK/missing-lang" add-thai
oc_push_work missing-lang main
oc_run 2026-08-04
jq -e '.findings.resolved_candidates | length == 0' "$OC_STATE/report/2026-08-04.json" >/dev/null || fail 'baseline B/C/D findings leaked into close proposals'
jq -e 'all(.findings[]; .check_id == "self-health" or .status == "resolved")' "$OC_STATE/findings.json" >/dev/null || {
  jq -c '.findings[] | select(.check_id != "self-health" and .status != "resolved")' "$OC_STATE/findings.json" >&2
  fail 'fresh repaired cells did not silently resolve the baseline inventory'
}
jq -e '[.findings.self_health[] | select(.claim_kind == "registry-schema-changed")] | length == 1' "$OC_STATE/report/2026-08-04.json" >/dev/null || fail 'registry schema/version change did not emit the A7 self-health finding'

python3 -B - "$OC_CORE" <<'PY' || fail 'claim sanitizer accepted active Markdown/control syntax'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("org_consistency_core", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
raw = "## bad <!-- hidden --> ``` @ops #123 oc-fingerprint: " + "a" * 64 + " useful"
safe = module.Runner.sanitize_claim(raw, 500)
assert "<!--" not in safe and "```" not in safe and "@" not in safe
assert "#123" not in safe and "oc-fingerprint" not in safe and "useful" in safe
PY

# A top-level dotted filename in agent docs is a real repo-path candidate; URL
# and bare-host references remain inert.
oc_case_init oc-d-top-level-dot
case_roots+=("$OC_CASE_ROOT")
oc_make_remote family-os main pass
mkdir -p "$OC_WORK/family-os/registry"
printf '%s\n' '{"version":1,"modules":[{"repo":"caty-ai/dot-demo"}]}' > "$OC_WORK/family-os/registry/modules.json"
oc_commit "$OC_WORK/family-os" add-registry
oc_push_work family-os main
oc_make_remote dot-demo main none
printf '%s\n' \
  '# Agent notes' \
  'Read contributing.md before opening a PR.' \
  'See the handbook at https://github.com/caty-ai/family-dev-handbook/blob/main/AGENTS.md.' \
  'Bare host stays inert: github.com/caty-ai/family-dev-handbook' \
  > "$OC_WORK/dot-demo/AGENTS.md"
oc_commit "$OC_WORK/dot-demo" add-agent-dot-file
oc_push_work dot-demo main
oc_write_two_api 941 family-os 942 dot-demo
oc_run 2026-08-01 OC_ZERO_STREAK_NIGHTS=99
jq -e '[.cells[] | select(.check_id == "OC-D" and .repo_id == 942 and .metrics.flagged == 1)] | length == 1' "$OC_STATE/report/2026-08-01.json" >/dev/null || fail 'OC-D did not flag the missing top-level dotted filename'
jq -e '[.findings.new[] | select(.check_id == "OC-D")] | length == 1' "$OC_STATE/report/2026-08-01.json" >/dev/null || fail 'OC-D reported extra findings alongside the dotted filename control'
jq -e '[.findings.new[] | select(.check_id == "OC-D" and .claim_kind == "ref:contributing.md")] | length == 1' "$OC_STATE/report/2026-08-01.json" >/dev/null || fail 'OC-D did not preserve the top-level dotted filename claim kind'
jq -e '[.findings.new[] | select(.check_id == "OC-D" and (.claim_kind | contains("github.com")))] | length == 0' "$OC_STATE/report/2026-08-01.json" >/dev/null || fail 'OC-D treated URL or bare-host text as a missing repository path'

# A handbook URL is not a repository path token for OC-D.
oc_case_init oc-d-url
case_roots+=("$OC_CASE_ROOT")
oc_make_remote family-os main pass
mkdir -p "$OC_WORK/family-os/registry"
printf '%s\n' '{"version":1,"modules":[{"repo":"caty-ai/url-demo"}]}' > "$OC_WORK/family-os/registry/modules.json"
oc_commit "$OC_WORK/family-os" add-registry
oc_push_work family-os main
oc_make_remote url-demo main none
printf '%s\n' \
  '# Agent notes' \
  'See the handbook at https://github.com/caty-ai/family-dev-handbook/blob/main/AGENTS.md.' \
  'Bare host stays inert: github.com/caty-ai/family-dev-handbook' \
  > "$OC_WORK/url-demo/AGENTS.md"
oc_commit "$OC_WORK/url-demo" add-agent-url
oc_push_work url-demo main
oc_write_two_api 941 family-os 942 url-demo
oc_run 2026-08-01 OC_ZERO_STREAK_NIGHTS=99
jq -e '[.cells[] | select(.check_id == "OC-D" and .repo_id == 942 and .metrics.flagged == 0)] | length == 1' "$OC_STATE/report/2026-08-01.json" >/dev/null || fail 'OC-D treated a URL host/path as a missing repository path'

# New ordinary OC-B/C/D findings map into the real central ledger without a
# skipped record.
oc_case_init bcd-ledger
case_roots+=("$OC_CASE_ROOT")
oc_make_remote family-os main pass
mkdir -p "$OC_WORK/family-os/registry"
printf '%s\n' '{"version":1,"modules":[{"repo":"caty-ai/ledger-demo"}]}' > "$OC_WORK/family-os/registry/modules.json"
oc_commit "$OC_WORK/family-os" add-registry
oc_push_work family-os main
oc_make_remote ledger-demo main none
oc_write_two_api 943 family-os 944 ledger-demo
oc_run 2026-08-01 OC_ZERO_STREAK_NIGHTS=99 OC_STALE_ESCALATE_NIGHTS=99
printf '%s\n' '' '[missing](docs/missing.md)' >> "$OC_WORK/ledger-demo/README.md"
rm "$OC_WORK/ledger-demo/README.th.md"
printf '%s\n' '# Agent notes' 'Run scripts/missing.' > "$OC_WORK/ledger-demo/AGENTS.md"
oc_commit "$OC_WORK/ledger-demo" add-bcd-drift
oc_push_work ledger-demo main
oc_run 2026-08-02 OC_ZERO_STREAK_NIGHTS=99 OC_STALE_ESCALATE_NIGHTS=99
bcd_proposals="$OC_CASE_ROOT/lanes/2026-08-02/findings.jsonl"
jq -e -s 'length > 0 and all(.[]; .kind == "org-consistency/OC-B" or .kind == "org-consistency/OC-C" or .kind == "org-consistency/OC-D")' "$bcd_proposals" >/dev/null || fail 'ordinary B/C/D proposals were not produced for ledger mapping'
STATE_DIR="$OC_CASE_ROOT/central-ledger"
mkdir -p "$STATE_DIR/ledger"
export NIGHT_ID=2026-08-02
ledger_ingest_proposals "$bcd_proposals"
[ "$LEDGER_INGESTED_COUNT" -gt 0 ] && [ "$LEDGER_SKIPPED_COUNT" -eq 0 ] || fail 'ordinary B/C/D proposals were skipped by ledger ingestion'

# Pinned public-HEAD corpus. Files are byte-for-byte copies from the recorded
# commits; the intentionally minimal repository subsets make every scanner
# exercise a stable, non-zero real-world path without network access.
family_corpus="$TEST_DIR/fixtures/corpus/family-os/17ab103"
meetmate_corpus="$TEST_DIR/fixtures/corpus/meetmate/e0b5fc5"
handbook_corpus="$TEST_DIR/fixtures/corpus/family-dev-handbook/49be5f3"
[ "$(<"$family_corpus/UPSTREAM_SHA")" = 17ab1034a964256aac07a0690a880a6592cc2440 ] || fail 'family-os corpus pin changed'
[ "$(<"$meetmate_corpus/UPSTREAM_SHA")" = e0b5fc5c374305e1038665c3a5f3e6f61b518029 ] || fail 'meetmate corpus pin changed'
[ "$(<"$handbook_corpus/UPSTREAM_SHA")" = 49be5f3c2b3ff84415bc8335111504c4fc36b69a ] || fail 'handbook corpus pin changed'
printf '%s  %s\n' \
  b495ef4f9394865525165f1a498a82cd3710973db88f6ac582c296a5aefd356e "$family_corpus/README.md" \
  7d81df720e966ec5dbae6271e491b14b8849b095fdfbc36a6e5854d64ecfa88c "$family_corpus/README.ja.md" \
  8ebf151c40d58003c081e23663818e36bd49da4c8f1c26332f8ac5e59f58ded7 "$family_corpus/README.zh.md" \
  81437cf26a8aa47ea3330af35b904ee25f94ea6339a7a9145e2907cf18ec1982 "$family_corpus/README.th.md" \
  452b374cf909a5c9fd26749790ce8ac1c02b3263b8c2bd3f9bb887bb3926c31d "$meetmate_corpus/README.md" \
  bd074374a616d7812e4517cfafe7f0eee56aa02140806d9e9e7699a769d3d6a4 "$meetmate_corpus/AGENTS.md" \
  34911274374734bf556bd70a0156b8f75ea10b69823e2d63996d95ba05540575 "$meetmate_corpus/package.json" \
  34e4167f6815f1225ef99ce1e1b73b6dcff390c992c2670b31af802a3ef459a5 "$handbook_corpus/README.md" \
  3b98c310db52c4cf2024006f216aadc049f25e6cd8e00de6166ac4cb13885149 "$handbook_corpus/README.ja.md" \
  3c18175c9ec00644c17e6ef708c472d068133294d31874d5fedc01825750bdb2 "$handbook_corpus/docs/05-fail-posture.md" \
  | shasum -a 256 -c >/dev/null || fail 'pinned B/C/D corpus drifted'

oc_case_init real-bcd
case_roots+=("$OC_CASE_ROOT")
mkdir -p "$OC_WORK/family-os"
cp -R "$family_corpus/tools" "$family_corpus/registry" "$OC_WORK/family-os/"
cp "$family_corpus"/README*.md "$OC_WORK/family-os/"
git -C "$OC_WORK/family-os" init -q
git -C "$OC_WORK/family-os" config user.name 'Org Consistency Fixture'
git -C "$OC_WORK/family-os" config user.email 'fixture@example.invalid'
git -C "$OC_WORK/family-os" config core.hooksPath /dev/null
git -C "$OC_WORK/family-os" checkout -qb main
oc_commit "$OC_WORK/family-os" pinned-family-os
git clone -q --bare "$OC_WORK/family-os" "$OC_REMOTES/family-os.git"

oc_git_init_work meetmate main
cp "$meetmate_corpus/README.md" "$meetmate_corpus/AGENTS.md" "$meetmate_corpus/package.json" "$OC_WORK/meetmate/"
cp -R "$meetmate_corpus/bin" "$meetmate_corpus/docs" "$meetmate_corpus/src" "$OC_WORK/meetmate/"
oc_commit "$OC_WORK/meetmate" pinned-meetmate
git clone -q --bare "$OC_WORK/meetmate" "$OC_REMOTES/meetmate.git"

oc_git_init_work family-dev-handbook main
cp "$handbook_corpus/README.md" "$handbook_corpus/README.ja.md" "$OC_WORK/family-dev-handbook/"
oc_commit "$OC_WORK/family-dev-handbook" pinned-handbook
git clone -q --bare "$OC_WORK/family-dev-handbook" "$OC_REMOTES/family-dev-handbook.git"

jq -n '[
  {id:951,name:"family-os",full_name:"caty-ai/family-os",default_branch:"main",clone_url:"https://github.com/caty-ai/family-os.git",archived:false,private:false},
  {id:952,name:"meetmate",full_name:"caty-ai/meetmate",default_branch:"main",clone_url:"https://github.com/caty-ai/meetmate.git",archived:false,private:false},
  {id:953,name:"family-dev-handbook",full_name:"caty-ai/family-dev-handbook",default_branch:"main",clone_url:"https://github.com/caty-ai/family-dev-handbook.git",archived:false,private:false}
]' > "$OC_API"
oc_run 2026-08-10
real_report="$OC_STATE/report/2026-08-10.json"
jq -e '
  .complete == true and
  ([.cells[] | select(.check_id == "OC-A")] | length) == 1 and
  ([.cells[] | select(.check_id == "OC-B")] | length) == 2 and
  ([.cells[] | select(.check_id == "OC-C")] | length) == 3 and
  ([.cells[] | select(.check_id == "OC-D")] | length) == 3 and
  ([.cells[] | select(.check_id == "OC-C" and .repo_id == 951 and .metrics.scanned == 4)] | length) == 1 and
  .check_metrics["OC-B"].flagged == 64 and
  .check_metrics["OC-C"].flagged == 5 and
  .check_metrics["OC-D"].flagged == 1
' "$real_report" >/dev/null || {
  jq -c '.check_metrics | {"OC-B": .["OC-B"].flagged, "OC-C": .["OC-C"].flagged, "OC-D": .["OC-D"].flagged}' "$real_report" >&2
  fail 'pinned real corpus drifted from the fixed OC-B/C/D finding counts'
}
jq -e '[.findings.new[] | select(.check_id == "OC-D")] | length == 1' "$real_report" >/dev/null || fail 'real corpus did not keep the fixed non-zero OC-D count'
jq -e '[.findings.new[] | select(.check_id == "OC-D" and .claim_kind == "ref:contributing.md")] | length == 1' "$real_report" >/dev/null || fail 'real corpus OC-D drift did not stay pinned to the top-level dotted file reference'
[ ! -s "$OC_CASE_ROOT/lanes/2026-08-10/findings.jsonl" ] || fail 'real-corpus baseline leaked proposals'

printf 'test_lane_org_consistency_oc_bcd: PASS\n'
