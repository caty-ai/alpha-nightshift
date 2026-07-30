#!/bin/bash
set -euo pipefail

GUARD_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
# shellcheck source=guard/common.sh
. "$GUARD_DIR/common.sh"

kind=
input=
seen_kind=false
seen_input=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --kind)
      [ "$seen_kind" = false ] ||
        { guard_fail "duplicate text kind"; exit 1; }
      [ "$#" -ge 2 ] ||
        { guard_fail "missing text kind"; exit 1; }
      kind=$2
      seen_kind=true
      shift 2
      ;;
    --input)
      [ "$seen_input" = false ] ||
        { guard_fail "duplicate text input"; exit 1; }
      [ "$#" -ge 2 ] ||
        { guard_fail "missing text input"; exit 1; }
      input=$2
      seen_input=true
      shift 2
      ;;
    *)
      guard_fail "unknown text-policy field"
      exit 1
      ;;
  esac
done

[ "$seen_kind" = true ] && [ "$seen_input" = true ] ||
  { guard_fail "text policy requires kind and input"; exit 1; }
case "$kind" in
  commit_message) max_bytes=16384 ;;
  title) max_bytes=512 ;;
  body) max_bytes=65536 ;;
  comment) max_bytes=32768 ;;
  *) guard_fail "invalid text kind"; exit 1 ;;
esac

guard_validate_absolute_path "$input" file
[ ! -L "$input" ] ||
  { guard_fail "text input must not be symlinked"; exit 1; }
input_links=$(/usr/bin/stat -f '%l' "$input" 2>/dev/null) ||
  { guard_fail "text input metadata is unavailable"; exit 1; }
[ "$input_links" -eq 1 ] ||
  { guard_fail "text input has an alias"; exit 1; }
input_size=$(/usr/bin/stat -f '%z' "$input" 2>/dev/null) ||
  { guard_fail "text input size is unavailable"; exit 1; }
case "$input_size" in
  ''|*[!0-9]*) guard_fail "text input size is malformed"; exit 1 ;;
esac
[ "$input_size" -le "$max_bytes" ] ||
  { guard_fail "text input exceeds the kind limit"; exit 1; }

/usr/bin/perl -e '
  use strict;
  use warnings;
  use Fcntl qw(S_ISLNK S_ISREG);
  my $path=$ARGV[0];
  my @parts=grep { length($_) } split m{/},$path;
  my $current="/";
  for my $part (@parts) {
    opendir my $dh,$current or exit 2;
    my $exact=0;
    while (defined(my $entry=readdir $dh)) {
      $exact++ if $entry eq $part;
    }
    closedir $dh or exit 2;
    exit 3 unless $exact == 1;
    $current .= "/" unless $current eq "/";
    $current .= $part;
    my @st=lstat($current);
    exit 4 unless @st && !S_ISLNK($st[2]);
  }
  my @final=lstat($path);
  exit 5 unless @final && S_ISREG($final[2]) && $final[3] == 1;
' "$input" ||
  { guard_fail "text input path is aliased or non-regular"; exit 1; }

text_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-text-policy.XXXXXX")
text_tmp=$(CDPATH= cd -- "$text_tmp" && pwd -P)
cleanup_text_policy() {
  rm -f "$text_tmp/input.snapshot" "$text_tmp/scanner.stdout" "$text_tmp/scanner.stderr"
  rmdir "$text_tmp" 2>/dev/null || :
}
trap cleanup_text_policy EXIT
snapshot=$text_tmp/input.snapshot

/usr/bin/perl -e '
  use strict;
  use warnings;
  use Fcntl qw(:DEFAULT :mode);
  my ($source,$target)=@ARGV;
  my @before=lstat($source);
  exit 2 unless @before && S_ISREG($before[2]) && !S_ISLNK($before[2]) && $before[3] == 1;
  sysopen my $in,$source,O_RDONLY|O_NOFOLLOW or exit 3;
  my @opened=stat($in);
  exit 4 unless @opened && S_ISREG($opened[2]) && $opened[3] == 1;
  exit 5 unless $before[0] == $opened[0] && $before[1] == $opened[1];
  sysopen my $out,$target,O_WRONLY|O_CREAT|O_EXCL,0600 or exit 6;
  my ($total,$buffer)=(0,"");
  while (1) {
    my $read=sysread($in,$buffer,65536);
    exit 7 unless defined $read;
    last if $read == 0;
    my $offset=0;
    while ($offset < $read) {
      my $written=syswrite($out,$buffer,$read-$offset,$offset);
      exit 8 unless defined($written) && $written > 0;
      $offset += $written;
    }
    $total += $read;
  }
  my @after=stat($in);
  my @path_after=lstat($source);
  exit 9 unless @after && @path_after;
  for my $index (0,1,2,3,7,9,10) {
    exit 10 unless $opened[$index] == $after[$index];
  }
  exit 11 unless $path_after[0] == $after[0] && $path_after[1] == $after[1] &&
    S_ISREG($path_after[2]) && !S_ISLNK($path_after[2]) && $path_after[3] == 1;
  exit 12 unless $total == $after[7];
  close $out or exit 13;
  close $in or exit 14;
' "$input" "$snapshot" ||
  { guard_fail "text input changed or could not be snapshotted"; exit 1; }

text_bytes=$(/usr/bin/wc -c < "$snapshot" | /usr/bin/tr -d ' ')
[ "$text_bytes" -le "$max_bytes" ] ||
  { guard_fail "text input exceeds the kind limit"; exit 1; }

set +e
/usr/bin/perl -MEncode -MUnicode::Normalize -e '
  use strict;
  use warnings;
  use feature "fc";
  my ($kind,$path)=@ARGV;
  open my $fh,"<:raw",$path or exit 90;
  local $/;
  my $raw=<$fh>;
  close $fh or exit 91;
  my $decode_input=$raw;
  my $text=eval { Encode::decode("UTF-8",$decode_input,Encode::FB_CROAK) };
  exit 2 if $@ || !defined($text);
  exit 2 if NFC($text) ne $text;
  exit 2 if $text =~
    /[\x{FEFF}\x{0000}-\x{0009}\x{000B}-\x{001F}\x{007F}-\x{009F}\x{2028}\x{2029}]/;
  exit 2 if $text =~
    /[\x{FDD0}-\x{FDEF}\p{Noncharacter_Code_Point}\p{Bidi_Control}\p{Default_Ignorable_Code_Point}\p{Cf}\p{Cn}]/;
  if ($kind eq "title") {
    exit 3 if length($raw) == 0 || $raw =~ /\n/ || $text !~ /\P{White_Space}/;
  } else {
    exit 3 if length($raw) < 2 || substr($raw,-1) ne "\n";
    exit 3 if substr($raw,-2,1) eq "\n";
    my $content=substr($text,0,length($text)-1);
    exit 3 if $content !~ /\P{White_Space}/;
  }
  sub confusable_fold {
    my ($value)=@_;
    $value=NFKC($value);
    my %map=(
      "\x{2044}"=>"/", "\x{2215}"=>"/", "\x{29F8}"=>"/",
      "\x{2216}"=>"\\", "\x{29F5}"=>"\\",
      "\x{2024}"=>".", "\x{3002}"=>".", "\x{FE52}"=>".",
      "\x{FE5F}"=>"#", "\x{FE6B}"=>"@", "\x{A789}"=>":",
      "\x{2010}"=>"-", "\x{2011}"=>"-", "\x{2012}"=>"-",
      "\x{2013}"=>"-", "\x{2014}"=>"-", "\x{2015}"=>"-",
      "\x{2212}"=>"-", "\x{FE63}"=>"-"
    );
    $value =~ s/([\x{2044}\x{2215}\x{29F8}\x{2216}\x{29F5}\x{2024}\x{3002}\x{FE52}\x{FE5F}\x{FE6B}\x{A789}\x{2010}-\x{2015}\x{2212}\x{FE63}])/$map{$1}/ge;
    return fc($value);
  }
  sub forbidden {
    my ($value)=@_;
    return 1 if $value =~ /[%\\&<>\@]/;
    return 1 if $value =~ m{(?:\b(?:https?|ftp|git|ssh|mailto|data|file):|://|www\.)}i;
    return 1 if $value =~
      m{\b(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}(?:\b|/)}i;
    return 1 if $value =~ /\b\d{1,3}(?:\.\d{1,3}){3}\b/;
    return 1 if $value =~ /!?\[[^\]\n]*\]\s*(?:\([^\)\n]*\)|\[[^\]\n]*\])/;
    return 1 if $value =~ /^\s*\[[^\]\n]+\]\s*:/m;
    return 1 if $value =~ /\#\d+/;
    return 1 if $value =~ /\bgh-\d+\b/i;
    return 1 if $value =~
      m{\b[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\#\d+\b};
    return 1 if $value =~
      /(?<![A-Fa-f0-9])[A-Fa-f0-9]{7,40}(?![A-Fa-f0-9])/;
    return 1 if $value =~
      /\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b[^\n]{0,64}(?:\#\d+|\bgh-\d+\b|[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\#\d+)/i;
    return 1 if $value =~ /^\s*[-*+]\s+\[[ xX]\]/m;
    return 0;
  }
  sub scanner_secret_assignment {
    my ($value)=@_;
    return $value =~ /(?:api[_-]?key|secret|token)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9_+\/=-]{16,}/i;
  }
  # Direct one-code-point ASCII targets from Unicode 17.0.0 UTS #39,
  # confusables.txt dated 2025-07-22 with approved SHA-256
  # 091c7f82fc39ef208faf8f94d29c244de99254675e09de163160c810d13ef22a.
  # This closed table is used only by the three fixed-key comparisons.
  my %keyword_skeleton_source_sets=(
    "a" =>
      "237A FF41 1D41A 1D44E 1D482 1D4B6 1D4EA 1D51E 1D552 1D586 " .
      "1D5BA 1D5EE 1D622 1D656 1D68A 0251 03B1 1D6C2 1D6FC 1D736 " .
      "1D770 1D7AA 0430 FF21 1CCD6 1D400 1D434 1D468 1D49C 1D4D0 " .
      "1D504 1D538 1D56C 1D5A0 1D5D4 1D608 1D63C 1D670 0391 1D6A8 " .
      "1D6E2 1D71C 1D756 1D790 0410 13AA 15C5 A4EE 16F40 102A0 ",
    "p" =>
      "2374 FF50 1D429 1D45D 1D491 1D4C5 1D4F9 1D52D 1D561 1D595 " .
      "1D5C9 1D5FD 1D631 1D665 1D699 00FE 01BF 03C1 03F1 1D6D2 " .
      "1D6E0 1D70C 1D71A 1D746 1D754 1D780 1D78E 1D7BA 1D7C8 03F8 " .
      "2CA3 2CCF 0440 FF30 2119 1CCE5 1D40F 1D443 1D477 1D4AB " .
      "1D4DF 1D513 1D57B 1D5AF 1D5E3 1D617 1D64B 1D67F 03A1 1D6B8 " .
      "1D6F2 1D72C 1D766 1D7A0 2CA2 2CCE 0420 13E2 146D A4D1 " .
      "10295 ",
    "i" =>
      "02DB 2373 FF49 2170 2139 2148 1D422 1D456 1D48A 1D4BE " .
      "1D4F2 1D526 1D55A 1D58E 1D5C2 1D5F6 1D62A 1D65E 1D692 0131 " .
      "1D6A4 026A 0269 03B9 1FBE 037A 1D6CA 1D704 1D73E 1D778 " .
      "1D7B2 2C93 0456 A647 0582 AB75 13A5 118C3 ",
    "k" =>
      "1D424 1D458 1D48C 1D4C0 1D4F4 1D528 1D55C 1D590 1D5C4 1D5F8 " .
      "1D62C 1D660 1D694 212A FF2B 1CCE0 1D40A 1D43E 1D472 1D4A6 " .
      "1D4DA 1D50E 1D542 1D576 1D5AA 1D5DE 1D612 1D646 1D67A 039A " .
      "1D6B1 1D6EB 1D725 1D75F 1D799 2C94 041A 13E6 16D5 A4D7 " .
      "10518 ",
    "e" =>
      "212E FF45 212F 2147 1D41E 1D452 1D486 1D4EE 1D522 1D556 " .
      "1D58A 1D5BE 1D5F2 1D626 1D65A 1D68E AB32 0435 04BD 22FF " .
      "FF25 2130 1CCDA 1D404 1D438 1D46C 1D4D4 1D508 1D53C 1D570 " .
      "1D5A4 1D5D8 1D60C 1D640 1D674 0395 1D6AC 1D6E6 1D720 1D75A " .
      "1D794 0415 2D39 13AC A4F0 118A6 118AE 10286 ",
    "y" =>
      "0263 1D8C FF59 1D432 1D466 1D49A 1D4CE 1D502 1D536 1D56A " .
      "1D59E 1D5D2 1D606 1D63A 1D66E 1D6A2 028F 1EFF AB5A 03B3 " .
      "213D 1D6C4 1D6FE 1D738 1D772 1D7AC 2CA9 0443 04AF 10E7 " .
      "118DC FF39 1CCEE 1D418 1D44C 1D480 1D4B4 1D4E8 1D51C 1D550 " .
      "1D584 1D5B8 1D5EC 1D620 1D654 1D688 03A5 03D2 1D6BC 1D6F6 " .
      "1D730 1D76A 1D7A4 2CA8 0423 04AE 13A9 13BD A4EC 16F43 " .
      "118A4 102B2 ",
    "s" =>
      "FF53 1D42C 1D460 1D494 1D4C8 1D4FC 1D530 1D564 1D598 1D5CC " .
      "1D600 1D634 1D668 1D69C A731 01BD 0455 0D1F ABAA 118C1 " .
      "10448 FF33 1CCE8 1D412 1D446 1D47A 1D4AE 1D4E2 1D516 1D54A " .
      "1D57E 1D5B2 1D5E6 1D61A 1D64E 1D682 0405 054F 13D5 13DA " .
      "A4E2 16F3A 10296 10420 ",
    "c" =>
      "FF43 217D 1D41C 1D450 1D484 1D4B8 1D4EC 1D520 1D554 1D588 " .
      "1D5BC 1D5F0 1D624 1D658 1D68C 1D04 03F2 2CA5 0441 1004 " .
      "105A ABAF 1043D 1F74C 118E9 118F2 FF23 216D 2102 212D " .
      "1CCD8 1D402 1D436 1D46A 1D49E 1D4D2 1D56E 1D5A2 1D5D6 1D60A " .
      "1D63E 1D672 03F9 2CA4 0421 13DF A4DA 102A2 10302 10415 " .
      "1051C ",
    "r" =>
      "1D42B 1D45F 1D493 1D4C7 1D4FB 1D52F 1D563 1D597 1D5CB 1D5FF " .
      "1D633 1D667 1D69B AB47 AB48 1D26 2C85 0433 AB81 1D216 " .
      "211B 211C 211D 1CCE7 1D411 1D445 1D479 1D4E1 1D57D 1D5B1 " .
      "1D5E5 1D619 1D64D 1D681 01A6 13A1 13D2 104B4 1587 A4E3 " .
      "16F35 ",
    "t" =>
      "1D42D 1D461 1D495 1D4C9 1D4FD 1D531 1D565 1D599 1D5CD 1D601 " .
      "1D635 1D669 1D69D 22A4 27D9 1F768 FF34 1CCE9 1D413 1D447 " .
      "1D47B 1D4AF 1D4E3 1D517 1D54B 1D57F 1D5B3 1D5E7 1D61B 1D64F " .
      "1D683 03A4 1D6BB 1D6F5 1D72F 1D769 1D7A3 2CA6 0422 13A2 " .
      "A4D4 16F0A 118BC 10297 102B1 10315 ",
    "o" =>
      "0C02 0C82 0D02 0D82 0966 09E6 0A66 0AE6 0B66 0BE6 " .
      "0C66 0D66 0E50 0ED0 1040 17E0 114D0 0665 06F5 FF4F " .
      "2134 1D428 1D45C 1D490 1D4F8 1D52C 1D560 1D594 1D5C8 1D5FC " .
      "1D630 1D664 1D698 1D0F 1D11 AB3D 03BF 1D6D0 1D70A 1D744 " .
      "1D77E 1D7B8 03C3 1D6D4 1D70E 1D748 1D782 1D7BC 2C9F 03ED " .
      "043E 10FF 0585 05E1 0647 1EE24 1EE64 1EE84 FEEB FEEC " .
      "FEEA FEE9 06BE FBAC FBAD FBAB FBAA 06C1 FBA8 FBA9 " .
      "FBA7 FBA6 06D5 0D20 101D 104EA 118C8 118D7 1042C 0030 " .
      "07C0 0CE6 3007 118E0 1CCF0 1D7CE 1D7D8 1D7E2 1D7EC 1D7F6 " .
      "1FBF0 FF2F 1CCE4 1D40E 1D442 1D476 1D4AA 1D4DE 1D512 1D546 " .
      "1D57A 1D5AE 1D5E2 1D616 1D64A 1D67E 039F 1D6B6 1D6F0 1D72A " .
      "1D764 1D79E 2C9E 041E 0555 2D54 12D0 0B20 104C2 A4F3 " .
      "118B5 10292 102AB 10404 10516 11DE0 ",
    "n" =>
      "1D427 1D45B 1D48F 1D4C3 1D4F7 1D52B 1D55F 1D593 1D5C7 1D5FB " .
      "1D62F 1D663 1D697 0578 057C FF2E 2115 1CCE3 1D40D 1D441 " .
      "1D475 1D4A9 1D4DD 1D511 1D579 1D5AD 1D5E1 1D615 1D649 1D67D " .
      "039D 1D6B4 1D6EE 1D728 1D762 1D79C 2C9A A4E0 10513 "
  );
  my %keyword_skeleton_direct_map;
  my %keyword_skeleton_map;
  my %keyword_sigma_overrides;
  for my $target (keys %keyword_skeleton_source_sets) {
    for my $source (split " ",$keyword_skeleton_source_sets{$target}) {
      my $character=chr hex $source;
      $keyword_skeleton_direct_map{$character}=$target;
      $keyword_skeleton_map{$character}=$target;
      if ($target eq "o") {
        my $decomposed=fc(NFKD($character));
        $decomposed =~ s/\p{M}//g;
        if ($decomposed eq "\x{03C3}" ||
            $decomposed eq "\x{03C2}") {
          $keyword_sigma_overrides{$character}=1;
        }
      }
    }
  }
  for my $source (keys %keyword_sigma_overrides) {
    $keyword_skeleton_map{$source}="s";
  }
  my %keyword_threat_specific_map=(
    "\x{0138}"=>"k", "\x{A793}"=>"c",
    "\x{03B1}"=>"a", "\x{0430}"=>"a",
    "\x{03C1}"=>"p", "\x{0440}"=>"p",
    "\x{03B9}"=>"i", "\x{0456}"=>"i", "\x{04CF}"=>"i",
    "\x{03BA}"=>"k", "\x{03F0}"=>"k", "\x{043A}"=>"k",
    "\x{03B5}"=>"e", "\x{0435}"=>"e",
    "\x{0454}"=>"e", "\x{04BD}"=>"e",
    "\x{03B3}"=>"y", "\x{0443}"=>"y",
    "\x{03C2}"=>"s", "\x{03C3}"=>"s", "\x{0455}"=>"s",
    "\x{03F2}"=>"c", "\x{0441}"=>"c",
    "\x{0433}"=>"r",
    "\x{03C4}"=>"t", "\x{0442}"=>"t",
    "\x{03BF}"=>"o", "\x{043E}"=>"o",
    "\x{03BD}"=>"n", "\x{03B7}"=>"n",
    "\x{043D}"=>"n", "\x{043F}"=>"n"
  );
  for my $source (keys %keyword_threat_specific_map) {
    $keyword_skeleton_map{$source}=$keyword_threat_specific_map{$source};
  }
  sub map_keyword_skeleton_units {
    my ($value)=@_;
    return join "", map {
      exists $keyword_skeleton_map{$_} ? $keyword_skeleton_map{$_} : $_
    } split //,$value;
  }
  sub known_keyword_skeleton {
    my ($identifier)=@_;
    my $skeleton=map_keyword_skeleton_units($identifier);
    $skeleton=NFKD($skeleton);
    $skeleton =~ s/\p{M}//g;
    $skeleton=map_keyword_skeleton_units(fc($skeleton));
    $skeleton =~ s/[\p{Han}\p{Hiragana}\p{Katakana}]//g;
    return $skeleton;
  }
  sub keyword_sigma_matches_o {
    my ($character)=@_;
    return 1 if exists $keyword_sigma_overrides{$character};
    return 0 if exists $keyword_skeleton_direct_map{$character};
    my $decomposed=fc(NFKD($character));
    $decomposed =~ s/\p{M}//g;
    return $decomposed eq "\x{03C3}" ||
      $decomposed eq "\x{03C2}";
  }
  sub keyword_unit_matches {
    my ($character,$unit,$expected)=@_;
    return 1 if $unit eq $expected;
    return
      $expected eq "o" &&
      $unit eq "s" &&
      keyword_sigma_matches_o($character);
  }
  my @known_keyword_patterns=("apikey","secret","token");
  sub keyword_separator_category {
    my ($character)=@_;
    return 1 if $character eq "\x{2800}";
    return 1 if $character =~
      /[\p{White_Space}\p{P}\p{S}\p{Lm}]/;
    return $character =~ /[\p{Han}\p{Hiragana}\p{Katakana}]/;
  }
  sub consumed_keyword_progress {
    my ($character,$unit,$pattern,$progress,$allow_restart)=@_;
    my $next=0;
    if ($allow_restart &&
        keyword_unit_matches($character,$unit,substr($pattern,0,1))) {
      $next |= 1 << 1;
    }
    for my $prefix_length (1..(length($pattern)-1)) {
      next unless $progress & (1 << $prefix_length);
      my $expected=substr($pattern,$prefix_length,1);
      if (keyword_unit_matches($character,$unit,$expected)) {
        $next |= 1 << ($prefix_length+1);
      }
    }
    return $next;
  }
  sub consume_keyword_character {
    my ($character,$progress,$allow_restart)=@_;
    my @consumed=@{$progress};
    for my $unit (split //,known_keyword_skeleton($character)) {
      for my $index (0..$#known_keyword_patterns) {
        my $pattern=$known_keyword_patterns[$index];
        my $next=consumed_keyword_progress(
          $character,$unit,$pattern,$consumed[$index],$allow_restart
        );
        return (1,@consumed) if $next & (1 << length($pattern));
        $consumed[$index]=$next;
      }
    }
    return (0,@consumed);
  }
  sub advance_known_keyword_matcher {
    my ($character,$progress)=@_;
    my @prior=@{$progress};
    my ($completed,@consumed)=
      consume_keyword_character($character,$progress,1);
    return 1 if $completed;
    for my $index (0..$#known_keyword_patterns) {
      $progress->[$index]=keyword_separator_category($character)
        ? $prior[$index] | $consumed[$index]
        : $consumed[$index];
    }
    return 0;
  }
  sub advance_pending_keyword_matcher {
    my ($character,$progress)=@_;
    my @prior=@{$progress};
    my ($completed,@consumed)=
      consume_keyword_character($character,$progress,0);
    return 2 if $completed;
    my $active=0;
    for my $index (0..$#known_keyword_patterns) {
      $progress->[$index]=keyword_separator_category($character)
        ? $prior[$index] | $consumed[$index]
        : $consumed[$index];
      $active=1 if $progress->[$index] != 0;
    }
    return $active ? 1 : -1;
  }
  sub identifier_evidence {
    my ($identifier)=@_;
    my $keyword_skeleton=known_keyword_skeleton($identifier);
    return 1 if $keyword_skeleton =~
      /\A(?:api[_-]?key|secret|token)\z/i;
    return 0 unless $identifier =~ /[A-Za-z]/;
    my $non_japanese=$identifier;
    $non_japanese =~ s/[\p{Han}\p{Hiragana}\p{Katakana}]//g;
    return $non_japanese =~ /[^\x00-\x7F]/;
  }
  sub assignment_delimiter {
    my ($character)=@_;
    if (ord($character) < 128) {
      return $character =~ /[[:punct:]]/ && $character ne ".";
    }
    my $folded_character=confusable_fold($character);
    return 0 if $folded_character eq ".";
    return 1 if $character =~ /[\p{P}\p{S}\p{Lm}]/;
    return $folded_character eq ":" || $folded_character eq "=";
  }
  sub identifier_character {
    my ($character)=@_;
    return
      $character =~ /[\p{L}\p{M}\p{N}\p{Pc}_-]/ &&
      $character !~ /\p{Lm}/;
  }
  sub ambiguous_secret_assignment {
    my ($value)=@_;
    my $state=0;
    my $identifier="";
    my $candidate_length=0;
    my @keyword_progress=(0,0,0);
    my $period_line_break=0;
    my $period_identifier_length=0;
    my $period_known_keyword=0;
    my $period_candidate_length=0;
    for my $character (split //,$value) {
      if ($state == 2) {
        if ($character =~ /[\p{L}\p{M}\p{N}_+\/=-]/) {
          $candidate_length++;
          return 1 if $candidate_length >= 16;
        } else {
          $candidate_length=0;
        }
        next;
      }
      if ($state == 4) {
        my $ordinary_period=confusable_fold($character) eq ".";
        if ($ordinary_period) {
          $state=3;
          $period_line_break=0;
          $period_identifier_length=0;
          $period_known_keyword=0;
          $period_candidate_length=0;
          @keyword_progress=(0,0,0);
        } elsif (identifier_character($character)) {
          $state=1;
        } elsif (assignment_delimiter($character)) {
          $state=2;
          $candidate_length=0;
        } else {
          $state=1;
        }
        next;
      }
      if ($state == 5) {
        my $pending_result=
          advance_pending_keyword_matcher($character,\@keyword_progress);
        if ($pending_result == 2) {
          $state=3;
          $period_line_break=0;
          $period_identifier_length=0;
          $period_known_keyword=1;
          $period_candidate_length=0;
          @keyword_progress=(0,0,0);
          next;
        }
        next if $pending_result >= 0;
        $state=0;
        $identifier="";
        @keyword_progress=(0,0,0);
      }
      if ($state == 3) {
        my $ordinary_period=confusable_fold($character) eq ".";
        if ($ordinary_period) {
          $period_candidate_length=0;
          next;
        }
        if ($character eq "\n") {
          $period_line_break=$period_known_keyword ? 0 : 1;
          $period_identifier_length=0;
          $period_candidate_length=0;
          next;
        }
        if (!$period_line_break &&
            $character =~ /[\p{L}\p{M}\p{N}_+\/=-]/) {
          $period_candidate_length++;
          return 1 if $period_candidate_length >= 16;
        } else {
          $period_candidate_length=0;
        }
        if (advance_known_keyword_matcher($character,\@keyword_progress)) {
          $period_known_keyword=1;
          $period_line_break=0;
          $period_identifier_length=0;
          $period_candidate_length=0;
          @keyword_progress=(0,0,0);
          next;
        }
        if (identifier_character($character)) {
          $period_identifier_length++ if $period_identifier_length < 2;
          next;
        }
        if (assignment_delimiter($character)) {
          if ($period_line_break && $period_identifier_length >= 2 &&
              !$period_known_keyword &&
              confusable_fold($character) eq ":") {
            $identifier="";
            if (grep { $_ > 0 } @keyword_progress) {
              $state=5;
            } else {
              $state=0;
              @keyword_progress=(0,0,0);
            }
            next;
          }
          $state=2;
          $candidate_length=0;
        }
        next;
      }
      if ($state == 1) {
        my $ordinary_period=confusable_fold($character) eq ".";
        if ($ordinary_period) {
          $state=3;
          $period_line_break=0;
          $period_identifier_length=0;
          $period_known_keyword=0;
          $period_candidate_length=0;
          @keyword_progress=(0,0,0);
        } elsif (assignment_delimiter($character)) {
          $state=2;
          $candidate_length=0;
        }
        next;
      }
      if (advance_known_keyword_matcher($character,\@keyword_progress)) {
        $state=4;
        $identifier="";
        next;
      }
      if (identifier_character($character)) {
        $identifier .= $character;
        next;
      }
      if (length($identifier) > 0) {
        my $ordinary_period=confusable_fold($character) eq ".";
        if (identifier_evidence($identifier)) {
          $state=$ordinary_period ? 3 : 1;
          if ($ordinary_period) {
            $period_line_break=0;
            $period_identifier_length=0;
            $period_known_keyword=0;
            $period_candidate_length=0;
            @keyword_progress=(0,0,0);
          }
        }
        $identifier="";
      }
      if ($state == 1 && assignment_delimiter($character)) {
        $state=2;
        $candidate_length=0;
      }
    }
    return 0;
  }
  my $folded=confusable_fold($text);
  exit 4 if scanner_secret_assignment($folded);
  exit 4 if ambiguous_secret_assignment($text);
  exit 4 if forbidden($text);
  exit 4 if forbidden($folded);
' "$kind" "$snapshot"
text_policy_rc=$?
set -e
if [ "$text_policy_rc" -ne 0 ]; then
  guard_fail "text representation or side-effect policy denied"
  exit 1
fi

if ! "$GUARD_DIR/scan.sh" --exact-stdin "$snapshot" \
  > "$text_tmp/scanner.stdout" 2> "$text_tmp/scanner.stderr"; then
  guard_fail "secret scanner denied text"
  exit 1
fi
[ ! -s "$text_tmp/scanner.stdout" ] ||
  { guard_fail "secret scanner emitted unexpected output"; exit 1; }

scanner_policy_sha256=$("$GUARD_DIR/scan.sh" --policy-digest 2>/dev/null) ||
  { guard_fail "scanner policy digest is unavailable"; exit 1; }
LC_ALL=C /usr/bin/printf '%s\n' "$scanner_policy_sha256" |
  /usr/bin/grep -E '^[a-f0-9]{64}$' >/dev/null ||
  { guard_fail "scanner policy digest is malformed"; exit 1; }
gitleaks_version=$(
  /opt/homebrew/Cellar/gitleaks/8.30.1/bin/gitleaks version 2>/dev/null
) || { guard_fail "gitleaks version is unavailable"; exit 1; }
[ "$gitleaks_version" = "8.30.1" ] ||
  { guard_fail "gitleaks version mismatch"; exit 1; }

/usr/bin/jq -cn \
  --arg mode "$GUARD_MODE" \
  --arg kind "$kind" \
  --arg accepted_sha256 "$(guard_sha256 "$snapshot")" \
  --arg scanner_policy_sha256 "$scanner_policy_sha256" \
  --arg gitleaks_sha256 \
    "$(guard_sha256 /opt/homebrew/Cellar/gitleaks/8.30.1/bin/gitleaks)" \
  --argjson bytes "$text_bytes" '
  {
    schema:"alpha-nightshift/text-policy-evidence/v1",
    mode:$mode,
    write_mode:false,
    verdict:"PASS_LOCAL_ONLY",
    kind:$kind,
    bytes:$bytes,
    accepted_sha256:$accepted_sha256,
    scanner_policy_sha256:$scanner_policy_sha256,
    gitleaks_version:"8.30.1",
    gitleaks_sha256:$gitleaks_sha256
  }'
