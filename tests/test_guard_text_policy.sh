#!/bin/bash
set -euo pipefail

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
ROOT=$(CDPATH= cd -- "$TEST_DIR/.." && pwd -P)
. "$TEST_DIR/helpers.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-text-policy-test.XXXXXX")
cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT
TEST_TMP=$(CDPATH= cd -- "$TEST_TMP" && pwd -P)
POLICY=$ROOT/guard/text-policy.sh
MANIFEST=$ROOT/config/guard-activation.example.json
GIT=/opt/homebrew/bin/git

pass_text() {
  label=$1
  kind=$2
  input=$3
  "$POLICY" --kind "$kind" --input "$input" > "$TEST_TMP/$label.json"
  /usr/bin/jq -e \
    --arg kind "$kind" '
      keys == [
        "accepted_sha256",
        "bytes",
        "gitleaks_sha256",
        "gitleaks_version",
        "kind",
        "mode",
        "scanner_policy_sha256",
        "schema",
        "verdict",
        "write_mode"
      ] and
      .schema == "alpha-nightshift/text-policy-evidence/v1" and
      .mode == "LOCAL_ONLY_REMOTE_UNPROVEN" and
      .write_mode == false and
      .verdict == "PASS_LOCAL_ONLY" and
      .kind == $kind and
      (.bytes | type == "number" and . >= 1) and
      (.accepted_sha256 | test("^[a-f0-9]{64}$")) and
      (.scanner_policy_sha256 | test("^[a-f0-9]{64}$")) and
      .gitleaks_version == "8.30.1" and
      (.gitleaks_sha256 | test("^[a-f0-9]{64}$"))
    ' "$TEST_TMP/$label.json" >/dev/null ||
    fail "clean $kind text did not produce exact evidence"
}

deny_text() {
  label=$1
  kind=$2
  input=$3
  if "$POLICY" --kind "$kind" --input "$input" \
    > "$TEST_TMP/$label.out" 2>&1; then
    fail "text policy accepted denied fixture: $label"
  fi
  assert_contains 'LOCAL_ONLY_REMOTE_UNPROVEN' "$TEST_TMP/$label.out"
}

make_clean_fixture() {
  output=$1
  bytes=$2
  terminal_lf=$3
  /usr/bin/perl -e '
    use strict;
    use warnings;
    my ($bytes,$terminal_lf)=@ARGV;
    my $unit="ordinary ";
    my $content_bytes=$bytes-$terminal_lf;
    die "invalid fixture size" if $content_bytes < 1;
    print $unit x int($content_bytes/length($unit));
    print substr($unit,0,$content_bytes%length($unit));
    print "\n" if $terminal_lf;
  ' "$bytes" "$terminal_lf" > "$output"
  actual_bytes=$(/usr/bin/wc -c < "$output" | /usr/bin/tr -d ' ')
  [ "$actual_bytes" -eq "$bytes" ] ||
    fail "clean fixture does not have the requested byte count: $output"
}

/usr/bin/printf '%s' 'Safe local title' > "$TEST_TMP/title.txt"
/usr/bin/printf '%s\n' 'Safe local commit message' > "$TEST_TMP/commit.txt"
/usr/bin/printf '%s\n' 'Safe local body with two words.' > "$TEST_TMP/body.txt"
/usr/bin/printf '%s\n' 'Safe local comment.' > "$TEST_TMP/comment.txt"
/usr/bin/printf '%s' 'OrdinaryCfFreeTitle' > "$TEST_TMP/cf-free-title.txt"
/usr/bin/printf '%s\n' 'Ordinary prose without format characters.' \
  > "$TEST_TMP/cf-free-body.txt"
/usr/bin/printf '%s' 'OrdinaryPrivateUseFreeTitle' \
  > "$TEST_TMP/co-free-title.txt"
/usr/bin/printf '%s\n' 'Ordinary prose without private-use characters.' \
  > "$TEST_TMP/co-free-body.txt"
make_clean_fixture "$TEST_TMP/title-512.txt" 512 0
make_clean_fixture "$TEST_TMP/body-1-kib.txt" 1024 1
make_clean_fixture "$TEST_TMP/body-10-kib.txt" 10240 1
make_clean_fixture "$TEST_TMP/body-60-kib.txt" 61440 1
make_clean_fixture "$TEST_TMP/commit-message-10-kib.txt" 10240 1
/usr/bin/perl -e 'print "a" x 965, "\n"' > "$TEST_TMP/body-966.txt"
/usr/bin/perl -e 'print "a" x 966, "\n"' > "$TEST_TMP/body-967.txt"
/usr/bin/printf '%s\n' 'これは通常の日本語の説明文です。' \
  > "$TEST_TMP/unicode-prose.txt"
/usr/bin/printf 'これは通常の日本語の段落です。\n\n次の段落も安全です。\n' \
  > "$TEST_TMP/unicode-paragraphs.txt"
/usr/bin/perl -e 'print "Ordinary local prose remains safe. " x 12, "\n"' \
  > "$TEST_TMP/long-ascii-prose.txt"
/usr/bin/perl -Mutf8 -CSD -e \
  'print "これは通常の日本語の長い説明段落です。\n" for 1..12' \
  > "$TEST_TMP/long-unicode-prose.txt"
/usr/bin/printf '%s\n' \
  'DocumentationSummary is ordinary prose; token: discussed locally.' \
  > "$TEST_TMP/candidate-before-token-colon.txt"
/usr/bin/printf '%s\n' \
  'LongHeadingIdentifier is ordinary prose; secret: discussed locally.' \
  > "$TEST_TMP/candidate-before-secret-colon.txt"
/usr/bin/printf '%s\n' \
  'DocumentationSummary は通常の説明です。token: はローカルで議論します。' \
  > "$TEST_TMP/japanese-candidate-before-evidence.txt"
/usr/bin/printf 'This sentence ends with token.\nDocumentationSummary remains ordinary prose.\n' \
  > "$TEST_TMP/token-period-before-candidate.txt"
/usr/bin/printf '説明は token。で終わります。\nDocumentationSummary は通常の見出しです。\n' \
  > "$TEST_TMP/japanese-token-period-before-candidate.txt"
/usr/bin/printf 'This sentence ends with token.\nNotes:\nDocumentationSummary remains ordinary prose.\n' \
  > "$TEST_TMP/token-period-before-later-colon.txt"
/usr/bin/printf '説明は token。で終わります。\nNotes:\nDocumentationSummary は通常の見出しです。\n' \
  > "$TEST_TMP/japanese-token-period-before-later-colon.txt"
/usr/bin/printf 'This sentence ends with tokenized.\nNotes:\nDocumentationSummary remains ordinary prose.\n' \
  > "$TEST_TMP/token-suffix-period-before-later-colon.txt"
/usr/bin/perl -CSD -e \
  'print "This sentence ends with secretive\x{3002}\nNotes:\nDocumentationSummary remains ordinary prose.\n"' \
  > "$TEST_TMP/secret-suffix-unicode-period-before-later-colon.txt"
/usr/bin/perl -CSD -e \
  'print "This sentence ends with token.\n\x{8AAC}\x{660E}:\nDocumentationSummary remains ordinary prose.\n"' \
  > "$TEST_TMP/period-before-japanese-label.txt"
/usr/bin/perl -CSD -e \
  'print "This sentence ends with token.\n\x{2C99}\x{2C89}\x{2C97}\x{2C81}:\nDocumentationSummary remains ordinary prose.\n"' \
  > "$TEST_TMP/period-before-coptic-label.txt"
/usr/bin/perl -CSD -e \
  'print "This sentence ends with token.\n\x{03B4}\x{2C99}\x{044B}\x{014B}:\nDocumentationSummary remains ordinary prose.\n"' \
  > "$TEST_TMP/period-before-mixed-label.txt"
/usr/bin/printf 'This sentence ends with token.\nProject:\nDocumentationSummary remains ordinary prose.\n' \
  > "$TEST_TMP/period-before-project-label.txt"
/usr/bin/printf 'This sentence ends with token.\nSubject:\nDocumentationSummary remains ordinary prose.\n' \
  > "$TEST_TMP/period-before-subject-label.txt"
/usr/bin/printf 'This sentence ends with token.\nStatus:\nDocumentationSummary remains ordinary prose.\n' \
  > "$TEST_TMP/period-before-s-label.txt"
/usr/bin/printf 'This sentence ends with token.\nAgenda:\nDocumentationSummary remains ordinary prose.\n' \
  > "$TEST_TMP/period-before-a-label.txt"
/usr/bin/printf 'This sentence ends with token.\nsec:\nXylophone remains ordinary prose.\nDocumentationSummary remains ordinary prose.\n' \
  > "$TEST_TMP/period-partial-prefix-diverges.txt"
/usr/bin/printf '説明:\n\nDocumentationSummary は通常の説明です。\n' \
  > "$TEST_TMP/japanese-label-before-candidate.txt"
/usr/bin/printf '説明 DocumentationGuide:\n\nDocumentationSummary は通常の説明です。\n' \
  > "$TEST_TMP/japanese-label-with-english.txt"
/usr/bin/printf 'JSON形式とUTF-8形式について説明します。\n' \
  > "$TEST_TMP/japanese-technical-terms.txt"
/usr/bin/perl -CSD -e \
  'print "\x{03B4}\x{03BF}\x{03BA}\x{03B9}\x{03BC}\x{03B7}:\nDocumentationSummary remains ordinary prose.\n"' \
  > "$TEST_TMP/greek-non-keyword-label.txt"
/usr/bin/perl -CSD -e \
  'print "\x{043F}\x{0440}\x{0438}\x{043C}\x{0435}\x{0440}:\nDocumentationSummary remains ordinary prose.\n"' \
  > "$TEST_TMP/cyrillic-non-keyword-label.txt"
/usr/bin/perl -CSD -e \
  'print "\x{03B4}\x{043E}\x{03BB}\x{0436}:\nDocumentationSummary remains ordinary prose.\n"' \
  > "$TEST_TMP/mixed-greek-cyrillic-non-keyword-label.txt"
/usr/bin/perl -CSD -e \
  'print "Project\x{2122}Label:\nDocumentationSummary remains ordinary prose.\n"' \
  > "$TEST_TMP/unrelated-so-label.txt"
/usr/bin/perl -CSD -e \
  'print "Budget\x{20AC}Label:\nDocumentationSummary remains ordinary prose.\n"' \
  > "$TEST_TMP/unrelated-sc-label.txt"
/usr/bin/perl -CSD -e \
  'print "Project\x{00B7}Label:\nDocumentationSummary remains ordinary prose.\n"' \
  > "$TEST_TMP/unmapped-punctuation-label.txt"
/usr/bin/perl -CSD -e \
  'print "Project\x{02B0}Label:\nDocumentationSummary remains ordinary prose.\n"' \
  > "$TEST_TMP/unmapped-modifier-label.txt"
/usr/bin/perl -CSD -e \
  'print "The \x{212E} character is discussed in ordinary prose.\n"' \
  > "$TEST_TMP/direct-source-symbol-prose.txt"
/usr/bin/perl -CSD -e \
  'print "\x{3007} is an ordinary character in this explanation.\n"' \
  > "$TEST_TMP/direct-source-cjk-prose.txt"
/usr/bin/perl -CSD -e \
  'print "The \x{1DA6} character is discussed in ordinary prose.\n"' \
  > "$TEST_TMP/two-stage-source-prose.txt"
/usr/bin/perl -CSD -e \
  'print "The symbols \x{20A8} and \x{2116} appear in ordinary prose.\n"' \
  > "$TEST_TMP/multi-unit-source-prose.txt"
/usr/bin/perl -CSD -e \
  'print "\x{03B4}\x{03BF}\x{03BA}\x{03B9}\x{03BC}\x{03AE}:\nDocumentationSummary remains ordinary prose.\n"' \
  > "$TEST_TMP/accented-greek-non-keyword-label.txt"
/usr/bin/perl -CSD -e \
  'print "\x{0451}\x{043B}\x{043A}\x{0430}:\nDocumentationSummary remains ordinary prose.\n"' \
  > "$TEST_TMP/accented-cyrillic-non-keyword-label.txt"
/usr/bin/perl -CSD -e \
  'print "\x{2C99}\x{2C89}\x{2C97}\x{2C81}:\nDocumentationSummary remains ordinary prose.\n"' \
  > "$TEST_TMP/coptic-non-keyword-label.txt"
/usr/bin/perl -CSD -e \
  'print "\x{014B}\x{00F8}\x{0111}:\nDocumentationSummary remains ordinary prose.\n"' \
  > "$TEST_TMP/latin-extended-non-keyword-label.txt"
/usr/bin/perl -CSD -e \
  'print "\x{03B4}\x{2C99}\x{044B}\x{014B}:\nDocumentationSummary remains ordinary prose.\n"' \
  > "$TEST_TMP/generated-mixed-non-keyword-label.txt"
pass_text title title "$TEST_TMP/title.txt"
pass_text commit commit_message "$TEST_TMP/commit.txt"
pass_text body body "$TEST_TMP/body.txt"
pass_text comment comment "$TEST_TMP/comment.txt"
pass_text cf-free-title title "$TEST_TMP/cf-free-title.txt"
pass_text cf-free-body body "$TEST_TMP/cf-free-body.txt"
pass_text co-free-title title "$TEST_TMP/co-free-title.txt"
pass_text co-free-body body "$TEST_TMP/co-free-body.txt"
pass_text title-512 title "$TEST_TMP/title-512.txt"
pass_text body-966 body "$TEST_TMP/body-966.txt"
pass_text body-967 body "$TEST_TMP/body-967.txt"
pass_text body-1-kib body "$TEST_TMP/body-1-kib.txt"
pass_text body-10-kib body "$TEST_TMP/body-10-kib.txt"
pass_text body-60-kib body "$TEST_TMP/body-60-kib.txt"
pass_text unicode-prose body "$TEST_TMP/unicode-prose.txt"
pass_text unicode-paragraphs body "$TEST_TMP/unicode-paragraphs.txt"
pass_text long-ascii-prose body "$TEST_TMP/long-ascii-prose.txt"
pass_text long-unicode-prose body "$TEST_TMP/long-unicode-prose.txt"
pass_text candidate-before-token-colon body \
  "$TEST_TMP/candidate-before-token-colon.txt"
pass_text candidate-before-secret-colon body \
  "$TEST_TMP/candidate-before-secret-colon.txt"
pass_text japanese-candidate-before-evidence body \
  "$TEST_TMP/japanese-candidate-before-evidence.txt"
pass_text token-period-before-candidate body \
  "$TEST_TMP/token-period-before-candidate.txt"
pass_text japanese-token-period-before-candidate body \
  "$TEST_TMP/japanese-token-period-before-candidate.txt"
pass_text token-period-before-later-colon body \
  "$TEST_TMP/token-period-before-later-colon.txt"
pass_text japanese-token-period-before-later-colon body \
  "$TEST_TMP/japanese-token-period-before-later-colon.txt"
pass_text token-suffix-period-before-later-colon body \
  "$TEST_TMP/token-suffix-period-before-later-colon.txt"
pass_text secret-suffix-unicode-period-before-later-colon body \
  "$TEST_TMP/secret-suffix-unicode-period-before-later-colon.txt"
pass_text period-before-japanese-label body \
  "$TEST_TMP/period-before-japanese-label.txt"
pass_text period-before-coptic-label body \
  "$TEST_TMP/period-before-coptic-label.txt"
pass_text period-before-mixed-label body \
  "$TEST_TMP/period-before-mixed-label.txt"
pass_text period-before-project-label body \
  "$TEST_TMP/period-before-project-label.txt"
pass_text period-before-subject-label body \
  "$TEST_TMP/period-before-subject-label.txt"
pass_text period-before-s-label body \
  "$TEST_TMP/period-before-s-label.txt"
pass_text period-before-a-label body \
  "$TEST_TMP/period-before-a-label.txt"
pass_text period-partial-prefix-diverges body \
  "$TEST_TMP/period-partial-prefix-diverges.txt"
pass_text japanese-label-before-candidate body \
  "$TEST_TMP/japanese-label-before-candidate.txt"
pass_text japanese-label-with-english body \
  "$TEST_TMP/japanese-label-with-english.txt"
pass_text japanese-technical-terms body \
  "$TEST_TMP/japanese-technical-terms.txt"
pass_text greek-non-keyword-label body \
  "$TEST_TMP/greek-non-keyword-label.txt"
pass_text cyrillic-non-keyword-label body \
  "$TEST_TMP/cyrillic-non-keyword-label.txt"
pass_text mixed-greek-cyrillic-non-keyword-label body \
  "$TEST_TMP/mixed-greek-cyrillic-non-keyword-label.txt"
pass_text unrelated-so-label body "$TEST_TMP/unrelated-so-label.txt"
pass_text unrelated-sc-label body "$TEST_TMP/unrelated-sc-label.txt"
pass_text unmapped-punctuation-label body \
  "$TEST_TMP/unmapped-punctuation-label.txt"
pass_text unmapped-modifier-label body \
  "$TEST_TMP/unmapped-modifier-label.txt"
pass_text direct-source-symbol-prose body \
  "$TEST_TMP/direct-source-symbol-prose.txt"
pass_text direct-source-cjk-prose body \
  "$TEST_TMP/direct-source-cjk-prose.txt"
pass_text two-stage-source-prose body \
  "$TEST_TMP/two-stage-source-prose.txt"
pass_text multi-unit-source-prose body \
  "$TEST_TMP/multi-unit-source-prose.txt"
pass_text accented-greek-non-keyword-label body \
  "$TEST_TMP/accented-greek-non-keyword-label.txt"
pass_text accented-cyrillic-non-keyword-label body \
  "$TEST_TMP/accented-cyrillic-non-keyword-label.txt"
pass_text coptic-non-keyword-label body \
  "$TEST_TMP/coptic-non-keyword-label.txt"
pass_text latin-extended-non-keyword-label body \
  "$TEST_TMP/latin-extended-non-keyword-label.txt"
pass_text generated-mixed-non-keyword-label body \
  "$TEST_TMP/generated-mixed-non-keyword-label.txt"
/usr/bin/printf '%s\n' 'Commit abcdef is local.' > "$TEST_TMP/sha-six.txt"
pass_text sha-six body "$TEST_TMP/sha-six.txt"
/usr/bin/printf '%s\n' \
  'Commit 0123456789abcdef0123456789abcdef012345678 is local.' \
  > "$TEST_TMP/sha-forty-one.txt"
pass_text sha-forty-one body "$TEST_TMP/sha-forty-one.txt"
/usr/bin/perl -e 'print "A" x 500, "\n"' > "$TEST_TMP/long-ascii-line.txt"
pass_text long-ascii-line body "$TEST_TMP/long-ascii-line.txt"

expected_body_sha=$(/usr/bin/shasum -a 256 "$TEST_TMP/body.txt" |
  /usr/bin/awk '{print $1}')
expected_body_bytes=$(/usr/bin/wc -c < "$TEST_TMP/body.txt" |
  /usr/bin/tr -d ' ')
/usr/bin/jq -e \
  --arg sha "$expected_body_sha" \
  --argjson bytes "$expected_body_bytes" '
    .accepted_sha256 == $sha and .bytes == $bytes
  ' "$TEST_TMP/body.json" >/dev/null ||
  fail "evidence did not bind the exact accepted bytes"
assert_not_contains 'Safe local body' "$TEST_TMP/body.json"

deny_fixture() {
  label=$1
  bytes=$2
  /usr/bin/printf '%b' "$bytes" > "$TEST_TMP/$label.txt"
  deny_text "$label" body "$TEST_TMP/$label.txt"
}

deny_fixture raw-url 'Visit https://example.invalid/path\n'
deny_fixture www-url 'Visit www.example.invalid now.\n'
deny_fixture autolink '<user@example.invalid>\n'
deny_fixture raw-html '<details>hidden text</details>\n'
deny_fixture markdown-link '[label](destination)\n'
deny_fixture markdown-image '![alt](asset)\n'
deny_fixture markdown-reference-link '[label][ref]\n'
deny_fixture markdown-reference '[ref]: destination\n'
deny_fixture mention '@night-bot\n'
deny_fixture issue-reference 'Discussion #123\n'
deny_fixture gh-reference 'Discussion GH-123\n'
deny_fixture repo-reference 'Discussion owner/repo#123\n'
deny_fixture closing-keyword 'Fixes #123\n'
deny_fixture sha-seven 'Commit abcdef1 is relevant.\n'
deny_fixture sha-forty 'Commit 0123456789abcdef0123456789abcdef01234567 is relevant.\n'
deny_fixture task-list '- [ ] mutate state\n'
deny_fixture backslash-escape 'Escaped \\#123 reference.\n'
deny_fixture percent-escape 'Encoded %23123 reference.\n'
deny_fixture entity-escape 'Encoded &#35;123 reference.\n'
deny_fixture fullwidth-reference 'Discussion ＃123\n'
deny_fixture confusable-slash 'Discussion owner⁄repo#123\n'
deny_fixture default-ignorable 'Discussion #​123\n'
deny_fixture unicode-line-separator 'First line\342\200\250Second line\n'
deny_fixture unicode-paragraph-separator 'First line\342\200\251Second line\n'
deny_fixture unicode-next-line 'First line\302\205Second line\n'
compat_secret_fullwidth_colon='api_key：ABCDEFGHIJKLMNOPQRSTUVWXYZ123456'
/usr/bin/printf '%s\n' "$compat_secret_fullwidth_colon" \
  > "$TEST_TMP/compat-secret-fullwidth-colon.txt"
deny_text compat-secret-fullwidth-colon body \
  "$TEST_TMP/compat-secret-fullwidth-colon.txt"
assert_not_contains "$compat_secret_fullwidth_colon" \
  "$TEST_TMP/compat-secret-fullwidth-colon.out"
compat_secret_fullwidth_equals='api_key＝ABCDEFGHIJKLMNOPQRSTUVWXYZ123456'
/usr/bin/printf '%s\n' "$compat_secret_fullwidth_equals" \
  > "$TEST_TMP/compat-secret-fullwidth-equals.txt"
deny_text compat-secret-fullwidth-equals body \
  "$TEST_TMP/compat-secret-fullwidth-equals.txt"
assert_not_contains "$compat_secret_fullwidth_equals" \
  "$TEST_TMP/compat-secret-fullwidth-equals.out"
compat_secret_greek_kappa='api_κey=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456'
/usr/bin/printf '%s\n' "$compat_secret_greek_kappa" \
  > "$TEST_TMP/compat-secret-greek-kappa.txt"
deny_text compat-secret-greek-kappa body \
  "$TEST_TMP/compat-secret-greek-kappa.txt"
assert_not_contains "$compat_secret_greek_kappa" \
  "$TEST_TMP/compat-secret-greek-kappa.out"
compat_secret_confusable_colon='token꞉ABCDEFGHIJKLMNOPQRSTUVWXYZ123456'
/usr/bin/printf '%s\n' "$compat_secret_confusable_colon" \
  > "$TEST_TMP/compat-secret-confusable-colon.txt"
deny_text compat-secret-confusable-colon body \
  "$TEST_TMP/compat-secret-confusable-colon.txt"
assert_not_contains "$compat_secret_confusable_colon" \
  "$TEST_TMP/compat-secret-confusable-colon.out"

deny_perl_fixture() {
  label=$1
  program=$2
  /usr/bin/perl -CSD -e "$program" > "$TEST_TMP/$label.txt"
  deny_text "$label" body "$TEST_TMP/$label.txt"
}

deny_perl_fixture mapped-estimated-symbol-secret \
  'print "s\x{212E}cret=ABCDEFGHIJKLMNOPQRSTUVWX\n"'
deny_text mapped-estimated-symbol-secret-commit commit_message \
  "$TEST_TMP/mapped-estimated-symbol-secret.txt"
deny_perl_fixture sigma-token \
  'print "\x{03C4}\x{03C3}\x{03BA}\x{03B5}\x{03BD}=ABCDEFGHIJKLMNOPQRSTUVWX\n"'
deny_text sigma-token-commit commit_message \
  "$TEST_TMP/sigma-token.txt"
deny_perl_fixture uppercase-sigma-secret \
  'print "\x{03A3}ecret=ABCDEFGHIJKLMNOPQRSTUVWX\n"'
deny_text uppercase-sigma-secret-commit commit_message \
  "$TEST_TMP/uppercase-sigma-secret.txt"
deny_perl_fixture uppercase-sigma-token \
  'print "t\x{03A3}ken=ABCDEFGHIJKLMNOPQRSTUVWX\n"'
deny_text uppercase-sigma-token-commit commit_message \
  "$TEST_TMP/uppercase-sigma-token.txt"
deny_perl_fixture decomposed-capital-sigma-secret \
  'print "\x{1D6BA}ecret=ABCDEFGHIJKLMNOPQRSTUVWX\n"'
deny_text decomposed-capital-sigma-secret-commit commit_message \
  "$TEST_TMP/decomposed-capital-sigma-secret.txt"
deny_perl_fixture decomposed-capital-sigma-token \
  'print "t\x{1D6BA}ken=ABCDEFGHIJKLMNOPQRSTUVWX\n"'
deny_text decomposed-capital-sigma-token-commit commit_message \
  "$TEST_TMP/decomposed-capital-sigma-token.txt"
deny_perl_fixture pending-mapped-source-secret \
  'print "token.\nas:\n\x{212E}cret.ABCDEFGHIJKLMNOPQRSTUVWX\n"'
deny_text pending-mapped-source-secret-commit commit_message \
  "$TEST_TMP/pending-mapped-source-secret.txt"
deny_perl_fixture pending-sigma-token \
  'print "token.\nat:\n\x{03C3}ken.ABCDEFGHIJKLMNOPQRSTUVWX\n"'
deny_text pending-sigma-token-commit commit_message \
  "$TEST_TMP/pending-sigma-token.txt"

# Enumerate the frozen direct-source table, generate one real fixed-key body
# for every row, and separately identify every row whose Unicode category
# would otherwise make it a soft separator.
DIRECT_SOURCE_DIR=$TEST_TMP/direct-keyword-sources
mkdir -p "$DIRECT_SOURCE_DIR"
/usr/bin/perl -CSDA -e '
  use strict;
  use warnings;
  my ($policy,$output_dir,$manifest,$counts,$shadowed)=@ARGV;
  my %fixed=(
    a=>["","pikey"], p=>["a","ikey"], i=>["ap","key"],
    k=>["api","ey"], e=>["apik","y"], y=>["apike",""],
    s=>["","ecret"], c=>["se","ret"], r=>["sec","et"],
    t=>["secre",""], o=>["t","ken"], n=>["toke",""]
  );
  open my $source,"<",$policy or exit 90;
  open my $manifest_out,">",$manifest or exit 91;
  open my $shadowed_out,">",$shadowed or exit 92;
  my ($inside,$target)=(0,"");
  my (%count,%seen);
  while (<$source>) {
    $inside=1,next if /my %keyword_skeleton_source_sets=\(/;
    last if $inside && /^  \);/;
    next unless $inside;
    $target=$1 if /^    "([apikeysctorn])" =>/;
    while (/"([0-9A-F ]+)"/g) {
      for my $hex (grep { length } split /\s+/,$1) {
        my $character=chr hex $hex;
        $count{$target}++;
        $seen{$hex}++;
        open my $fixture,">:encoding(UTF-8)",
          "$output_dir/$target-$hex.txt" or exit 93;
        print {$fixture}
          $fixed{$target}[0],$character,$fixed{$target}[1],
          "=ABCDEFGHIJKLMNOPQRSTUVWX\n" or exit 94;
        close $fixture or exit 95;
        print {$manifest_out} "$target $hex\n" or exit 96;
        if ($character eq "\x{2800}" ||
            $character =~
              /[\p{White_Space}\p{P}\p{S}\p{Lm}\p{Han}\p{Hiragana}\p{Katakana}]/) {
          print {$shadowed_out} "$target $hex\n" or exit 97;
        }
      }
    }
  }
  close $source or exit 98;
  close $manifest_out or exit 99;
  close $shadowed_out or exit 100;
  open my $counts_out,">",$counts or exit 101;
  print {$counts_out}
    join(" ",map { "$_=$count{$_}" } qw(a p i k e y s c r t o n)),
    " total=",scalar(grep { $seen{$_} } keys %seen),
    " unique=",scalar(grep { $seen{$_} == 1 } keys %seen),"\n" or exit 102;
  close $counts_out or exit 103;
' "$POLICY" "$DIRECT_SOURCE_DIR" \
  "$TEST_TMP/direct-source-manifest.txt" \
  "$TEST_TMP/direct-source-counts.txt" \
  "$TEST_TMP/direct-source-shadowed.txt"

expected_direct_counts='a=50 p=61 i=38 k=41 e=48 y=62 s=44 c=51 r=41 t=46 o=126 n=39 total=647 unique=647'
[ "$(/bin/cat "$TEST_TMP/direct-source-counts.txt")" = \
  "$expected_direct_counts" ] ||
  fail "embedded direct-source table cardinalities changed"
/usr/bin/sort -k2,2 "$TEST_TMP/direct-source-shadowed.txt" \
  > "$TEST_TMP/direct-source-shadowed.sorted.txt"
/usr/bin/printf '%s\n' \
  'i 02DB' \
  'i 037A' \
  'r 1D216' \
  'c 1F74C' \
  't 1F768' \
  'e 212E' \
  't 22A4' \
  'e 22FF' \
  'i 2373' \
  'p 2374' \
  'a 237A' \
  't 27D9' \
  'o 3007' > "$TEST_TMP/direct-source-shadowed.expected.txt"
/usr/bin/cmp -s \
  "$TEST_TMP/direct-source-shadowed.expected.txt" \
  "$TEST_TMP/direct-source-shadowed.sorted.txt" ||
  fail "mapped soft-category source set changed"

while IFS=' ' read -r direct_target direct_code; do
  deny_text "direct-source-$direct_target-$direct_code" body \
    "$DIRECT_SOURCE_DIR/$direct_target-$direct_code.txt"
done < "$TEST_TMP/direct-source-manifest.txt"
while IFS=' ' read -r direct_target direct_code; do
  deny_text "shadowed-source-$direct_code-commit" commit_message \
    "$DIRECT_SOURCE_DIR/$direct_target-$direct_code.txt"
done < "$TEST_TMP/direct-source-shadowed.txt"

DUAL_SOURCE_DIR=$TEST_TMP/dual-role-sources
mkdir -p "$DUAL_SOURCE_DIR"
while IFS=' ' read -r dual_target dual_code; do
  for dual_keyword in apikey secret token; do
    dual_length=${#dual_keyword}
    dual_split=1
    while [ "$dual_split" -lt "$dual_length" ]; do
      dual_fixture=$DUAL_SOURCE_DIR/$dual_code-$dual_keyword-$dual_split.txt
      /usr/bin/perl -CSD -e '
        my ($hex,$keyword,$split)=@ARGV;
        print substr($keyword,0,$split),chr(hex $hex),
          substr($keyword,$split),
          "=ABCDEFGHIJKLMNOPQRSTUVWX\n";
      ' "$dual_code" "$dual_keyword" "$dual_split" > "$dual_fixture"
      deny_text \
        "dual-$dual_code-$dual_keyword-$dual_split" \
        body "$dual_fixture"
      dual_split=$((dual_split + 1))
    done
  done

  if [ "$dual_target" = e ]; then
    dual_off_keyword=token
  else
    dual_off_keyword=secret
  fi
  dual_off_fixture=$DUAL_SOURCE_DIR/$dual_code-off-position.txt
  /usr/bin/perl -CSD -e '
    my ($hex,$keyword)=@ARGV;
    print substr($keyword,0,1),chr(hex $hex),
      substr($keyword,1),
      "=ABCDEFGHIJKLMNOPQRSTUVWX\n";
  ' "$dual_code" "$dual_off_keyword" > "$dual_off_fixture"
  deny_text "dual-$dual_code-off-position-commit" commit_message \
    "$dual_off_fixture"
done < "$TEST_TMP/direct-source-shadowed.txt"

/usr/bin/perl -CSD -e \
  'print "sec\x{212E}ret=ABCDEFGHIJKLMNOPQRSTUVWX"' \
  > "$TEST_TMP/dual-off-position-title.txt"
deny_text dual-off-position-title title \
  "$TEST_TMP/dual-off-position-title.txt"
/usr/bin/perl -CSD -e \
  'print "sec\x{212E}ret=ABCDEFGHIJKLMNOPQRSTUVWX\n"' \
  > "$TEST_TMP/dual-off-position-all-multiline.txt"
deny_text dual-off-position-comment comment \
  "$TEST_TMP/dual-off-position-all-multiline.txt"
deny_text dual-off-position-body body \
  "$TEST_TMP/dual-off-position-all-multiline.txt"
deny_text dual-off-position-commit commit_message \
  "$TEST_TMP/dual-off-position-all-multiline.txt"
deny_perl_fixture dual-matched-position-duplicate \
  'print "s\x{212E}ecret=ABCDEFGHIJKLMNOPQRSTUVWX\n"'
deny_text dual-matched-position-duplicate-commit commit_message \
  "$TEST_TMP/dual-matched-position-duplicate.txt"
deny_perl_fixture pending-dual-off-position \
  'print "token.\nase:\nc\x{212E}ret.ABCDEFGHIJKLMNOPQRSTUVWX\n"'
deny_text pending-dual-off-position-commit commit_message \
  "$TEST_TMP/pending-dual-off-position.txt"
deny_perl_fixture pending-dual-matched-position-duplicate \
  'print "token.\nas:\n\x{212E}ecret.ABCDEFGHIJKLMNOPQRSTUVWX\n"'
deny_text pending-dual-matched-position-duplicate-commit commit_message \
  "$TEST_TMP/pending-dual-matched-position-duplicate.txt"

TWO_STAGE_SOURCE_DIR=$TEST_TMP/two-stage-separator-sources
mkdir -p "$TWO_STAGE_SOURCE_DIR"
/usr/bin/perl -MUnicode::Normalize -MUnicode::UCD -CSDA -e '
  use strict;
  use warnings;
  use feature "fc";
  my ($policy,$output_dir,$manifest,$multi_manifest,$runtime)=@ARGV;
  open my $source,"<",$policy or exit 90;
  my (%direct,%direct_target,%map);
  my ($inside,$target)=(0,"");
  while (<$source>) {
    $inside=1,next if /my %keyword_skeleton_source_sets=\(/;
    last if $inside && /^  \);/;
    next unless $inside;
    $target=$1 if /^    "([apikeysctorn])" =>/;
    while (/"([0-9A-F ]+)"/g) {
      for my $hex (grep { length } split /\s+/,$1) {
        my $character=chr hex $hex;
        $direct{$character}=1;
        $direct_target{$character}=$target;
        $map{$character}=$target;
      }
    }
  }
  for my $character (keys %direct) {
    next unless $direct_target{$character} eq "o";
    my $decomposed=fc(NFKD($character));
    $decomposed =~ s/\p{M}//g;
    if ($decomposed eq "\x{03C3}" ||
        $decomposed eq "\x{03C2}") {
      $map{$character}="s";
    }
  }
  seek $source,0,0 or exit 91;
  $inside=0;
  while (<$source>) {
    $inside=1,next if /my %keyword_threat_specific_map=\(/;
    last if $inside && /^  \);/;
    next unless $inside;
    while (/"\\x\{([0-9A-F]+)\}"=>"([a-z])"/g) {
      $map{chr hex $1}=$2;
    }
  }
  close $source or exit 92;
  sub skeleton {
    my ($character)=@_;
    my $value=join "",map {
      exists $map{$_} ? $map{$_} : $_
    } split //,$character;
    $value=NFKD($value);
    $value =~ s/\p{M}//g;
    $value=join "",map {
      exists $map{$_} ? $map{$_} : $_
    } split //,fc($value);
    $value =~ s/[\p{Han}\p{Hiragana}\p{Katakana}]//g;
    return $value;
  }
  sub separator {
    my ($character)=@_;
    return 1 if $character eq "\x{2800}";
    return 1 if $character =~
      /[\p{White_Space}\p{P}\p{S}\p{Lm}]/;
    return $character =~
      /[\p{Han}\p{Hiragana}\p{Katakana}]/;
  }
  my %fold_map=(
    "\x{2044}"=>"/", "\x{2215}"=>"/", "\x{29F8}"=>"/",
    "\x{2216}"=>"\\", "\x{29F5}"=>"\\",
    "\x{2024}"=>".", "\x{3002}"=>".", "\x{FE52}"=>".",
    "\x{FE5F}"=>"#", "\x{FE6B}"=>"@", "\x{A789}"=>":",
    "\x{2010}"=>"-", "\x{2011}"=>"-", "\x{2012}"=>"-",
    "\x{2013}"=>"-", "\x{2014}"=>"-", "\x{2015}"=>"-",
    "\x{2212}"=>"-", "\x{FE63}"=>"-"
  );
  sub folded {
    my ($value)=@_;
    $value=NFKC($value);
    $value =~
      s/([\x{2044}\x{2215}\x{29F8}\x{2216}\x{29F5}\x{2024}\x{3002}\x{FE52}\x{FE5F}\x{FE6B}\x{A789}\x{2010}-\x{2015}\x{2212}\x{FE63}])/$fold_map{$1}/ge;
    return fc($value);
  }
  my %fixed=(
    a=>["","pikey"], p=>["a","ikey"], i=>["ap","key"],
    k=>["api","ey"], e=>["apik","y"], y=>["apike",""],
    s=>["","ecret"], c=>["se","ret"], r=>["sec","et"],
    t=>["secre",""], o=>["t","ken"], n=>["toke",""]
  );
  open my $manifest_out,">",$manifest or exit 93;
  open my $multi_out,">",$multi_manifest or exit 94;
  open my $runtime_out,">",$runtime or exit 95;
  print {$runtime_out}
    "perl=$] unicode=",Unicode::UCD::UnicodeVersion(),"\n" or exit 96;
  close $runtime_out or exit 97;
  for my $codepoint (0..0x10FFFF) {
    next if $codepoint >= 0xD800 && $codepoint <= 0xDFFF;
    my $character=chr $codepoint;
    next unless separator($character);
    my $mapped=skeleton($character);
    next unless length($mapped);
    my $hex=sprintf "%04X",$codepoint;
    if (length($mapped)>1 &&
        $mapped =~ /\A[apikeysctorn]+\z/) {
      print {$multi_out} "$hex $mapped\n" or exit 98;
    }
    next if exists $direct{$character};
    next unless $mapped =~ /\A([apikeysctorn])\z/;
    my $mapped_target=$1;
    my $keyword=
      $fixed{$mapped_target}[0] .
      $character .
      $fixed{$mapped_target}[1];
    my $folded=folded(
      "$keyword=ABCDEFGHIJKLMNOPQRSTUVWX"
    );
    next if $folded =~
      /(?:api[_-]?key|secret|token)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9_+\/=-]{16,}/i;
    print {$manifest_out} "$mapped_target $hex\n" or exit 99;
    open my $fixture,">:encoding(UTF-8)",
      "$output_dir/$mapped_target-$hex-match.txt" or exit 100;
    print {$fixture}
      "$keyword=ABCDEFGHIJKLMNOPQRSTUVWX\n" or exit 101;
    close $fixture or exit 102;
  }
  close $manifest_out or exit 103;
  close $multi_out or exit 104;
' "$POLICY" "$TWO_STAGE_SOURCE_DIR" \
  "$TEST_TMP/two-stage-source-manifest.txt" \
  "$TEST_TMP/multi-unit-source-manifest.txt" \
  "$TEST_TMP/two-stage-runtime.txt"

[ "$(/bin/cat "$TEST_TMP/two-stage-runtime.txt")" = \
  'perl=5.034001 unicode=13.0.0' ] ||
  fail "two-stage source derivation runtime changed"
/usr/bin/printf '%s\n' \
  'y 02E0' \
  'a 1D45' \
  'y 1D5E' \
  'y 1D67' \
  'p 1D68' \
  'n 1D78' \
  'i 1DA5' \
  'i 1DA6' \
  'o 3358' \
  's 1F12A' > "$TEST_TMP/two-stage-source.expected.txt"
/usr/bin/cmp -s \
  "$TEST_TMP/two-stage-source.expected.txt" \
  "$TEST_TMP/two-stage-source-manifest.txt" ||
  fail "two-stage separator source set changed"
/usr/bin/printf '%s\n' \
  '20A8 rs' \
  '2116 no' \
  '3250 pte' \
  '3376 pc' \
  '3380 pa' \
  '3381 na' \
  '3384 ka' \
  '33A9 pa' \
  '33AA kpa' \
  '33B0 ps' \
  '33B1 ns' \
  '33C4 cc' \
  '33CC in' \
  '33CD kk' \
  '33CF kt' \
  '33DA pr' \
  '33DB sr' \
  '1F14D ss' > "$TEST_TMP/multi-unit-source.expected.txt"
/usr/bin/cmp -s \
  "$TEST_TMP/multi-unit-source.expected.txt" \
  "$TEST_TMP/multi-unit-source-manifest.txt" ||
  fail "multi-unit separator skeleton set changed"

while IFS=' ' read -r two_stage_target two_stage_code; do
  two_stage_match=$TWO_STAGE_SOURCE_DIR/$two_stage_target-"$two_stage_code"-match.txt
  deny_text "two-stage-$two_stage_code-match" body \
    "$two_stage_match"
  deny_text "two-stage-$two_stage_code-match-commit" commit_message \
    "$two_stage_match"

  if [ "$two_stage_target" = e ]; then
    two_stage_off_keyword=token
  else
    two_stage_off_keyword=secret
  fi
  /usr/bin/perl -CSD -e '
    my ($hex,$keyword)=@ARGV;
    print substr($keyword,0,1),chr(hex $hex),
      substr($keyword,1),
      "=ABCDEFGHIJKLMNOPQRSTUVWX\n";
  ' "$two_stage_code" "$two_stage_off_keyword" \
    > "$TWO_STAGE_SOURCE_DIR/$two_stage_code-off.txt"
  deny_text "two-stage-$two_stage_code-off" body \
    "$TWO_STAGE_SOURCE_DIR/$two_stage_code-off.txt"
  deny_text "two-stage-$two_stage_code-off-commit" commit_message \
    "$TWO_STAGE_SOURCE_DIR/$two_stage_code-off.txt"

  /usr/bin/perl -CSD -e '
    my ($hex,$target)=@ARGV;
    my %fixed=(
      a=>["","pikey"], p=>["a","ikey"], i=>["ap","key"],
      k=>["api","ey"], e=>["apik","y"], y=>["apike",""],
      s=>["","ecret"], c=>["se","ret"], r=>["sec","et"],
      t=>["secre",""], o=>["t","ken"], n=>["toke",""]
    );
    print $fixed{$target}[0],chr(hex $hex),$target,
      $fixed{$target}[1],
      "=ABCDEFGHIJKLMNOPQRSTUVWX\n";
  ' "$two_stage_code" "$two_stage_target" \
    > "$TWO_STAGE_SOURCE_DIR/$two_stage_code-duplicate.txt"
  deny_text "two-stage-$two_stage_code-duplicate" body \
    "$TWO_STAGE_SOURCE_DIR/$two_stage_code-duplicate.txt"
  deny_text "two-stage-$two_stage_code-duplicate-commit" commit_message \
    "$TWO_STAGE_SOURCE_DIR/$two_stage_code-duplicate.txt"

  if [ "$two_stage_target" = o ]; then
    two_stage_pending_prefix=as
    two_stage_pending_suffix=ecret
  else
    two_stage_pending_prefix=at
    two_stage_pending_suffix=oken
  fi
  /usr/bin/perl -CSD -e '
    my ($hex,$prefix,$suffix)=@ARGV;
    print "token.\n$prefix:\n",chr(hex $hex),$suffix,
      ".ABCDEFGHIJKLMNOPQRSTUVWX\n";
  ' "$two_stage_code" "$two_stage_pending_prefix" \
    "$two_stage_pending_suffix" \
    > "$TWO_STAGE_SOURCE_DIR/$two_stage_code-pending-off.txt"
  deny_text "two-stage-$two_stage_code-pending-off" body \
    "$TWO_STAGE_SOURCE_DIR/$two_stage_code-pending-off.txt"
done < "$TEST_TMP/two-stage-source-manifest.txt"

/usr/bin/perl -CSD -e \
  'print "ap\x{1DA6}key=ABCDEFGHIJKLMNOPQRST"' \
  > "$TEST_TMP/two-stage-title.txt"
deny_text two-stage-title title "$TEST_TMP/two-stage-title.txt"
deny_text two-stage-comment comment \
  "$TWO_STAGE_SOURCE_DIR/i-1DA6-match.txt"
deny_perl_fixture two-stage-pending-duplicate \
  'print "token.\nap:\n\x{1DA6}ikey.ABCDEFGHIJKLMNOPQRSTUVWX\n"'
deny_text two-stage-pending-duplicate-commit commit_message \
  "$TEST_TMP/two-stage-pending-duplicate.txt"

/usr/bin/perl -CSD -e \
  'print "sec\x{20A8}et=ABCDEFGHIJKLMNOPQRSTUVWX\n"' \
  > "$TEST_TMP/multi-unit-rs-subset.txt"
pass_text multi-unit-rs-subset body \
  "$TEST_TMP/multi-unit-rs-subset.txt"
/usr/bin/perl -CSD -e \
  'print "t\x{2116}ken=ABCDEFGHIJKLMNOPQRSTUVWX\n"' \
  > "$TEST_TMP/multi-unit-no-subset.txt"
pass_text multi-unit-no-subset body \
  "$TEST_TMP/multi-unit-no-subset.txt"
deny_perl_fixture multi-unit-whole-skip \
  'print "sec\x{20A8}ret=ABCDEFGHIJKLMNOPQRSTUVWX\n"'
deny_perl_fixture multi-unit-whole-consume \
  'print "\x{20A8}ecret=ABCDEFGHIJKLMNOPQRSTUVWX\n"'
deny_perl_fixture multi-unit-completion-sticky \
  'print "toke\x{2116}=ABCDEFGHIJKLMNOPQRSTUVWX\n"'
deny_text multi-unit-completion-sticky-commit commit_message \
  "$TEST_TMP/multi-unit-completion-sticky.txt"
/usr/bin/perl -CSD -e \
  'print "token.\nxsec:\n\x{20A8}et=ABCDEFGHIJKLMNOPQRSTUVWX\n"' \
  > "$TEST_TMP/multi-unit-pending-subset.txt"
pass_text multi-unit-pending-subset body \
  "$TEST_TMP/multi-unit-pending-subset.txt"
deny_perl_fixture multi-unit-pending-whole-skip \
  'print "token.\nxsec:\n\x{20A8}ret.ABCDEFGHIJKLMNOPQRSTUVWX\n"'

for pending_keyword in secret apikey token; do
  pending_length=${#pending_keyword}
  pending_split=1
  while [ "$pending_split" -lt "$pending_length" ]; do
    pending_label=pending-split-"$pending_keyword"-"$pending_split"
    /usr/bin/perl -e '
      my ($keyword,$split)=@ARGV;
      print "token.\n",
        substr($keyword,0,$split), ":\n",
        substr($keyword,$split),
        ".ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n";
    ' "$pending_keyword" "$pending_split" > "$TEST_TMP/$pending_label.txt"
    deny_text "$pending_label" body "$TEST_TMP/$pending_label.txt"
    pending_split=$((pending_split + 1))
  done
done

# Closed assignment classes: mixed/non-ASCII LHS, Unicode spacing, and
# assignment-shaped punctuation after scanner-keyword evidence all deny.
deny_perl_fixture ascii-delimiter-hash \
  'print "api_key#ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture ascii-delimiter-comma \
  'print "api_key,ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture ascii-delimiter-semicolon \
  'print "api_key;ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture ascii-delimiter-quote \
  'print "api_key\"ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture ascii-delimiter-pipe \
  'print "api_key|ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture short-confusable-token \
  'print "t\x{043E}k\x{0435}n: ABCDEFGHIJKLMNOP1234\n"'
deny_perl_fixture mixed-script-value \
  'print "secret: \x{0391}\x{0392}\x{0393}\x{0394}\x{0395}\x{0396}\x{0397}\x{0398}\x{0399}abcdefg\n"'
deny_perl_fixture greek-confusable-token \
  'print "\x{03C4}\x{03BF}\x{03BA}\x{03B5}\x{03BD}=ABCDEFGHIJKLMNOP1234\n"'
deny_perl_fixture cyrillic-token-lowercase \
  'print "\x{0442}\x{043E}\x{043A}\x{0435}\x{043D}=WXYZWXYZWXYZWXYZ\n"'
deny_perl_fixture cyrillic-token-uppercase \
  'print "\x{0422}\x{041E}\x{041A}\x{0415}\x{041D}=WXYZWXYZWXYZWXYZ\n"'
deny_perl_fixture cyrillic-token-colon \
  'print "\x{0442}\x{043E}\x{043A}\x{0435}\x{043D}:WXYZWXYZWXYZWXYZ\n"'
deny_perl_fixture cyrillic-token-middle-dot \
  'print "\x{0442}\x{043E}\x{043A}\x{0435}\x{043D}\x{00B7}WXYZWXYZWXYZWXYZ\n"'
deny_perl_fixture japanese-label-cyrillic-token \
  'print "\x{8AAC}\x{660E}:\n\x{0442}\x{043E}\x{043A}\x{0435}\x{043D}=WXYZWXYZWXYZWXYZ\n"'
deny_perl_fixture cyrillic-confusable-api-key \
  'print "\x{0430}\x{0440}\x{0456}_\x{043A}\x{0435}\x{0443}=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture middle-dot-token \
  'print "token\x{00B7}ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture middle-dot-api-key \
  'print "api_key\x{00B7}ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture japanese-inserted-api-key \
  'print "api_key\x{8AAC}\x{660E}=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture cross-script-confusable-token \
  'print "\x{03C4}\x{043E}\x{03BA}\x{03B5}\x{03BD}:ABCDEFGHIJKLMNOP\n"'
deny_perl_fixture cross-script-confusable-api-key \
  'print "\x{0430}\x{03C1}\x{0456}_\x{043A}\x{0435}\x{0443}=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture greek-confusable-api-key \
  'print "\x{03B1}\x{03C1}\x{03B9}_\x{03BA}\x{03B5}\x{03B3}=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture identifier-padding-api-key \
  'print "api_keyx=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture identifier-padding-secret \
  'print "secretZZ=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture identifier-padding-token \
  'print "tokenNOISE=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture identifier-padding-digits \
  'print "api_key000=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture repeated-underscore-api-key \
  'print "api__key=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture repeated-hyphen-api-key \
  'print "api---key=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture trailing-separator-api-key \
  'print "api_key_=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture soft-split-lf-api-key \
  'print "api_\nkey=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture soft-split-nbsp-api-key \
  'print "api\x{00A0}key=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture soft-split-ideographic-api-key \
  'print "api\x{3000}key=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture soft-split-braille-api-key \
  'print "api\x{2800}key=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture soft-split-comma-api-key \
  'print "api,key=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture soft-split-slash-api-key \
  'print "api/key=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture soft-split-middle-dot-api-key \
  'print "api\x{00B7}key=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture soft-split-lf-secret \
  'print "sec\nret=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture soft-split-lf-token \
  'print "tok\nen=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture soft-split-greek-token \
  'print "\x{03C4}\x{03BF}\n\x{03BA}\x{03B5}\x{03BD}=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture soft-split-cyrillic-secret \
  'print "\x{0455}\x{0435}\x{0441}\n\x{0433}\x{0435}\x{0442}=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture soft-split-cyrillic-api-key \
  'print "\x{0430}\x{0440}\x{0456}_\n\x{043A}\x{0435}\x{0443}=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture cyrillic-ukrainian-ie-secret \
  'print "\x{0455}\x{0454}\x{0441}\x{0433}\x{0454}\x{0442}=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture cyrillic-abkhasian-che-secret \
  'print "\x{0455}\x{04BD}\x{0441}\x{0433}\x{04BD}\x{0442}=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture soft-split-trademark-api-key \
  'print "api\x{2122}key=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture soft-split-euro-api-key \
  'print "api\x{20AC}key=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture soft-split-trademark-secret \
  'print "sec\x{2122}ret=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture soft-split-degree-token \
  'print "tok\x{00B0}en=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture soft-split-degree-greek-token \
  'print "\x{03C4}\x{03BF}\x{00B0}\x{03BA}\x{03B5}\x{03BD}=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture soft-split-symbol-abkhasian-che-secret \
  'print "\x{0455}\x{04BD}\x{0441}\x{2122}\x{0433}\x{04BD}\x{0442}=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture symbol-padding-blank-line-compound \
  'print "api\x{2122}keyNOISE\n\n=\n\nABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture post-completion-trademark-secret \
  'print "secret\x{2122}ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture accented-greek-token \
  'print "\x{03C4}\x{03CC}\x{03BA}\x{03B5}\x{03BD}=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture accented-cyrillic-secret \
  'print "\x{0455}\x{0451}\x{0441}\x{0433}\x{0451}\x{0442}=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture accented-greek-api-key \
  'print "\x{03AC}\x{03C1}\x{03AF}_\x{03BA}\x{03B5}\x{03B3}=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture period-dotted-api-key \
  'print "api_key.value=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture period-dotted-secret \
  'print "secret.x=ABCDEFGHIJKLMNOP\n"'
deny_perl_fixture period-dotted-api-short \
  'print "api_key.q=ABCDEFGHIJKLMNOP\n"'
deny_perl_fixture period-spaced-token \
  'print "token. z=ABCDEFGHIJKLMNOP\n"'
deny_perl_fixture period-direct-candidate \
  'print "token. ABCDEFGHIJKLMNOP\n"'
deny_perl_fixture period-line-equals \
  'print "token.\nAB=ABCDEFGHIJKLMNOP\n"'
deny_perl_fixture period-ideographic-secret \
  'print "secret\x{3002}x=ABCDEFGHIJKLMNOP\n"'
deny_perl_fixture period-one-dot-leader-secret \
  'print "secret\x{2024}x=ABCDEFGHIJKLMNOP\n"'
deny_perl_fixture period-confusable-secret \
  'print "s\x{0435}cret.x=ABCDEFGHIJKLMNOP\n"'
deny_perl_fixture period-symbol-secret \
  'print "sec\x{2122}ret.x=ABCDEFGHIJKLMNOP\n"'
deny_perl_fixture period-japanese-token \
  'print "token\x{3002}\x{8AAC}\x{660E}\x{FF1A}ABCDEFGHIJKLMNOP\n"'
deny_perl_fixture period-second-secret \
  'print "token.\nsecret.ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture period-second-api-key \
  'print "token.\napi_key.ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture period-second-token \
  'print "token.\ntoken.ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture pending-compat-colon-secret \
  'print "token.\nsec\x{A789}\nret.ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture pending-fullwidth-colon-api-key \
  'print "token.\napi\x{FF1A}\nkey.ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture pending-confusable-secret \
  'print "token.\ns\x{0435}c:\nret.ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture pending-soft-symbol-secret \
  'print "token.\nsec:\n\x{2122}\nret.ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture pending-equals-secret \
  'print "token.\nsec:\nret=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture pending-direct-secret \
  'print "token.\nsec:\nretABCDEFGHIJKLMNOP\n"'
deny_perl_fixture pending-suffix-period-secret \
  'print "token.\nsec:\nretZZ.ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture pending-blank-value-secret \
  'print "token.\nsec:\nret\n\nABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture pending-multiple-separators-secret \
  'print "token.\nsec:\n\n\x{2122}\n\x{3000}\n\x{00A0}\nret.ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture unicode-period-pending-secret \
  'print "token\x{3002}\nsec:\nret.ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture period-second-confusable-secret \
  'print "token.\ns\x{0435}cret.ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture period-second-split-secret \
  'print "token.\nsec\nret.ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture period-second-soft-secret \
  'print "token.\nsec\x{2122}ret.ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture period-second-suffix-secret \
  'print "token.\nsecretZZ.ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture period-second-ideographic-secret \
  'print "token.\nsecret\x{3002}ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture period-second-one-dot-leader-secret \
  'print "token.\nsecret\x{2024}ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture period-second-direct-candidate \
  'print "token.\nsecretABCDEFGHIJKLMNOP\n"'
deny_perl_fixture period-second-letter-equals \
  'print "token.\nsecret.q=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture period-second-multiple-whitespace \
  'print "token.\n\n\x{3000}\n\x{00A0}\n\nsecret.ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture unicode-period-second-secret \
  'print "token\x{3002}\nsecret.ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture period-second-symbol-blank-compound \
  'print "token.\nsec\x{2122}retZZ\x{3002}\n\nABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture suffix-period-secret \
  'print "secretZZ.ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture suffix-period-token \
  'print "tokenNOISE.ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture suffix-period-api-key \
  'print "api_keyx.ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture suffix-period-one-character \
  'print "secretZ.ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture suffix-period-digit \
  'print "token1.ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture suffix-period-underscore \
  'print "api_key_.ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture suffix-period-hyphen \
  'print "api_key-.ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture suffix-period-connector \
  'print "secret\x{203F}.ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture suffix-period-combining-mark \
  'print "secret\x{0301}.ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture suffix-ideographic-period \
  'print "secretZZ\x{3002}ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture suffix-one-dot-leader \
  'print "tokenNOISE\x{2024}ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture suffix-confusable-period \
  'print "s\x{0435}cretZZ.ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture suffix-period-letter-equals \
  'print "secretZZ.q=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture suffix-period-symbol-blank \
  'print "tokenNOISE.\x{2122}\n\nABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture suffix-period-newline-equals \
  'print "api_keyx.\n\n=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture sigma-secret \
  'print "\x{03C3}\x{03B5}\x{0441}\x{0433}\x{03B5}\x{03C4}=ABCDEFGHIJKLMNOP\n"'
deny_perl_fixture final-sigma-secret \
  'print "\x{03C2}\x{03B5}\x{0441}\x{0433}\x{03B5}\x{03C4}=ABCDEFGHIJKLMNOP\n"'
deny_perl_fixture math-sigma-u1d6d4-secret \
  'print "\x{1D6D4}\x{0435}\x{0441}\x{0433}\x{0435}\x{0442}=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture math-sigma-u1d70e-secret \
  'print "\x{1D70E}\x{0435}\x{0441}\x{0433}\x{0435}\x{0442}=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture math-sigma-u1d748-secret \
  'print "\x{1D748}\x{0435}\x{0441}\x{0433}\x{0435}\x{0442}=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture math-sigma-u1d782-secret \
  'print "\x{1D782}\x{0435}\x{0441}\x{0433}\x{0435}\x{0442}=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture math-sigma-u1d7bc-secret \
  'print "\x{1D7BC}\x{0435}\x{0441}\x{0433}\x{0435}\x{0442}=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture math-sigma-soft-blank-compound \
  'print "\x{1D6D4}\x{2122}\x{0435}\x{0441}\x{0433}\x{0435}\x{0442}NOISE\n\n\x{FF1A}\n\nABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture lunate-sigma-secret \
  'print "\x{0455}\x{03B5}\x{03F2}\x{0433}\x{03B5}\x{03C4}=ABCDEFGHIJKLMNOP\n"'
deny_perl_fixture small-capital-y-api-key \
  'print "\x{03B1}\x{03C1}\x{03B9}\x{03BA}\x{03B5}\x{028F}=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture coptic-sima-secret \
  'print "\x{0455}\x{0454}\x{2CA5}\x{0433}\x{0454}\x{0442}=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture generated-api-key \
  'print "\x{0251}\x{00FE}\x{026A}\x{0138}\x{212F}\x{028F}=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture generated-secret \
  'print "\x{01BD}\x{AB32}\x{1D04}\x{AB47}\x{AB32}\x{13A2}=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture generated-token \
  'print "\x{1D42D}\x{1D428}\x{1D424}\x{1D41E}\x{1D427}=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture generated-symbol-padding-compound \
  'print "\x{03C3}\x{03B5}\x{2122}\x{0441}\x{0433}\x{03B5}\x{03C4}NOISE\n\n\x{FF1A}\n\nABCDEFGHIJKLMNOP\n"'

# Derive every direct UTS "o" source whose fixed-key decomposition is sigma,
# then prove that each discovered row takes the threat-specific "s" path.
mkdir -p "$TEST_TMP/sigma-derived-invariant"
/usr/bin/perl -MUnicode::Normalize -CSDA -e '
  use strict;
  use warnings;
  use feature "fc";
  my ($policy,$output_dir)=@ARGV;
  open my $source,"<",$policy or exit 90;
  my ($inside,$target)=(0,"");
  while (<$source>) {
    $inside=1,next if /my %keyword_skeleton_source_sets=\(/;
    last if $inside && /^  \);/;
    next unless $inside;
    $target=$1 if /^    "([apikeysctorn])" =>/;
    while (/"([0-9A-F ]+)"/g) {
      for my $hex (grep { length } split /\s+/,$1) {
        next unless $target eq "o";
        my $character=chr hex $hex;
        my $decomposed=fc(NFKD($character));
        $decomposed =~ s/\p{M}//g;
        next unless $decomposed eq "\x{03C3}" ||
          $decomposed eq "\x{03C2}";
        open my $fixture,">:encoding(UTF-8)","$output_dir/$hex.txt" or exit 91;
        print {$fixture}
          $character,
          "\x{0435}\x{0441}\x{0433}\x{0435}\x{0442}",
          "=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n" or exit 92;
        close $fixture or exit 93;
        print "$hex\n";
      }
    }
  }
  close $source or exit 94;
' "$POLICY" "$TEST_TMP/sigma-derived-invariant" \
  > "$TEST_TMP/sigma-derived-codes.txt"
[ "$(/usr/bin/wc -l < "$TEST_TMP/sigma-derived-codes.txt" |
  /usr/bin/tr -d ' ')" -eq 6 ] ||
  fail "embedded sigma-derived source invariant changed unexpectedly"
for sigma_code in 03C3 1D6D4 1D70E 1D748 1D782 1D7BC; do
  /usr/bin/grep -Fx "$sigma_code" \
    "$TEST_TMP/sigma-derived-codes.txt" >/dev/null ||
    fail "embedded sigma-derived source invariant omitted $sigma_code"
done
while IFS= read -r sigma_code; do
  deny_text "sigma-derived-$sigma_code" body \
    "$TEST_TMP/sigma-derived-invariant/$sigma_code.txt"
  deny_text "sigma-derived-$sigma_code-commit" commit_message \
    "$TEST_TMP/sigma-derived-invariant/$sigma_code.txt"
  /usr/bin/perl -CSD -e '
    my ($hex)=@ARGV;
    print "t",chr(hex $hex),"ken=ABCDEFGHIJKLMNOPQRSTUVWX\n";
  ' "$sigma_code" \
    > "$TEST_TMP/sigma-derived-invariant/$sigma_code-token.txt"
  deny_text "sigma-token-derived-$sigma_code" body \
    "$TEST_TMP/sigma-derived-invariant/$sigma_code-token.txt"
  deny_text "sigma-token-derived-$sigma_code-commit" commit_message \
    "$TEST_TMP/sigma-derived-invariant/$sigma_code-token.txt"
done < "$TEST_TMP/sigma-derived-codes.txt"

/usr/bin/perl -CSD -e \
  'print "secret\x{2122}ABCDEFGHIJKLMNOPQRSTUVWXYZ123456"' \
  > "$TEST_TMP/post-completion-trademark-title.txt"
deny_text post-completion-trademark-title title \
  "$TEST_TMP/post-completion-trademark-title.txt"
/usr/bin/perl -CSD -e \
  'print "api_key.value=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456"' \
  > "$TEST_TMP/period-dotted-api-key-title.txt"
deny_text period-dotted-api-key-title title \
  "$TEST_TMP/period-dotted-api-key-title.txt"
/usr/bin/perl -CSD -e \
  'print "secret\x{3002}x=ABCDEFGHIJKLMNOP"' \
  > "$TEST_TMP/period-ideographic-secret-title.txt"
deny_text period-ideographic-secret-title title \
  "$TEST_TMP/period-ideographic-secret-title.txt"
/usr/bin/perl -CSD -e \
  'print "sec\x{2122}ret\x{2024}x=ABCDEFGHIJKLMNOP"' \
  > "$TEST_TMP/period-symbol-confusable-title.txt"
deny_text period-symbol-confusable-title title \
  "$TEST_TMP/period-symbol-confusable-title.txt"
deny_perl_fixture cyrillic-a-key \
  'print "\x{0430}pi_key=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture cyrillic-e-secret \
  'print "s\x{0435}cret=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture cyrillic-o-token \
  'print "t\x{043E}ken=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture mixed-script-lambda-key \
  'print "api_\x{03BB}ey=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture ideographic-space-assignment \
  'print "api_key\x{3000}=\x{3000}ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture nbsp-assignment \
  'print "api_key\x{00A0}=\x{00A0}ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture em-space-assignment \
  'print "api_key\x{2003}=\x{2003}ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture ratio-delimiter \
  'print "api_key\x{2236}ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture triangular-colon-delimiter \
  'print "api_key\x{02D0}ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture short-equals-delimiter \
  'print "api_key\x{A78A}ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture cross-line-assignment \
  'print "api_key=\nABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture compound-cyrillic-ratio \
  'print "\x{0430}pi_key\x{2236}ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture compound-mixed-unicode-space \
  'print "s\x{0435}cret\x{00A0}=\x{2003}ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture compound-mixed-cross-line \
  'print "t\x{043E}ken=\nABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture compound-delimiter-mixed-value \
  'print "api_key\x{2236}ABCDEFGH\x{0391}IJKLMNOPQRSTUV\n"'
deny_perl_fixture blank-line-cyrillic-secret \
  'print "s\x{0435}cret=\n\nABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture blank-line-cyrillic-ratio \
  'print "\x{0430}pi_key\x{2236}\n\nABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture multi-whitespace-lines-compound \
  'print "\x{0430}pi_key\x{00A0}\x{2236}\x{2003}\n\n\x{3000}\n\x{00A0}\x{2003}\nABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture padding-api-79 \
  'print "api_key=", "." x 79, "ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture padding-api-80 \
  'print "api_key=", "." x 80, "ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture padding-api-81 \
  'print "api_key=", "." x 81, "ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture padding-secret-80 \
  'print "secret=", "." x 80, "ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture padding-cyrillic-secret-80 \
  'print "s\x{0435}cret=", "." x 80, "ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture padding-cyrillic-ratio-80 \
  'print "\x{0430}pi_key\x{2236}", "." x 80, "ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture leading-hash-candidate \
  'print "api_key=\n\n#ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture leading-quote-candidate \
  'print "api_key=\n\n\"ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\"\n"'
deny_perl_fixture leading-short-word-candidate \
  'print "api_key=\n\nval ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture leading-junk-confusable-secret \
  'print "s\x{0435}cret=\n\nval #\"ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\"\n"'
deny_perl_fixture intervening-note \
  'print "api_key=\n\nnote\n\nABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture intervening-note-confusable-ratio \
  'print "\x{0430}pi_key\x{2236}\n\nnote\n\nABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture linear-long-filler \
  'print "api_key=", "." x 30000, "ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture split-identifier-ascii \
  'print "api_key\n= ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture split-identifier-confusable \
  'print "s\x{0435}cret\n= ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture split-identifier-confusable-value-line \
  'print "s\x{0435}cret\n=\nABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture split-identifier-ratio \
  'print "api_key\n\x{2236}ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture split-identifier-confusable-ratio-whitespace \
  'print "s\x{0435}cret\n\x{3000}\n\x{00A0}\x{2003}\n\x{2236}\n#ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture pre-delimiter-padding-api-79 \
  'print "api_key", "." x 79, "=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture pre-delimiter-padding-api-80 \
  'print "api_key", "." x 80, "=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture pre-delimiter-padding-api-81 \
  'print "api_key", "." x 81, "=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture pre-delimiter-padding-confusable-80 \
  'print "s\x{0435}cret", "." x 80, "=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture pre-delimiter-padding-ratio-80 \
  'print "api_key", "." x 80, "\x{2236}ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture pre-delimiter-unicode-filler \
  'print "s\x{0435}cret", "\x{3000}" x 80, "\x{2236}ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'
deny_perl_fixture pre-delimiter-linear-long-filler \
  'print "api_key", "." x 30000, "=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n"'

/usr/bin/printf '\377invalid\n' > "$TEST_TMP/invalid-utf8.txt"
deny_text invalid-utf8 body "$TEST_TMP/invalid-utf8.txt"
/usr/bin/printf 'nul\000byte\n' > "$TEST_TMP/nul.txt"
deny_text nul body "$TEST_TMP/nul.txt"
/usr/bin/printf '\357\273\277bom\n' > "$TEST_TMP/bom.txt"
deny_text bom body "$TEST_TMP/bom.txt"
/usr/bin/printf 'crlf\r\n' > "$TEST_TMP/crlf.txt"
deny_text crlf body "$TEST_TMP/crlf.txt"
/usr/bin/printf 'control\001byte\n' > "$TEST_TMP/control.txt"
deny_text control body "$TEST_TMP/control.txt"
/usr/bin/printf 'e\314\201\n' > "$TEST_TMP/non-nfc.txt"
deny_text non-nfc body "$TEST_TMP/non-nfc.txt"
: > "$TEST_TMP/empty.txt"
deny_text empty-body body "$TEST_TMP/empty.txt"
deny_text empty-title title "$TEST_TMP/empty.txt"
/usr/bin/printf 'first\nsecond' > "$TEST_TMP/multiline-title.txt"
deny_text multiline-title title "$TEST_TMP/multiline-title.txt"
/usr/bin/printf 'missing terminal LF' > "$TEST_TMP/no-terminal-lf.txt"
deny_text no-terminal-lf body "$TEST_TMP/no-terminal-lf.txt"
/usr/bin/printf 'extra terminal LF\n\n' > "$TEST_TMP/double-terminal-lf.txt"
deny_text double-terminal-lf body "$TEST_TMP/double-terminal-lf.txt"
/usr/bin/perl -e 'print "x" x 513' > "$TEST_TMP/oversize-title.txt"
deny_text oversize title "$TEST_TMP/oversize-title.txt"

CF_SOURCE_DIR=$TEST_TMP/cf-structural-sources
mkdir -p "$CF_SOURCE_DIR"
/usr/bin/perl -MUnicode::UCD -CSDA -e '
  use strict;
  use warnings;
  my ($output_dir,$all_manifest,$survivor_manifest,$runtime)=@ARGV;
  open my $all_out,">",$all_manifest or exit 90;
  open my $survivor_out,">",$survivor_manifest or exit 91;
  my ($all_count,$survivor_count)=(0,0);
  for my $codepoint (0..0x10FFFF) {
    next if $codepoint >= 0xD800 && $codepoint <= 0xDFFF;
    my $character=chr $codepoint;
    next unless $character =~ /\p{Cf}/;
    my $hex=sprintf "%04X",$codepoint;
    $all_count++;
    print {$all_out} "$hex\n" or exit 92;
    open my $fixture,">:encoding(UTF-8)",
      "$output_dir/$hex.txt" or exit 93;
    print {$fixture}
      "api",$character,"key=ZqWrTsPvXyZqWrTsPvXy\n" or exit 94;
    close $fixture or exit 95;
    next if $character eq "\x{FEFF}";
    next if $character =~
      /[\x{FDD0}-\x{FDEF}\p{Noncharacter_Code_Point}\p{Bidi_Control}\p{Default_Ignorable_Code_Point}\p{Cn}]/;
    $survivor_count++;
    print {$survivor_out} "$hex\n" or exit 96;
  }
  close $all_out or exit 97;
  close $survivor_out or exit 98;
  open my $runtime_out,">",$runtime or exit 99;
  print {$runtime_out}
    "perl=$] unicode=",Unicode::UCD::UnicodeVersion(),
    " all_cf=$all_count pre_round21_survivors=$survivor_count\n" or exit 100;
  close $runtime_out or exit 101;
' "$CF_SOURCE_DIR" \
  "$TEST_TMP/cf-all-manifest.txt" \
  "$TEST_TMP/cf-pre-round21-survivors.txt" \
  "$TEST_TMP/cf-runtime.txt"

[ "$(/bin/cat "$TEST_TMP/cf-runtime.txt")" = \
  'perl=5.034001 unicode=13.0.0 all_cf=161 pre_round21_survivors=23' ] ||
  fail "Cf structural derivation runtime or cardinality changed"
/usr/bin/printf '%s\n' \
  0600 0601 0602 0603 0604 0605 06DD 070F 08E2 \
  FFF9 FFFA FFFB 110BD 110CD \
  13430 13431 13432 13433 13434 13435 13436 13437 13438 \
  > "$TEST_TMP/cf-pre-round21-survivors.expected.txt"
/usr/bin/cmp -s \
  "$TEST_TMP/cf-pre-round21-survivors.expected.txt" \
  "$TEST_TMP/cf-pre-round21-survivors.txt" ||
  fail "pre-round-21 Cf survivor set changed"

cf_postfix_survivors=0
while IFS= read -r cf_code; do
  if "$POLICY" --kind body --input "$CF_SOURCE_DIR/$cf_code.txt" \
    > "$TEST_TMP/cf-all-$cf_code.out" 2>&1; then
    cf_postfix_survivors=$((cf_postfix_survivors + 1))
  else
    assert_contains 'LOCAL_ONLY_REMOTE_UNPROVEN' \
      "$TEST_TMP/cf-all-$cf_code.out"
  fi
done < "$TEST_TMP/cf-all-manifest.txt"
[ "$cf_postfix_survivors" -eq 0 ] ||
  fail "a Unicode Cf character survived the corrected structural predicate"

while IFS= read -r cf_code; do
  deny_text "cf-$cf_code-commit" commit_message \
    "$CF_SOURCE_DIR/$cf_code.txt"
done < "$TEST_TMP/cf-pre-round21-survivors.txt"

/usr/bin/perl -CSD -e \
  'print "api\x{070F}key=ZqWrTsPvXyZqWrTsPvXy"' \
  > "$TEST_TMP/cf-exact-title.txt"
deny_text cf-exact-title title "$TEST_TMP/cf-exact-title.txt"
/usr/bin/perl -CSD -e \
  'print "Ordinary\x{070F}Title"' \
  > "$TEST_TMP/cf-structural-title.txt"
deny_text cf-structural-title title \
  "$TEST_TMP/cf-structural-title.txt"
deny_text cf-exact-comment comment "$CF_SOURCE_DIR/070F.txt"

CO_SOURCE_DIR=$TEST_TMP/co-structural-sources
mkdir -p "$CO_SOURCE_DIR"
[ "$(/usr/bin/grep -F -c \
  '\p{Default_Ignorable_Code_Point}\p{Cf}\p{Co}\p{Cn}' "$POLICY")" -eq 1 ] ||
  fail "production structural predicate does not reject Unicode Co"
/usr/bin/perl -MUnicode::UCD -CSDA -e '
  use strict;
  use warnings;
  my ($ranges_path,$runtime_path)=@ARGV;
  my ($count,$postfix_survivors,$range_start,$previous)=(0,0);
  my @ranges;
  for my $codepoint (0..0x10FFFF) {
    next if $codepoint >= 0xD800 && $codepoint <= 0xDFFF;
    my $character=chr $codepoint;
    next unless $character =~ /\p{Co}/;
    $count++;
    $postfix_survivors++ unless $character =~
      /[\x{FEFF}\x{0000}-\x{0009}\x{000B}-\x{001F}\x{007F}-\x{009F}\x{2028}\x{2029}\x{FDD0}-\x{FDEF}\p{Noncharacter_Code_Point}\p{Bidi_Control}\p{Default_Ignorable_Code_Point}\p{Cf}\p{Co}\p{Cn}]/;
    if (!defined $range_start) {
      ($range_start,$previous)=($codepoint,$codepoint);
    } elsif ($codepoint == $previous+1) {
      $previous=$codepoint;
    } else {
      push @ranges,[$range_start,$previous];
      ($range_start,$previous)=($codepoint,$codepoint);
    }
  }
  push @ranges,[$range_start,$previous] if defined $range_start;
  open my $ranges_out,">",$ranges_path or exit 90;
  for my $range (@ranges) {
    printf {$ranges_out} "%X-%X\n",$range->[0],$range->[1] or exit 91;
  }
  close $ranges_out or exit 92;
  open my $runtime_out,">",$runtime_path or exit 93;
  print {$runtime_out}
    "perl=$] unicode=",Unicode::UCD::UnicodeVersion(),
    " all_co=$count ranges=",scalar(@ranges),
    " post_fix_survivors=$postfix_survivors\n" or exit 94;
  close $runtime_out or exit 95;
' "$TEST_TMP/co-ranges.txt" "$TEST_TMP/co-runtime.txt"

[ "$(/bin/cat "$TEST_TMP/co-runtime.txt")" = \
  'perl=5.034001 unicode=13.0.0 all_co=137468 ranges=3 post_fix_survivors=0' ] ||
  fail "Co structural derivation runtime, cardinality, or survivor count changed"
/usr/bin/printf '%s\n' \
  E000-F8FF F0000-FFFFD 100000-10FFFD \
  > "$TEST_TMP/co-ranges.expected.txt"
/usr/bin/cmp -s \
  "$TEST_TMP/co-ranges.expected.txt" \
  "$TEST_TMP/co-ranges.txt" ||
  fail "Unicode Co contiguous ranges changed"

/usr/bin/printf '%s\n' \
  E000 EC80 F8FF \
  F0000 F7FFF FFFFD \
  100000 107FFF 10FFFD \
  > "$TEST_TMP/co-representatives.txt"
while IFS= read -r co_code; do
  /usr/bin/perl -CSDA -e '
    use strict;
    use warnings;
    my ($code,$path)=@ARGV;
    open my $fixture,">:encoding(UTF-8)",$path or exit 90;
    print {$fixture}
      "api",chr(hex($code)),"key=ZqWrTsPvXyZqWrTsPvXy\n" or exit 91;
    close $fixture or exit 92;
  ' "$co_code" "$CO_SOURCE_DIR/$co_code.txt"
  deny_text "co-$co_code-body" body "$CO_SOURCE_DIR/$co_code.txt"
  deny_text "co-$co_code-commit" commit_message \
    "$CO_SOURCE_DIR/$co_code.txt"
done < "$TEST_TMP/co-representatives.txt"

/usr/bin/perl -CSD -e \
  'print "api\x{E000}key=ZqWrTsPvXyZqWrTsPvXy"' \
  > "$TEST_TMP/co-exact-title.txt"
deny_text co-exact-title title "$TEST_TMP/co-exact-title.txt"
/usr/bin/perl -CSD -e \
  'print "Ordinary\x{E000}Title"' \
  > "$TEST_TMP/co-structural-title.txt"
deny_text co-structural-title title "$TEST_TMP/co-structural-title.txt"
deny_text co-exact-comment comment "$CO_SOURCE_DIR/E000.txt"

if "$POLICY" --kind title --input relative.txt >/dev/null 2>&1; then
  fail "relative text input was accepted"
fi
if "$POLICY" --kind unknown --input "$TEST_TMP/title.txt" >/dev/null 2>&1; then
  fail "unknown text kind was accepted"
fi
if "$POLICY" --kind title >/dev/null 2>&1; then
  fail "missing text input was accepted"
fi
if "$POLICY" --input "$TEST_TMP/title.txt" >/dev/null 2>&1; then
  fail "missing text kind was accepted"
fi
if "$POLICY" --kind title --kind body --input "$TEST_TMP/title.txt" \
  >/dev/null 2>&1; then
  fail "duplicate text kind was accepted"
fi
if "$POLICY" --kind title --input "$TEST_TMP/title.txt" \
  --input "$TEST_TMP/title.txt" >/dev/null 2>&1; then
  fail "duplicate text input was accepted"
fi
if "$POLICY" --kind title --input "$TEST_TMP/title.txt" \
  --repo sample/repo >/dev/null 2>&1; then
  fail "unknown text-policy field was accepted"
fi
if "$POLICY" --kind title --input "$TEST_TMP/../$(basename "$TEST_TMP")/title.txt" \
  >/dev/null 2>&1; then
  fail "noncanonical text input was accepted"
fi
/bin/ln -s "$TEST_TMP/title.txt" "$TEST_TMP/title-symlink.txt"
if "$POLICY" --kind title --input "$TEST_TMP/title-symlink.txt" >/dev/null 2>&1; then
  fail "symlinked text input was accepted"
fi
/bin/ln "$TEST_TMP/title.txt" "$TEST_TMP/title-hardlink.txt"
if "$POLICY" --kind title --input "$TEST_TMP/title.txt" >/dev/null 2>&1; then
  fail "hard-link-aliased text input was accepted"
fi
if "$POLICY" --kind title --input "$TEST_TMP" >/dev/null 2>&1; then
  fail "non-regular text input was accepted"
fi
/usr/bin/perl -e 'unlink $ARGV[0] or die $!' "$TEST_TMP/title-hardlink.txt"

generic_secret='api_key=ABCDEFGHIJKLMNOPQRSTUVWXYZ123456'
/usr/bin/printf '%s\n' "$generic_secret" > "$TEST_TMP/generic-secret.txt"
deny_text generic-secret body "$TEST_TMP/generic-secret.txt"
assert_not_contains "$generic_secret" "$TEST_TMP/generic-secret.out"
github_secret='ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ123456'
/usr/bin/printf '%s\n' "$github_secret" > "$TEST_TMP/github-secret.txt"
deny_text github-secret body "$TEST_TMP/github-secret.txt"
assert_not_contains "$github_secret" "$TEST_TMP/github-secret.out"

# The exact-stdin runner is shared by object and text scanning. Exercise forged
# stdout/report/exit/count paths against an isolated copy with a fixed fake tool.
FAKE_GUARD=$TEST_TMP/fake-guard
mkdir -p "$FAKE_GUARD"
/bin/cp "$ROOT/guard/common.sh" "$FAKE_GUARD/common.sh"
FAKE_GITLEAKS=$TEST_TMP/fake-gitleaks
/usr/bin/printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'if [ "${1-}" = version ]; then printf "%s\n" "8.30.1"; exit 0; fi' \
  'report=' \
  'for arg in "$@"; do case "$arg" in --report-path=*) report=${arg#*=} ;; esac; done' \
  '[ -n "$report" ] || exit 90' \
  'payload=$report.input' \
  '/bin/cat > "$payload"' \
  'bytes=$(/usr/bin/wc -c < "$payload" | /usr/bin/tr -d " ")' \
  'mode=${FAKE_GITLEAKS_MODE:-clean}' \
  'is_canary=false' \
  'if /usr/bin/grep -F "api_key=NSCANEXACTSTDINPHASEONE" "$payload" >/dev/null 2>&1; then is_canary=true; fi' \
  'case "$mode" in' \
  '  clean|canary-missing|misleading-count|duplicate-count|missing-count)' \
  '    if [ "$is_canary" = true ]; then' \
  '      if [ "$mode" = canary-missing ]; then' \
  '        /usr/bin/printf "%s\n" "[]" > "$report"' \
  '      else' \
  '        /usr/bin/printf "%s\n" "[{\"RuleID\":\"nightshift-generic-api-key\"}]" > "$report"' \
  '      fi' \
  '    else' \
  '      /usr/bin/printf "%s\n" "[]" > "$report"' \
  '    fi' \
  '    ;;' \
  '  stdout) /usr/bin/printf "%s\n" "[]"> "$report"; printf "%s\n" forged ;;' \
  '  malformed) /usr/bin/printf "%s\n" "{}" > "$report" ;;' \
  '  finding) /usr/bin/printf "%s\n" "[{\"RuleID\":\"forged\"}]" > "$report" ;;' \
  '  missing-report) : ;;' \
  '  exit) /usr/bin/printf "%s\n" "[]" > "$report" ;;' \
  '  short) /usr/bin/printf "%s\n" "[]" > "$report" ;;' \
  '  *) exit 91 ;;' \
  'esac' \
  'if [ "$mode" = short ]; then' \
  '  printf "%s\n" "level=debug scanned ~1 bytes (1 bytes)" >&2' \
  'elif [ "$mode" = misleading-count ]; then' \
  '  printf "level=debug scanned ~%s0 bytes (%s bytes)\n" "$bytes" "$bytes" >&2' \
  'elif [ "$mode" = duplicate-count ]; then' \
  '  printf "level=debug scanned ~%s bytes (%s bytes)\n" "$bytes" "$bytes" >&2' \
  '  printf "level=debug scanned ~%s bytes (%s bytes)\n" "$bytes" "$bytes" >&2' \
  'elif [ "$mode" = missing-count ]; then' \
  '  printf "%s\n" "level=debug completed scan" >&2' \
  'else' \
  '  printf "level=debug scanned ~%s bytes (%s bytes)\n" "$bytes" "$bytes" >&2' \
  'fi' \
  '[ "$mode" != exit ] || exit 2' \
  'if [ "$mode" = canary-missing ] && [ "$is_canary" = true ]; then exit 0; fi' \
  '[ "$is_canary" != true ] || exit 1' \
  '[ "$mode" != finding ] || exit 0' \
  'exit 0' > "$FAKE_GITLEAKS"
/bin/chmod 755 "$FAKE_GITLEAKS"

for source_name in scan.sh text-policy.sh; do
  /usr/bin/sed \
    "s|/opt/homebrew/Cellar/gitleaks/8.30.1/bin/gitleaks|$FAKE_GITLEAKS|g" \
    "$ROOT/guard/$source_name" > "$FAKE_GUARD/$source_name"
  /bin/chmod 755 "$FAKE_GUARD/$source_name"
done

for failure_mode in \
  stdout malformed finding missing-report exit short canary-missing \
  misleading-count duplicate-count missing-count; do
  if FAKE_GITLEAKS_MODE=$failure_mode \
    "$FAKE_GUARD/text-policy.sh" \
      --kind body \
      --input "$TEST_TMP/body.txt" \
      > "$TEST_TMP/fake-$failure_mode.out" 2>&1; then
    fail "forged gitleaks $failure_mode path was accepted"
  fi
  assert_contains 'LOCAL_ONLY_REMOTE_UNPROVEN' \
    "$TEST_TMP/fake-$failure_mode.out"
  assert_not_contains 'Safe local body' "$TEST_TMP/fake-$failure_mode.out"
done
FAKE_GITLEAKS_MODE=clean \
  "$FAKE_GUARD/text-policy.sh" \
    --kind body \
    --input "$TEST_TMP/body.txt" > "$TEST_TMP/fake-clean.json"
/usr/bin/jq -e '.verdict == "PASS_LOCAL_ONLY"' \
  "$TEST_TMP/fake-clean.json" >/dev/null ||
  fail "clean fake exact-stdin contract did not pass"

# The standalone body and the outgoing commit message use one predicate.
PARITY_REPO=$TEST_TMP/parity-repo
"$GIT" init -q "$PARITY_REPO"
"$GIT" -C "$PARITY_REPO" config user.name night-bot
"$GIT" -C "$PARITY_REPO" config user.email night-bot@users.noreply.github.com
/usr/bin/printf '%s\n' base > "$PARITY_REPO/file.txt"
"$GIT" -C "$PARITY_REPO" add file.txt
"$GIT" -C "$PARITY_REPO" -c core.hooksPath=/dev/null commit -qm 'Base content'
PARITY_BASE=$("$GIT" -C "$PARITY_REPO" rev-parse HEAD)
/usr/bin/printf '%s\n' 'candidate local content.' > "$PARITY_REPO/file.txt"
"$GIT" -C "$PARITY_REPO" add file.txt
"$GIT" -C "$PARITY_REPO" -c core.hooksPath=/dev/null commit -qm 'Discussion #123'
PARITY_TIP=$("$GIT" -C "$PARITY_REPO" rev-parse HEAD)
if "$ROOT/guard/scan.sh" \
  --repo "$PARITY_REPO" \
  --repo-id sample/repo \
  --base "$PARITY_BASE" \
  --candidate "$PARITY_TIP" \
  --manifest "$MANIFEST" > "$TEST_TMP/parity-scan.out" 2>&1; then
  fail "outgoing commit message bypassed the shared text predicate"
fi
assert_contains 'outgoing commit message text policy denied' \
  "$TEST_TMP/parity-scan.out"

PARITY_SECRET_REPO=$TEST_TMP/parity-secret-repo
"$GIT" init -q "$PARITY_SECRET_REPO"
"$GIT" -C "$PARITY_SECRET_REPO" config user.name night-bot
"$GIT" -C "$PARITY_SECRET_REPO" config user.email night-bot@users.noreply.github.com
/usr/bin/printf '%s\n' base > "$PARITY_SECRET_REPO/file.txt"
"$GIT" -C "$PARITY_SECRET_REPO" add file.txt
"$GIT" -C "$PARITY_SECRET_REPO" -c core.hooksPath=/dev/null commit -qm 'Base content'
PARITY_SECRET_BASE=$("$GIT" -C "$PARITY_SECRET_REPO" rev-parse HEAD)
/usr/bin/printf '%s\n' 'candidate local content.' > "$PARITY_SECRET_REPO/file.txt"
"$GIT" -C "$PARITY_SECRET_REPO" add file.txt
"$GIT" -C "$PARITY_SECRET_REPO" -c core.hooksPath=/dev/null commit -qm \
  'api_key：ABCDEFGHIJKLMNOPQRSTUVWXYZ123456'
PARITY_SECRET_TIP=$("$GIT" -C "$PARITY_SECRET_REPO" rev-parse HEAD)
if "$ROOT/guard/scan.sh" \
  --repo "$PARITY_SECRET_REPO" \
  --repo-id sample/repo \
  --base "$PARITY_SECRET_BASE" \
  --candidate "$PARITY_SECRET_TIP" \
  --manifest "$MANIFEST" > "$TEST_TMP/parity-secret-scan.out" 2>&1; then
  fail "outgoing commit message secret assignment bypassed the shared text predicate"
fi
assert_contains 'outgoing commit message text policy denied' \
  "$TEST_TMP/parity-secret-scan.out"

deny_outgoing_message() {
  label=$1
  message=$2
  outgoing_repo=$TEST_TMP/outgoing-$label
  "$GIT" init -q "$outgoing_repo"
  "$GIT" -C "$outgoing_repo" config user.name night-bot
  "$GIT" -C "$outgoing_repo" config user.email \
    night-bot@users.noreply.github.com
  /usr/bin/printf '%s\n' base > "$outgoing_repo/file.txt"
  "$GIT" -C "$outgoing_repo" add file.txt
  "$GIT" -C "$outgoing_repo" -c core.hooksPath=/dev/null \
    commit -qm 'Base content'
  outgoing_base=$("$GIT" -C "$outgoing_repo" rev-parse HEAD)
  /usr/bin/printf '%s\n' 'candidate local content.' > "$outgoing_repo/file.txt"
  "$GIT" -C "$outgoing_repo" add file.txt
  "$GIT" -C "$outgoing_repo" -c core.hooksPath=/dev/null \
    commit -q --cleanup=verbatim -F "$message"
  outgoing_tip=$("$GIT" -C "$outgoing_repo" rev-parse HEAD)
  if "$ROOT/guard/scan.sh" \
    --repo "$outgoing_repo" \
    --repo-id sample/repo \
    --base "$outgoing_base" \
    --candidate "$outgoing_tip" \
    --manifest "$MANIFEST" > "$TEST_TMP/outgoing-$label.out" 2>&1; then
    fail "outgoing commit message bypassed text policy: $label"
  fi
  assert_contains 'outgoing commit message text policy denied' \
    "$TEST_TMP/outgoing-$label.out"
}

deny_outgoing_message cyrillic-key "$TEST_TMP/cyrillic-a-key.txt"
deny_outgoing_message unicode-whitespace \
  "$TEST_TMP/ideographic-space-assignment.txt"
deny_outgoing_message unlisted-delimiter "$TEST_TMP/ratio-delimiter.txt"
deny_outgoing_message cross-line "$TEST_TMP/cross-line-assignment.txt"
deny_outgoing_message compound-cyrillic-ratio \
  "$TEST_TMP/compound-cyrillic-ratio.txt"
deny_outgoing_message blank-line-cyrillic-secret \
  "$TEST_TMP/blank-line-cyrillic-secret.txt"
deny_outgoing_message blank-line-cyrillic-ratio \
  "$TEST_TMP/blank-line-cyrillic-ratio.txt"
deny_outgoing_message multi-whitespace-lines-compound \
  "$TEST_TMP/multi-whitespace-lines-compound.txt"
deny_outgoing_message padding-api-80 "$TEST_TMP/padding-api-80.txt"
deny_outgoing_message padding-secret-80 "$TEST_TMP/padding-secret-80.txt"
deny_outgoing_message padding-cyrillic-secret-80 \
  "$TEST_TMP/padding-cyrillic-secret-80.txt"
deny_outgoing_message padding-cyrillic-ratio-80 \
  "$TEST_TMP/padding-cyrillic-ratio-80.txt"
deny_outgoing_message leading-hash-candidate \
  "$TEST_TMP/leading-hash-candidate.txt"
deny_outgoing_message leading-quote-candidate \
  "$TEST_TMP/leading-quote-candidate.txt"
deny_outgoing_message leading-short-word-confusable \
  "$TEST_TMP/leading-junk-confusable-secret.txt"
deny_outgoing_message intervening-note "$TEST_TMP/intervening-note.txt"
deny_outgoing_message intervening-note-confusable-ratio \
  "$TEST_TMP/intervening-note-confusable-ratio.txt"
deny_outgoing_message split-identifier-ascii \
  "$TEST_TMP/split-identifier-ascii.txt"
deny_outgoing_message split-identifier-confusable \
  "$TEST_TMP/split-identifier-confusable.txt"
deny_outgoing_message split-identifier-confusable-value-line \
  "$TEST_TMP/split-identifier-confusable-value-line.txt"
deny_outgoing_message split-identifier-ratio \
  "$TEST_TMP/split-identifier-ratio.txt"
deny_outgoing_message split-identifier-confusable-ratio-whitespace \
  "$TEST_TMP/split-identifier-confusable-ratio-whitespace.txt"
deny_outgoing_message pre-delimiter-padding-api-80 \
  "$TEST_TMP/pre-delimiter-padding-api-80.txt"
deny_outgoing_message pre-delimiter-padding-confusable-80 \
  "$TEST_TMP/pre-delimiter-padding-confusable-80.txt"
deny_outgoing_message pre-delimiter-padding-ratio-80 \
  "$TEST_TMP/pre-delimiter-padding-ratio-80.txt"
deny_outgoing_message pre-delimiter-unicode-filler \
  "$TEST_TMP/pre-delimiter-unicode-filler.txt"
deny_outgoing_message ascii-delimiter-hash \
  "$TEST_TMP/ascii-delimiter-hash.txt"
deny_outgoing_message short-confusable-token \
  "$TEST_TMP/short-confusable-token.txt"
deny_outgoing_message mixed-script-value \
  "$TEST_TMP/mixed-script-value.txt"
deny_outgoing_message greek-confusable-token \
  "$TEST_TMP/greek-confusable-token.txt"
deny_outgoing_message cyrillic-token-lowercase \
  "$TEST_TMP/cyrillic-token-lowercase.txt"
deny_outgoing_message cyrillic-token-uppercase \
  "$TEST_TMP/cyrillic-token-uppercase.txt"
deny_outgoing_message cyrillic-token-colon \
  "$TEST_TMP/cyrillic-token-colon.txt"
deny_outgoing_message cyrillic-token-middle-dot \
  "$TEST_TMP/cyrillic-token-middle-dot.txt"
deny_outgoing_message japanese-label-cyrillic-token \
  "$TEST_TMP/japanese-label-cyrillic-token.txt"
deny_outgoing_message cyrillic-confusable-api-key \
  "$TEST_TMP/cyrillic-confusable-api-key.txt"
deny_outgoing_message middle-dot-token \
  "$TEST_TMP/middle-dot-token.txt"
deny_outgoing_message japanese-inserted-api-key \
  "$TEST_TMP/japanese-inserted-api-key.txt"
deny_outgoing_message cross-script-confusable-token \
  "$TEST_TMP/cross-script-confusable-token.txt"
deny_outgoing_message cross-script-confusable-api-key \
  "$TEST_TMP/cross-script-confusable-api-key.txt"
deny_outgoing_message identifier-padding-api-key \
  "$TEST_TMP/identifier-padding-api-key.txt"
deny_outgoing_message soft-split-lf-api-key \
  "$TEST_TMP/soft-split-lf-api-key.txt"
deny_outgoing_message soft-split-nbsp-api-key \
  "$TEST_TMP/soft-split-nbsp-api-key.txt"
deny_outgoing_message cyrillic-ukrainian-ie-secret \
  "$TEST_TMP/cyrillic-ukrainian-ie-secret.txt"
deny_outgoing_message cyrillic-abkhasian-che-secret \
  "$TEST_TMP/cyrillic-abkhasian-che-secret.txt"
deny_outgoing_message mapped-estimated-symbol-secret \
  "$TEST_TMP/mapped-estimated-symbol-secret.txt"
deny_outgoing_message mapped-shadowed-apikey \
  "$DIRECT_SOURCE_DIR/a-237A.txt"
deny_outgoing_message mapped-shadowed-token \
  "$DIRECT_SOURCE_DIR/o-3007.txt"
deny_outgoing_message pending-mapped-source-secret \
  "$TEST_TMP/pending-mapped-source-secret.txt"
deny_outgoing_message pending-sigma-token \
  "$TEST_TMP/pending-sigma-token.txt"
deny_outgoing_message dual-off-position-secret \
  "$TEST_TMP/dual-off-position-all-multiline.txt"
deny_outgoing_message dual-off-position-apikey \
  "$DUAL_SOURCE_DIR/237A-apikey-2.txt"
deny_outgoing_message dual-matched-position-token \
  "$DUAL_SOURCE_DIR/3007-token-1.txt"
deny_outgoing_message pending-dual-off-position \
  "$TEST_TMP/pending-dual-off-position.txt"
deny_outgoing_message pending-dual-matched-position-duplicate \
  "$TEST_TMP/pending-dual-matched-position-duplicate.txt"
deny_outgoing_message soft-split-trademark-api-key \
  "$TEST_TMP/soft-split-trademark-api-key.txt"
deny_outgoing_message accented-greek-token \
  "$TEST_TMP/accented-greek-token.txt"
deny_outgoing_message accented-cyrillic-secret \
  "$TEST_TMP/accented-cyrillic-secret.txt"
deny_outgoing_message period-dotted-api-key \
  "$TEST_TMP/period-dotted-api-key.txt"
deny_outgoing_message period-spaced-token \
  "$TEST_TMP/period-spaced-token.txt"
deny_outgoing_message period-ideographic-secret \
  "$TEST_TMP/period-ideographic-secret.txt"
deny_outgoing_message period-one-dot-leader-secret \
  "$TEST_TMP/period-one-dot-leader-secret.txt"
deny_outgoing_message period-symbol-secret \
  "$TEST_TMP/period-symbol-secret.txt"
deny_outgoing_message period-japanese-token \
  "$TEST_TMP/period-japanese-token.txt"
deny_outgoing_message period-second-secret \
  "$TEST_TMP/period-second-secret.txt"
deny_outgoing_message period-second-api-key \
  "$TEST_TMP/period-second-api-key.txt"
deny_outgoing_message period-second-token \
  "$TEST_TMP/period-second-token.txt"
deny_outgoing_message pending-split-secret \
  "$TEST_TMP/pending-split-secret-3.txt"
deny_outgoing_message pending-split-api-key \
  "$TEST_TMP/pending-split-apikey-3.txt"
deny_outgoing_message pending-split-token \
  "$TEST_TMP/pending-split-token-3.txt"
deny_outgoing_message pending-compat-colon-secret \
  "$TEST_TMP/pending-compat-colon-secret.txt"
deny_outgoing_message pending-confusable-secret \
  "$TEST_TMP/pending-confusable-secret.txt"
deny_outgoing_message pending-direct-secret \
  "$TEST_TMP/pending-direct-secret.txt"
deny_outgoing_message pending-multiple-separators-secret \
  "$TEST_TMP/pending-multiple-separators-secret.txt"
deny_outgoing_message unicode-period-pending-secret \
  "$TEST_TMP/unicode-period-pending-secret.txt"
deny_outgoing_message period-second-confusable-secret \
  "$TEST_TMP/period-second-confusable-secret.txt"
deny_outgoing_message period-second-split-secret \
  "$TEST_TMP/period-second-split-secret.txt"
deny_outgoing_message period-second-direct-candidate \
  "$TEST_TMP/period-second-direct-candidate.txt"
deny_outgoing_message period-second-multiple-whitespace \
  "$TEST_TMP/period-second-multiple-whitespace.txt"
deny_outgoing_message unicode-period-second-secret \
  "$TEST_TMP/unicode-period-second-secret.txt"
deny_outgoing_message period-second-symbol-blank-compound \
  "$TEST_TMP/period-second-symbol-blank-compound.txt"
deny_outgoing_message suffix-period-secret \
  "$TEST_TMP/suffix-period-secret.txt"
deny_outgoing_message suffix-period-token \
  "$TEST_TMP/suffix-period-token.txt"
deny_outgoing_message suffix-period-api-key \
  "$TEST_TMP/suffix-period-api-key.txt"
deny_outgoing_message suffix-period-underscore \
  "$TEST_TMP/suffix-period-underscore.txt"
deny_outgoing_message suffix-ideographic-period \
  "$TEST_TMP/suffix-ideographic-period.txt"
deny_outgoing_message suffix-one-dot-leader \
  "$TEST_TMP/suffix-one-dot-leader.txt"
deny_outgoing_message suffix-confusable-period \
  "$TEST_TMP/suffix-confusable-period.txt"
deny_outgoing_message suffix-period-symbol-blank \
  "$TEST_TMP/suffix-period-symbol-blank.txt"
deny_outgoing_message suffix-period-newline-equals \
  "$TEST_TMP/suffix-period-newline-equals.txt"
deny_outgoing_message sigma-secret "$TEST_TMP/sigma-secret.txt"
deny_outgoing_message sigma-token "$TEST_TMP/sigma-token.txt"
deny_outgoing_message final-sigma-secret \
  "$TEST_TMP/final-sigma-secret.txt"
deny_outgoing_message math-sigma-u1d6d4-secret \
  "$TEST_TMP/math-sigma-u1d6d4-secret.txt"
deny_outgoing_message math-sigma-u1d70e-secret \
  "$TEST_TMP/math-sigma-u1d70e-secret.txt"
deny_outgoing_message math-sigma-u1d748-secret \
  "$TEST_TMP/math-sigma-u1d748-secret.txt"
deny_outgoing_message math-sigma-u1d782-secret \
  "$TEST_TMP/math-sigma-u1d782-secret.txt"
deny_outgoing_message math-sigma-u1d7bc-secret \
  "$TEST_TMP/math-sigma-u1d7bc-secret.txt"
deny_outgoing_message math-sigma-u1d6d4-token \
  "$TEST_TMP/sigma-derived-invariant/1D6D4-token.txt"
deny_outgoing_message decomposed-capital-sigma-token \
  "$TEST_TMP/decomposed-capital-sigma-token.txt"
deny_outgoing_message math-sigma-soft-blank-compound \
  "$TEST_TMP/math-sigma-soft-blank-compound.txt"
deny_outgoing_message lunate-sigma-secret \
  "$TEST_TMP/lunate-sigma-secret.txt"
deny_outgoing_message small-capital-y-api-key \
  "$TEST_TMP/small-capital-y-api-key.txt"
deny_outgoing_message coptic-sima-secret \
  "$TEST_TMP/coptic-sima-secret.txt"
deny_outgoing_message generated-api-key \
  "$TEST_TMP/generated-api-key.txt"
deny_outgoing_message generated-secret \
  "$TEST_TMP/generated-secret.txt"
deny_outgoing_message generated-token \
  "$TEST_TMP/generated-token.txt"
deny_outgoing_message generated-symbol-padding-compound \
  "$TEST_TMP/generated-symbol-padding-compound.txt"
while IFS=' ' read -r two_stage_target two_stage_code; do
  deny_outgoing_message "two-stage-$two_stage_code-match" \
    "$TWO_STAGE_SOURCE_DIR/$two_stage_target-$two_stage_code-match.txt"
done < "$TEST_TMP/two-stage-source-manifest.txt"
deny_outgoing_message two-stage-pending-duplicate \
  "$TEST_TMP/two-stage-pending-duplicate.txt"
deny_outgoing_message cf-u070f "$CF_SOURCE_DIR/070F.txt"
deny_outgoing_message co-ue000 "$CO_SOURCE_DIR/E000.txt"

pass_outgoing_message() {
  label=$1
  message=$2
  outgoing_repo=$TEST_TMP/pass-outgoing-$label
  "$GIT" init -q "$outgoing_repo"
  "$GIT" -C "$outgoing_repo" config user.name night-bot
  "$GIT" -C "$outgoing_repo" config user.email \
    night-bot@users.noreply.github.com
  /usr/bin/printf '%s\n' base > "$outgoing_repo/file.txt"
  "$GIT" -C "$outgoing_repo" add file.txt
  "$GIT" -C "$outgoing_repo" -c core.hooksPath=/dev/null \
    commit -qm 'Base content'
  outgoing_base=$("$GIT" -C "$outgoing_repo" rev-parse HEAD)
  /usr/bin/printf '%s\n' 'candidate local content.' > "$outgoing_repo/file.txt"
  "$GIT" -C "$outgoing_repo" add file.txt
  "$GIT" -C "$outgoing_repo" -c core.hooksPath=/dev/null \
    commit -q --cleanup=verbatim -F "$message"
  outgoing_tip=$("$GIT" -C "$outgoing_repo" rev-parse HEAD)
  "$ROOT/guard/scan.sh" \
    --repo "$outgoing_repo" \
    --repo-id sample/repo \
    --base "$outgoing_base" \
    --candidate "$outgoing_tip" \
    --manifest "$MANIFEST" > "$TEST_TMP/pass-outgoing-$label.json" ||
    fail "safe outgoing commit message was denied: $label"
  /usr/bin/jq -e '.verdict == "PASS_LOCAL_ONLY"' \
    "$TEST_TMP/pass-outgoing-$label.json" >/dev/null ||
    fail "safe outgoing commit message did not produce PASS_LOCAL_ONLY: $label"
}

pass_outgoing_message token-period-before-later-colon \
  "$TEST_TMP/token-period-before-later-colon.txt"
pass_outgoing_message token-suffix-period-before-later-colon \
  "$TEST_TMP/token-suffix-period-before-later-colon.txt"
pass_outgoing_message clean-10-kib \
  "$TEST_TMP/commit-message-10-kib.txt"

# Gateway and broker remain local-only and do not consult PATH credentials/tools.
mkdir -p "$TEST_TMP/remote-stubs"
for command_name in git gh curl ssh security; do
  /usr/bin/printf '%s\n' \
    '#!/bin/bash' \
    "/usr/bin/touch \"$TEST_TMP/REMOTE_PATH_INVOKED\"" \
    'exit 99' > "$TEST_TMP/remote-stubs/$command_name"
  /bin/chmod 755 "$TEST_TMP/remote-stubs/$command_name"
done
PATH="$TEST_TMP/remote-stubs:/usr/bin:/bin" \
GH_TOKEN=planted \
GITHUB_TOKEN=planted \
  "$ROOT/guard/gateway.sh" validate_text \
    --kind body \
    --input "$TEST_TMP/body.txt" > "$TEST_TMP/gateway-text.json"
/usr/bin/jq -e \
  '.schema == "alpha-nightshift/text-policy-evidence/v1" and
   .write_mode == false and .verdict == "PASS_LOCAL_ONLY"' \
  "$TEST_TMP/gateway-text.json" >/dev/null ||
  fail "gateway did not expose strict local text validation"

for layer in gateway broker; do
  for operation in \
    publish publish_branch create_draft_pr create_issue push merge comment label api request graphql; do
    if PATH="$TEST_TMP/remote-stubs:/usr/bin:/bin" \
      GH_TOKEN=planted \
      GITHUB_TOKEN=planted \
      "$ROOT/guard/$layer.sh" "$operation" \
        > "$TEST_TMP/$layer-$operation.out" 2>&1; then
      fail "$layer accepted hard-disabled operation: $operation"
    fi
    assert_contains 'LOCAL_ONLY_REMOTE_UNPROVEN' \
      "$TEST_TMP/$layer-$operation.out"
  done
done
[ ! -e "$TEST_TMP/REMOTE_PATH_INVOKED" ] ||
  fail "a network, credential, or remote tool stub was invoked"

printf 'test_guard_text_policy: PASS\n'
