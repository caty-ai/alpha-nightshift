#!/bin/bash
set -euo pipefail

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
ROOT=$(CDPATH= cd -- "$TEST_DIR/.." && pwd -P)
. "$TEST_DIR/helpers.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-scan-test.XXXXXX")
cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT
TEST_TMP=$(CDPATH= cd -- "$TEST_TMP" && pwd -P)
REPO=$TEST_TMP/repo
MANIFEST=$ROOT/config/guard-activation.example.json
GIT=/opt/homebrew/bin/git
DETECTABLE_VALUE='ABCDEFGHIJKLMNOPQRSTUVWXYZ'"123456"
DETECTABLE_ASSIGNMENT="api_key=$DETECTABLE_VALUE"

"$GIT" init -q "$REPO"
"$GIT" -C "$REPO" config user.name night-bot
"$GIT" -C "$REPO" config user.email night-bot@users.noreply.github.com
/usr/bin/printf '%s\n' 'base content.' > "$REPO/content.txt"
/usr/bin/printf '%s\n' '*.secret binary' > "$REPO/.gitattributes"
"$GIT" -C "$REPO" add content.txt .gitattributes
"$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'Base content'
BASE=$("$GIT" -C "$REPO" rev-parse HEAD)

scan_tip() {
  output=$1
  tip=$("$GIT" -C "$REPO" rev-parse HEAD)
  "$ROOT/guard/scan.sh" \
    --repo "$REPO" \
    --repo-id sample/repo \
    --base "$BASE" \
    --candidate "$tip" \
    --manifest "$MANIFEST" > "$output" 2>&1
}

reset_base() {
  "$GIT" -C "$REPO" reset -q --hard "$BASE"
}

/usr/bin/printf '%s\n' 'candidate content.' >> "$REPO/content.txt"
"$GIT" -C "$REPO" add content.txt
"$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'Candidate content'
scan_tip "$TEST_TMP/clean.json"
/usr/bin/jq -e '
  .mode == "LOCAL_ONLY_REMOTE_UNPROVEN" and
  .write_mode == false and
  .verdict == "PASS_LOCAL_ONLY" and
  .evidence_scope == "CALLER_SUPPLIED_LOCAL_BASE_NO_REMOTE_PROOF" and
  .counts.outgoing == 3 and
  .sets.explicit_membership_check == "PASS_LOCAL" and
  (.sets.local_raw_records.resident_base_sha256 | test("^[a-f0-9]{64}$")) and
  (.sets.local_raw_records.outgoing_sha256 | test("^[a-f0-9]{64}$")) and
  (.sets.outgoing_by_type | keys == ["blob","commit","tree"])
' "$TEST_TMP/clean.json" >/dev/null || fail "clean local object scan did not pass"
assert_not_contains 'api_key=' "$TEST_TMP/clean.json"
assert_not_contains 'NSCAN' "$TEST_TMP/clean.json"
# Accepted findings 9 and 11: local raw records and explicit membership are deterministic.
scan_tip "$TEST_TMP/clean-repeat.json"
cmp "$TEST_TMP/clean.json" "$TEST_TMP/clean-repeat.json" >/dev/null ||
  fail "local raw-record/set evidence was not deterministic"

# Accepted finding 5: Git tree ordering uses the virtual slash for directories.
reset_base
mkdir -p "$REPO/foo"
/usr/bin/printf '%s\n' clean > "$REPO/foo.txt"
/usr/bin/printf '%s\n' nested > "$REPO/foo/item.txt"
"$GIT" -C "$REPO" add foo.txt foo/item.txt
"$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'Canonical tree ordering fixture'
scan_tip "$TEST_TMP/tree-order.json"
/usr/bin/jq -e '.verdict == "PASS_LOCAL_ONLY"' "$TEST_TMP/tree-order.json" >/dev/null ||
  fail "canonical foo.txt plus foo directory tree was denied"

# Accepted finding 7: the tree canary is inserted canonically around late names.
reset_base
/usr/bin/printf '%s\n' late > "$REPO/zzzzzzzz-last"
"$GIT" -C "$REPO" add zzzzzzzz-last
"$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'Late tree name fixture'
scan_tip "$TEST_TMP/late-tree.json"
/usr/bin/jq -e '.verdict == "PASS_LOCAL_ONLY"' "$TEST_TMP/late-tree.json" >/dev/null ||
  fail "canonical late-name tree canary failed"

# Accepted finding 6: gitleaks 8.30.1 reports empty stdin as "(0)".
reset_base
: > "$REPO/empty.txt"
"$GIT" -C "$REPO" add empty.txt
"$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'Empty blob fixture'
scan_tip "$TEST_TMP/empty.json"
/usr/bin/jq -e '.verdict == "PASS_LOCAL_ONLY"' "$TEST_TMP/empty.json" >/dev/null ||
  fail "clean empty outgoing blob or its canary was denied"

# Accepted finding 4: a 160000 gitlink is outside the scanned closure and denies.
reset_base
"$GIT" -C "$REPO" update-index --add --cacheinfo "160000,$BASE,external-link"
"$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'Gitlink fixture'
if scan_tip "$TEST_TMP/gitlink.out" 2>&1; then
  fail "gitlink tree mode 160000 was accepted"
fi
assert_contains 'LOCAL_ONLY_REMOTE_UNPROVEN' "$TEST_TMP/gitlink.out"

reset_base
/usr/bin/printf '%s\n' "$DETECTABLE_ASSIGNMENT" > "$REPO/hidden.secret"
"$GIT" -C "$REPO" add hidden.secret
"$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'Attribute fixture'
if scan_tip "$TEST_TMP/attribute.out" 2>&1; then
  fail ".gitattributes binary marker hid a secret"
fi
assert_contains 'LOCAL_ONLY_REMOTE_UNPROVEN' "$TEST_TMP/attribute.out"
assert_not_contains "$DETECTABLE_VALUE" "$TEST_TMP/attribute.out"

reset_base
for magic_kind in gzip zip pdf elf wasm; do
  reset_base
  case "$magic_kind" in
    gzip) /usr/bin/printf '\037\213plaintext\n' > "$REPO/magic.bin" ;;
    zip) /usr/bin/printf 'PK\003\004plaintext\n' > "$REPO/magic.bin" ;;
    pdf) /usr/bin/printf '%%PDF-1.7\nplaintext\n' > "$REPO/magic.bin" ;;
    elf) /usr/bin/printf '\177ELFplaintext\n' > "$REPO/magic.bin" ;;
    wasm) /usr/bin/printf '\000asmplaintext\n' > "$REPO/magic.bin" ;;
  esac
  "$GIT" -C "$REPO" add magic.bin
  "$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'Magic fixture'
  if scan_tip "$TEST_TMP/magic-$magic_kind.out" 2>&1; then
    fail "$magic_kind magic prefix was accepted"
  fi
  assert_contains 'LOCAL_ONLY_REMOTE_UNPROVEN' "$TEST_TMP/magic-$magic_kind.out"
done

for encoding in UTF-16LE UTF-16BE UTF-32LE UTF-32BE UTF-7; do
  reset_base
  /usr/bin/printf '£%s' "$DETECTABLE_ASSIGNMENT" |
    /usr/bin/iconv -f UTF-8 -t "$encoding" > "$REPO/encoded.txt"
  "$GIT" -C "$REPO" add encoded.txt
  "$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'Encoding fixture'
  if scan_tip "$TEST_TMP/$encoding.out" 2>&1; then
    fail "$encoding object was accepted"
  fi
done

reset_base
encoded=$(/usr/bin/printf '%s' "$DETECTABLE_ASSIGNMENT" | /usr/bin/base64)
/usr/bin/printf '%s' "$encoded" > "$REPO/wrapped.txt"
"$GIT" -C "$REPO" add wrapped.txt
"$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'Wrapper fixture'
if scan_tip "$TEST_TMP/wrapper.out" 2>&1; then
  fail "decoded secret representation was accepted"
fi
assert_not_contains "$DETECTABLE_VALUE" "$TEST_TMP/wrapper.out"

# Accepted finding 3: one ordinary terminal LF remains part of the wrapper grammar.
hex_encoded=$(/usr/bin/perl -e 'print unpack("H*",$ARGV[0])' "$DETECTABLE_ASSIGNMENT")
percent_encoded=$(/usr/bin/perl -e '
  print join "", map { sprintf "%%%02X",ord } split //,$ARGV[0]
' "$DETECTABLE_ASSIGNMENT")
for wrapper_kind in base64 hex percent; do
  reset_base
  case "$wrapper_kind" in
    base64) wrapper_value=$encoded ;;
    hex) wrapper_value=$hex_encoded ;;
    percent) wrapper_value=$percent_encoded ;;
  esac
  /usr/bin/printf '%s\n' "$wrapper_value" > "$REPO/wrapped-lf.txt"
  "$GIT" -C "$REPO" add wrapped-lf.txt
  "$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'LF wrapper fixture'
  if scan_tip "$TEST_TMP/wrapper-lf-$wrapper_kind.out" 2>&1; then
    fail "$wrapper_kind wrapper ending in one LF hid a secret"
  fi
  assert_not_contains "$DETECTABLE_VALUE" "$TEST_TMP/wrapper-lf-$wrapper_kind.out"
  if [ "$wrapper_kind" = hex ]; then
    [ "$(( ${#wrapper_value} % 4 ))" -eq 0 ] ||
      fail "exact hex regression is not 4k-length"
    assert_contains 'secret detector denied an outgoing object' \
      "$TEST_TMP/wrapper-lf-$wrapper_kind.out"
    assert_not_contains 'representation or commit policy denied' \
      "$TEST_TMP/wrapper-lf-$wrapper_kind.out"
  fi
done

# Round 3: normalized wrapper shapes must never fall through as clean text.
reset_base
line_wrapped=$(/usr/bin/printf '%s' "$encoded" | /usr/bin/fold -w 12)
/usr/bin/printf '%s\n' "$line_wrapped" > "$REPO/wrapped-lines.txt"
"$GIT" -C "$REPO" add wrapped-lines.txt
"$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'Line wrapped Base64 fixture'
if scan_tip "$TEST_TMP/wrapper-lines.out" 2>&1; then
  fail "line-wrapped Base64 with a terminal LF hid a secret"
fi
assert_not_contains "$DETECTABLE_VALUE" "$TEST_TMP/wrapper-lines.out"

for ascii_boundary in space tab; do
  reset_base
  case "$ascii_boundary" in
    space)
      /usr/bin/printf '%s %s\n' "${encoded:0:12}" "${encoded:12}" \
        > "$REPO/wrapped-ascii.txt"
      ;;
    tab)
      /usr/bin/printf '%s\t%s\n' "${encoded:0:12}" "${encoded:12}" \
        > "$REPO/wrapped-ascii.txt"
      ;;
  esac
  "$GIT" -C "$REPO" add wrapped-ascii.txt
  "$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'ASCII wrapper boundary fixture'
  if scan_tip "$TEST_TMP/wrapper-ascii-$ascii_boundary.out" 2>&1; then
    fail "internal ASCII $ascii_boundary hid a Base64 secret"
  fi
  assert_not_contains "$DETECTABLE_VALUE" "$TEST_TMP/wrapper-ascii-$ascii_boundary.out"
done

for unicode_boundary in nbsp zwsp zwnj; do
  reset_base
  case "$unicode_boundary" in
    nbsp) unicode_bytes='\302\240' ;;
    zwsp) unicode_bytes='\342\200\213' ;;
    zwnj) unicode_bytes='\342\200\214' ;;
  esac
  /usr/bin/printf "$unicode_bytes%s$unicode_bytes\n" "$encoded" \
    > "$REPO/wrapped-unicode.txt"
  "$GIT" -C "$REPO" add wrapped-unicode.txt
  "$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'Unicode wrapper boundary fixture'
  if scan_tip "$TEST_TMP/wrapper-unicode-$unicode_boundary.out" 2>&1; then
    fail "$unicode_boundary boundary hid a Base64 secret"
  fi
  assert_not_contains "$DETECTABLE_VALUE" "$TEST_TMP/wrapper-unicode-$unicode_boundary.out"
done

# Private-use and unassigned characters participate only in the normalized
# whole-wrapper ambiguity check. Pin the runtime properties used by these
# fixtures, then exercise one private-use representative from every range.
wrapper_unicode_runtime=$(/usr/bin/perl -MUnicode::UCD -e '
  my @co=map { chr(hex $_) =~ /\p{Co}/ ? 1 : 0 }
    qw(E000 F0000 100000);
  my $cn=chr(0x2FE0) =~ /\p{Cn}/ ? 1 : 0;
  print "perl=$] unicode=",Unicode::UCD::UnicodeVersion(),
    " co=",join("",@co)," cn=$cn\n";
')
[ "$wrapper_unicode_runtime" = \
  'perl=5.034001 unicode=13.0.0 co=111 cn=1' ] ||
  fail "wrapper Unicode property runtime or representative set changed"

for wrapper_case in plain cf-00ad co-e000 co-f0000 co-100000 cn-2fe0; do
  reset_base
  case "$wrapper_case" in
    plain)
      /usr/bin/printf '%s' "$encoded" > "$REPO/wrapped-structural.txt"
      ;;
    cf-00ad) wrapper_code=00AD ;;
    co-e000) wrapper_code=E000 ;;
    co-f0000) wrapper_code=F0000 ;;
    co-100000) wrapper_code=100000 ;;
    cn-2fe0) wrapper_code=2FE0 ;;
  esac
  if [ "$wrapper_case" != plain ]; then
    /usr/bin/perl -CSDA -e '
      my ($value,$hex)=@ARGV;
      print substr($value,0,20),chr(hex $hex),substr($value,20);
    ' "$encoded" "$wrapper_code" > "$REPO/wrapped-structural.txt"
  fi
  "$GIT" -C "$REPO" add wrapped-structural.txt
  "$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm \
    'Structural wrapper differential fixture'
  if scan_tip "$TEST_TMP/wrapper-structural-$wrapper_case.out" 2>&1; then
    fail "$wrapper_case interposition hid a Base64 secret"
  fi
  assert_contains 'LOCAL_ONLY_REMOTE_UNPROVEN' \
    "$TEST_TMP/wrapper-structural-$wrapper_case.out"
  assert_not_contains "$DETECTABLE_VALUE" \
    "$TEST_TMP/wrapper-structural-$wrapper_case.out"
  if [ "$wrapper_case" = plain ]; then
    assert_contains 'secret detector denied an outgoing object' \
      "$TEST_TMP/wrapper-structural-$wrapper_case.out"
  else
    assert_contains 'encoded wrapper is ambiguous or exceeds bounds' \
      "$TEST_TMP/wrapper-structural-$wrapper_case.out"
  fi
done

for nonwrapper_case in co-e000 cn-2fe0; do
  reset_base
  case "$nonwrapper_case" in
    co-e000) nonwrapper_code=E000 ;;
    cn-2fe0) nonwrapper_code=2FE0 ;;
  esac
  /usr/bin/perl -CSDA -e '
    my ($hex)=@ARGV;
    print "ordinary non-wrapper ",chr(hex $hex)," prose.\n";
  ' "$nonwrapper_code" > "$REPO/ordinary-unicode.txt"
  "$GIT" -C "$REPO" add ordinary-unicode.txt
  "$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm \
    'Ordinary Unicode blob fixture'
  scan_tip "$TEST_TMP/nonwrapper-$nonwrapper_case.json"
  /usr/bin/jq -e '
    .mode == "LOCAL_ONLY_REMOTE_UNPROVEN" and
    .write_mode == false and
    .verdict == "PASS_LOCAL_ONLY"
  ' "$TEST_TMP/nonwrapper-$nonwrapper_case.json" >/dev/null ||
    fail "$nonwrapper_case ordinary non-wrapper blob was denied"
done

MARK_MANIFEST=$TEST_TMP/wrapper-mark-categories.txt
MARK_RUNTIME=$TEST_TMP/wrapper-mark-runtime.txt
/usr/bin/perl -MUnicode::UCD -e '
  use strict;
  use warnings;
  my ($manifest_path,$runtime_path)=@ARGV;
  open my $manifest,">",$manifest_path or exit 90;
  my @runtime;
  for my $category (qw(Mn Mc Me)) {
    my @boundaries=Unicode::UCD::prop_invlist($category);
    exit 91 unless @boundaries && @boundaries%2==0;
    my $count=0;
    for (my $index=0;$index<@boundaries;$index+=2) {
      $count += $boundaries[$index+1]-$boundaries[$index];
    }
    exit 92 unless $count>0;
    my $first=sprintf "%04X",$boundaries[0];
    print {$manifest} lc($category)," $first\n" or exit 93;
    push @runtime,"$category=$count first=$first";
  }
  close $manifest or exit 94;
  open my $runtime,">",$runtime_path or exit 95;
  print {$runtime}
    "perl=$] unicode=",Unicode::UCD::UnicodeVersion(),
    " ",join(" ",@runtime),"\n" or exit 96;
  close $runtime or exit 97;
' "$MARK_MANIFEST" "$MARK_RUNTIME"
[ "$(/bin/cat "$MARK_RUNTIME")" = \
  'perl=5.034001 unicode=13.0.0 Mn=1839 first=0300 Mc=443 first=0903 Me=13 first=0488' ] ||
  fail "Unicode mark category runtime, counts, or representatives changed"
/usr/bin/printf '%s\n' \
  'mn 0300' \
  'mc 0903' \
  'me 0488' > "$TEST_TMP/wrapper-mark-categories.expected.txt"
/usr/bin/cmp -s \
  "$TEST_TMP/wrapper-mark-categories.expected.txt" \
  "$MARK_MANIFEST" ||
  fail "derived Unicode mark category representatives changed"

{
  /bin/cat "$MARK_MANIFEST"
  /usr/bin/printf '%s\n' \
    'braille 2800' \
    'object-replacement FFFC' \
    'replacement FFFD'
} > "$TEST_TMP/render-transparent-cases.txt"

while IFS=' ' read -r render_case render_code; do
  reset_base
  /usr/bin/perl -MUnicode::Normalize -CSDA -e '
    my ($value,$hex)=@ARGV;
    my $fixture=
      substr($value,0,20) . chr(hex $hex) . substr($value,20);
    exit 90 unless NFC($fixture) eq $fixture;
    print $fixture;
  ' "$encoded" "$render_code" > "$REPO/wrapped-render-transparent.txt"
  "$GIT" -C "$REPO" add wrapped-render-transparent.txt
  "$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm \
    'Render-transparent wrapper fixture'
  if scan_tip "$TEST_TMP/wrapper-render-$render_case.out" 2>&1; then
    fail "$render_case interposition hid a Base64 secret"
  fi
  assert_contains 'LOCAL_ONLY_REMOTE_UNPROVEN' \
    "$TEST_TMP/wrapper-render-$render_case.out"
  assert_contains 'encoded wrapper is ambiguous or exceeds bounds' \
    "$TEST_TMP/wrapper-render-$render_case.out"
  assert_not_contains "$DETECTABLE_VALUE" \
    "$TEST_TMP/wrapper-render-$render_case.out"
done < "$TEST_TMP/render-transparent-cases.txt"

while IFS=' ' read -r render_case render_code; do
  reset_base
  /usr/bin/perl -MUnicode::Normalize -CSDA -e '
    my ($hex)=@ARGV;
    my $fixture="ordinary.non-wrapper." . chr(hex $hex) . ".prose.\n";
    exit 90 unless NFC($fixture) eq $fixture;
    print $fixture;
  ' "$render_code" > "$REPO/ordinary-render-transparent.txt"
  "$GIT" -C "$REPO" add ordinary-render-transparent.txt
  "$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm \
    'Ordinary render-transparent blob fixture'
  scan_tip "$TEST_TMP/nonwrapper-render-$render_case.json"
  /usr/bin/jq -e '
    .mode == "LOCAL_ONLY_REMOTE_UNPROVEN" and
    .write_mode == false and
    .verdict == "PASS_LOCAL_ONLY"
  ' "$TEST_TMP/nonwrapper-render-$render_case.json" >/dev/null ||
    fail "$render_case ordinary non-wrapper blob was denied"
done < "$TEST_TMP/render-transparent-cases.txt"

reset_base
/usr/bin/printf '%s!%s' "${encoded:0:20}" "${encoded:20}" \
  > "$REPO/visible-punctuation-control.txt"
"$GIT" -C "$REPO" add visible-punctuation-control.txt
"$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm \
  'Visible punctuation comparison control'
scan_tip "$TEST_TMP/visible-punctuation-control.json"
/usr/bin/jq -e '
  .mode == "LOCAL_ONLY_REMOTE_UNPROVEN" and
  .write_mode == false and
  .verdict == "PASS_LOCAL_ONLY"
' "$TEST_TMP/visible-punctuation-control.json" >/dev/null ||
  fail "visible punctuation was treated as removable wrapper garbage"

reset_base
base64url=$(
  /usr/bin/printf '%s??' "$DETECTABLE_ASSIGNMENT" |
    /usr/bin/base64 |
    /usr/bin/tr '+/' '-_'
)
case "$base64url" in
  *[-_]*) ;;
  *) fail "Base64url fixture does not exercise URL-specific alphabet" ;;
esac
/usr/bin/printf '%s\n' "$base64url" > "$REPO/wrapped-base64url.txt"
"$GIT" -C "$REPO" add wrapped-base64url.txt
"$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'Base64url wrapper fixture'
if scan_tip "$TEST_TMP/wrapper-base64url.out" 2>&1; then
  fail "Base64url wrapper shape hid a secret"
fi
assert_not_contains "$DETECTABLE_VALUE" "$TEST_TMP/wrapper-base64url.out"

# Round 4: unpadded, composed-normalization, and mixed-alphabet wrapper oracles.
reset_base
unpadded_standard=${encoded%%=*}
case "$(( ${#unpadded_standard} % 4 ))" in
  2|3) ;;
  *) fail "unpadded standard fixture does not exercise modulo-two/three grammar" ;;
esac
case "$unpadded_standard" in
  *[!A-Za-z0-9+/]*) fail "unpadded standard fixture left the standard alphabet" ;;
esac
/usr/bin/printf '%s' "$unpadded_standard" > "$REPO/wrapped-unpadded.txt"
"$GIT" -C "$REPO" add wrapped-unpadded.txt
"$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'Unpadded standard Base64 fixture'
if scan_tip "$TEST_TMP/wrapper-unpadded.out" 2>&1; then
  fail "unpadded standard Base64 hid a secret"
fi
assert_contains 'LOCAL_ONLY_REMOTE_UNPROVEN' "$TEST_TMP/wrapper-unpadded.out"
assert_not_contains "$DETECTABLE_VALUE" "$TEST_TMP/wrapper-unpadded.out"

reset_base
case "$unpadded_standard" in
  *[!A-Za-z0-9]*) fail "space-normalization fixture is not pure alphanumeric Base64" ;;
esac
unpadded_space="${unpadded_standard:0:27} ${unpadded_standard:27}"
case "$unpadded_space" in
  *' '*) ;;
  *) fail "space-normalization fixture lacks an internal ASCII space" ;;
esac
[ "${unpadded_space% *}${unpadded_space#* }" = "$unpadded_standard" ] ||
  fail "space-normalization fixture does not reveal the unpadded wrapper"
/usr/bin/printf '%s' "$unpadded_space" > "$REPO/wrapped-unpadded-space.txt"
"$GIT" -C "$REPO" add wrapped-unpadded-space.txt
"$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm \
  'Space-split unpadded standard Base64 fixture'
if scan_tip "$TEST_TMP/wrapper-unpadded-space.out" 2>&1; then
  fail "internal ASCII space hid unpadded standard Base64"
fi
assert_contains 'LOCAL_ONLY_REMOTE_UNPROVEN' \
  "$TEST_TMP/wrapper-unpadded-space.out"
assert_not_contains "$DETECTABLE_VALUE" \
  "$TEST_TMP/wrapper-unpadded-space.out"

reset_base
mod1_union="${unpadded_standard}AAA"
case "$mod1_union" in
  *[!A-Za-z0-9]*) fail "modulo-one union fixture is not pure alphanumeric" ;;
esac
[ "$(( ${#mod1_union} % 4 ))" -eq 1 ] ||
  fail "union-alphabet fixture does not exercise modulo-one grammar"
/usr/bin/perl -MMIME::Base64=decode_base64 -e '
  my ($encoded_value,$expected)=@ARGV;
  my $decoded=decode_base64($encoded_value);
  exit(index($decoded,$expected)==0 ? 0 : 1);
' "$mod1_union" "$DETECTABLE_ASSIGNMENT" ||
  fail "lenient local Base64 decode did not recover the detectable assignment"
mod1_space="${mod1_union:0:27} ${mod1_union:27}"
case "$mod1_space" in
  *' '*) ;;
  *) fail "modulo-one normalization fixture lacks an internal ASCII space" ;;
esac
[ "${mod1_space% *}${mod1_space#* }" = "$mod1_union" ] ||
  fail "space normalization does not reveal the modulo-one union value"
/usr/bin/printf '%s' "$mod1_space" > "$REPO/wrapped-mod1-space.txt"
"$GIT" -C "$REPO" add wrapped-mod1-space.txt
"$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm \
  'Space-split modulo-one Base64 union fixture'
if scan_tip "$TEST_TMP/wrapper-mod1-space.out" 2>&1; then
  fail "internal ASCII space hid a leniently decodable modulo-one union value"
fi
assert_contains 'LOCAL_ONLY_REMOTE_UNPROVEN' \
  "$TEST_TMP/wrapper-mod1-space.out"
assert_not_contains "$DETECTABLE_VALUE" \
  "$TEST_TMP/wrapper-mod1-space.out"

reset_base
url_mod1="${mod1_union:0:12}_${mod1_union:13}"
case "$url_mod1" in
  *_*) ;;
  *) fail "URL-safe modulo-one fixture lacks an underscore" ;;
esac
case "$url_mod1" in
  *[!A-Za-z0-9_-]*) fail "URL-safe modulo-one fixture left the union alphabet" ;;
esac
[ "$(( ${#url_mod1} % 4 ))" -eq 1 ] ||
  fail "URL-safe union fixture does not exercise modulo-one grammar"
url_mod1_tab="${url_mod1:0:27}	${url_mod1:27}"
case "$url_mod1_tab" in
  *"	"*) ;;
  *) fail "URL-safe normalization fixture lacks an internal ASCII tab" ;;
esac
[ "${url_mod1_tab%	*}${url_mod1_tab#*	}" = "$url_mod1" ] ||
  fail "tab normalization does not reveal the URL-safe modulo-one value"
/usr/bin/printf '%s' "$url_mod1_tab" > "$REPO/wrapped-url-mod1-tab.txt"
"$GIT" -C "$REPO" add wrapped-url-mod1-tab.txt
"$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm \
  'Tab-split URL-safe modulo-one fixture'
if scan_tip "$TEST_TMP/wrapper-url-mod1-tab.out" 2>&1; then
  fail "internal ASCII tab hid a URL-safe modulo-one union value"
fi
assert_contains 'LOCAL_ONLY_REMOTE_UNPROVEN' \
  "$TEST_TMP/wrapper-url-mod1-tab.out"
assert_not_contains "$DETECTABLE_VALUE" \
  "$TEST_TMP/wrapper-url-mod1-tab.out"

reset_base
exclusive_standard=$(
  /usr/bin/printf '%s???' "$DETECTABLE_ASSIGNMENT" |
    /usr/bin/base64
)
exclusive_standard=${exclusive_standard%%=*}
case "$exclusive_standard" in
  *=*) fail "exclusive standard fixture retained padding" ;;
esac
case "$exclusive_standard" in
  *['+/']*) ;;
  *) fail "exclusive standard fixture lacks + or /" ;;
esac
case "$(( ${#exclusive_standard} % 4 ))" in
  2|3) ;;
  *) fail "exclusive standard fixture is not legal unpadded modulo-two/three" ;;
esac
/usr/bin/printf '%s' "$exclusive_standard" > "$REPO/wrapped-unpadded-exclusive.txt"
"$GIT" -C "$REPO" add wrapped-unpadded-exclusive.txt
"$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'Exclusive unpadded standard fixture'
if scan_tip "$TEST_TMP/wrapper-unpadded-exclusive.out" 2>&1; then
  fail "unpadded standard Base64 with + or / hid a secret"
fi
assert_contains 'LOCAL_ONLY_REMOTE_UNPROVEN' "$TEST_TMP/wrapper-unpadded-exclusive.out"
assert_not_contains "$DETECTABLE_VALUE" "$TEST_TMP/wrapper-unpadded-exclusive.out"

for composed_boundary in nbsp-lf tab-zwsp lf-zwnj; do
  reset_base
  case "$composed_boundary" in
    nbsp-lf)
      /usr/bin/printf '%s\302\240%s\n%s' \
        "${encoded:0:12}" "${encoded:12:12}" "${encoded:24}" \
        > "$REPO/wrapped-composed.txt"
      ;;
    tab-zwsp)
      /usr/bin/printf '%s\t%s\342\200\213%s' \
        "${encoded:0:12}" "${encoded:12:12}" "${encoded:24}" \
        > "$REPO/wrapped-composed.txt"
      ;;
    lf-zwnj)
      /usr/bin/printf '%s\n%s\342\200\214%s' \
        "${encoded:0:12}" "${encoded:12:12}" "${encoded:24}" \
        > "$REPO/wrapped-composed.txt"
      ;;
  esac
  "$GIT" -C "$REPO" add wrapped-composed.txt
  "$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'Composed wrapper boundary fixture'
  if scan_tip "$TEST_TMP/wrapper-composed-$composed_boundary.out" 2>&1; then
    fail "$composed_boundary normalization combination hid a secret"
  fi
  assert_contains 'LOCAL_ONLY_REMOTE_UNPROVEN' \
    "$TEST_TMP/wrapper-composed-$composed_boundary.out"
  assert_not_contains "$DETECTABLE_VALUE" \
    "$TEST_TMP/wrapper-composed-$composed_boundary.out"
done

reset_base
mixed_alphabet="${exclusive_standard:0:12}-${exclusive_standard:12}"
case "$mixed_alphabet" in
  *['+/']*) ;;
  *) fail "mixed-alphabet fixture lacks standard-exclusive + or /" ;;
esac
case "$mixed_alphabet" in
  *[-_]*) ;;
  *) fail "mixed-alphabet fixture lacks URL-safe-exclusive - or _" ;;
esac
case "$mixed_alphabet" in
  *[!A-Za-z0-9+/=_-]*) fail "mixed-alphabet fixture left the union alphabet" ;;
esac
/usr/bin/printf '%s' "$mixed_alphabet" > "$REPO/wrapped-mixed-alphabet.txt"
"$GIT" -C "$REPO" add wrapped-mixed-alphabet.txt
"$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'Mixed Base64 alphabet fixture'
if scan_tip "$TEST_TMP/wrapper-mixed-alphabet.out" 2>&1; then
  fail "mixed standard and URL-safe Base64 alphabet hid a secret"
fi
assert_contains 'LOCAL_ONLY_REMOTE_UNPROVEN' "$TEST_TMP/wrapper-mixed-alphabet.out"
assert_not_contains "$DETECTABLE_VALUE" "$TEST_TMP/wrapper-mixed-alphabet.out"

clean_wrapper=$(/usr/bin/printf '%s' 'ordinary clean payload' | /usr/bin/base64)
for boundary_kind in crlf multiple-lf leading-space trailing-space; do
  reset_base
  case "$boundary_kind" in
    crlf) /usr/bin/printf '%s\r\n' "$clean_wrapper" > "$REPO/ambiguous.txt" ;;
    multiple-lf) /usr/bin/printf '%s\n\n' "$clean_wrapper" > "$REPO/ambiguous.txt" ;;
    leading-space) /usr/bin/printf ' %s\n' "$clean_wrapper" > "$REPO/ambiguous.txt" ;;
    trailing-space) /usr/bin/printf '%s \n' "$clean_wrapper" > "$REPO/ambiguous.txt" ;;
  esac
  "$GIT" -C "$REPO" add ambiguous.txt
  "$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'Ambiguous wrapper boundary fixture'
  if scan_tip "$TEST_TMP/ambiguous-$boundary_kind.out" 2>&1; then
    fail "$boundary_kind wrapper boundary was accepted"
  fi
done

reset_base
wrapped_once=$(/usr/bin/printf '%s' 'clean wrapper payload' | /usr/bin/base64)
wrapped_twice=$(/usr/bin/printf '%s' "$wrapped_once" | /usr/bin/base64)
wrapped_thrice=$(/usr/bin/printf '%s' "$wrapped_twice" | /usr/bin/base64)
/usr/bin/printf '%s' "$wrapped_thrice" > "$REPO/deep-wrapper.txt"
"$GIT" -C "$REPO" add deep-wrapper.txt
"$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'Deep wrapper fixture'
if scan_tip "$TEST_TMP/deep-wrapper.out" 2>&1; then
  fail "decode depth overflow was accepted"
fi

reset_base
secret_name=$DETECTABLE_ASSIGNMENT
/usr/bin/printf '%s\n' clean > "$REPO/$secret_name"
"$GIT" -C "$REPO" add "$secret_name"
"$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'Tree name fixture'
if scan_tip "$TEST_TMP/tree.out" 2>&1; then
  fail "tree-name-only secret was accepted"
fi
assert_not_contains "$DETECTABLE_VALUE" "$TEST_TMP/tree.out"

# Accepted finding 10: keep and expose the intentionally narrow MIME policy.
reset_base
/usr/bin/printf '%s\n' '#!/bin/bash' 'printf "%s\n" safe' > "$REPO/source.sh"
"$GIT" -C "$REPO" add source.sh
"$GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'Narrow MIME fixture'
if scan_tip "$TEST_TMP/source-mime.out" 2>&1; then
  fail "source MIME outside the Phase 1a allowlist was accepted"
fi
assert_contains 'unsupported or opaque classification' "$TEST_TMP/source-mime.out"

tip=$("$GIT" -C "$REPO" rev-parse HEAD)
object_dir=${tip%${tip#??}}
object_name=${tip#??}
/bin/chmod 644 "$REPO/.git/objects/$object_dir/$object_name"
/usr/bin/printf '%s' corrupt > "$REPO/.git/objects/$object_dir/$object_name"
if "$ROOT/guard/scan.sh" \
  --repo "$REPO" \
  --repo-id sample/repo \
  --base "$BASE" \
  --candidate "$tip" \
  --manifest "$MANIFEST" > "$TEST_TMP/corrupt.out" 2>&1; then
  fail "corrupt/short Git object was accepted"
fi
assert_contains 'LOCAL_ONLY_REMOTE_UNPROVEN' "$TEST_TMP/corrupt.out"

printf 'test_guard_scan: PASS\n'
