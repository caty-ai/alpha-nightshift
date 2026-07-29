#!/bin/bash
set -euo pipefail

GUARD_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
# shellcheck source=guard/common.sh
. "$GUARD_DIR/common.sh"

scanner_config() {
  /usr/bin/printf '%s\n' \
    'title = "alpha-nightshift Phase 1a exact-stdin policy"' \
    '' \
    '[[rules]]' \
    'id = "nightshift-generic-api-key"' \
    'description = "Generic API key assignment"' \
    "regex = '''(?i)(?:api[_-]?key|secret|token)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9_+/=-]{16,}'''" \
    'keywords = ["api", "secret", "token"]' \
    '' \
    '[[rules]]' \
    'id = "nightshift-github-token"' \
    'description = "GitHub token shape"' \
    "regex = '''gh[pousr]_[A-Za-z0-9]{20,}'''" \
    'keywords = ["ghp_", "gho_", "ghu_", "ghs_", "ghr_"]'
}

scanner_policy_digest() {
  scanner_config | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

if [ "$#" -eq 1 ] && [ "$1" = "--policy-digest" ]; then
  scanner_policy_digest
  exit 0
fi

repo=
base=
candidate=
manifest=
repo_id=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -ge 2 ] || { guard_fail "missing repository path"; exit 1; }
      repo=$2
      shift 2
      ;;
    --base)
      [ "$#" -ge 2 ] || { guard_fail "missing base object id"; exit 1; }
      base=$2
      shift 2
      ;;
    --candidate)
      [ "$#" -ge 2 ] || { guard_fail "missing candidate object id"; exit 1; }
      candidate=$2
      shift 2
      ;;
    --manifest)
      [ "$#" -ge 2 ] || { guard_fail "missing activation manifest"; exit 1; }
      manifest=$2
      shift 2
      ;;
    --repo-id)
      [ "$#" -ge 2 ] || { guard_fail "missing repository id"; exit 1; }
      repo_id=$2
      shift 2
      ;;
    *)
      guard_fail "unknown scanner field"
      exit 1
      ;;
  esac
done

[ -n "$repo" ] && [ -n "$base" ] && [ -n "$candidate" ] &&
  [ -n "$manifest" ] && [ -n "$repo_id" ] ||
  { guard_fail "scan requires repo, repo-id, base, candidate, and manifest"; exit 1; }
guard_validate_absolute_path "$repo" dir
guard_validate_absolute_path "$manifest" file
guard_validate_repo_id "$repo_id"
guard_validate_sha "$base"
guard_validate_sha "$candidate"
guard_json_no_duplicate_paths "$manifest"
/usr/bin/jq -e '
  .schema == "alpha-nightshift/guard-activation/v1" and
  .mode == "LOCAL_ONLY_REMOTE_UNPROVEN" and
  (.night_bot.name | type == "string" and length > 0) and
  (.night_bot.email | type == "string" and length > 2)
' "$manifest" >/dev/null ||
  { guard_fail "scanner manifest is malformed"; exit 1; }
bot_name=$(/usr/bin/jq -r '.night_bot.name' "$manifest")
bot_email=$(/usr/bin/jq -r '.night_bot.email' "$manifest")
guard_has_control "$bot_name" && { guard_fail "night-bot name contains controls"; exit 1; }
guard_has_control "$bot_email" && { guard_fail "night-bot email contains controls"; exit 1; }
LC_ALL=C /usr/bin/printf '%s\n' "$bot_email" |
  /usr/bin/grep -E '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$' >/dev/null ||
  { guard_fail "night-bot email is invalid"; exit 1; }

if [ -d "$repo/.git" ]; then
  git_dir=$repo/.git
elif [ -f "$repo/.git" ]; then
  gitdir_line=$(/usr/bin/sed -n '1p' "$repo/.git")
  case "$gitdir_line" in
    "gitdir: "/*) git_dir=${gitdir_line#gitdir: } ;;
    *) guard_fail "linked-worktree gitdir is not an absolute canonical path"; exit 1 ;;
  esac
else
  guard_fail "repository has no explicit Git directory"
  exit 1
fi
guard_validate_absolute_path "$git_dir" dir

common_dir=$git_dir
if [ -f "$git_dir/commondir" ]; then
  common_hint=$(/usr/bin/sed -n '1p' "$git_dir/commondir")
  case "$common_hint" in
    /*) common_dir=$common_hint ;;
    *)
      common_dir=$(CDPATH= cd -- "$git_dir/$common_hint" 2>/dev/null && pwd -P) ||
        { guard_fail "Git common directory is ambiguous"; exit 1; }
      ;;
  esac
fi
guard_validate_absolute_path "$common_dir" dir

for forbidden_state in \
  "$git_dir/shallow" \
  "$common_dir/shallow" \
  "$common_dir/info/grafts" \
  "$common_dir/objects/info/alternates"; do
  if [ -s "$forbidden_state" ]; then
    guard_fail "shallow, graft, or alternate object state is forbidden"
    exit 1
  fi
done
if [ -d "$common_dir/refs/replace" ] &&
  /usr/bin/find "$common_dir/refs/replace" -type f -print -quit | /usr/bin/grep . >/dev/null; then
  guard_fail "replace refs are forbidden"
  exit 1
fi
case "${GIT_ALTERNATE_OBJECT_DIRECTORIES-}${GIT_OBJECT_DIRECTORY-}${GIT_REPLACE_REF_BASE-}" in
  '') ;;
  *) guard_fail "inherited Git object indirection is forbidden"; exit 1 ;;
esac

if [ -f "$common_dir/config" ]; then
  unsafe_config=$(guard_hardened_git "$git_dir" config --file "$common_dir/config" \
    --no-includes --name-only --list 2>/dev/null |
    LC_ALL=C /usr/bin/grep -E \
      '^(include|includeif|credential|http|url|core\.hooksPath|core\.sshCommand|core\.fsmonitor|filter|diff\..*\.textconv)' ||
    :)
  if [ -n "$unsafe_config" ]; then
    guard_fail "candidate Git configuration contains a forbidden mechanism"
    exit 1
  fi
fi

scan_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-object-scan.XXXXXX")
cleanup() {
  rm -rf "$scan_tmp"
}
trap cleanup EXIT
config_path=$scan_tmp/gitleaks.toml
ignore_path=$scan_tmp/empty.ignore
scanner_config > "$config_path"
: > "$ignore_path"

if [ "$(/opt/homebrew/Cellar/gitleaks/8.30.1/bin/gitleaks version 2>/dev/null)" != "8.30.1" ]; then
  guard_fail "gitleaks version mismatch"
  exit 1
fi

for objectish in "$base" "$candidate"; do
  resolved=$(guard_hardened_git "$git_dir" rev-parse --verify "$objectish^{commit}" 2>/dev/null) ||
    { guard_fail "base or candidate is not an exact available commit"; exit 1; }
  [ "$resolved" = "$objectish" ] ||
    { guard_fail "base or candidate commit is ambiguous"; exit 1; }
done
guard_hardened_git "$git_dir" fsck --strict --no-dangling "$base" "$candidate" \
  >/dev/null 2>&1 ||
  { guard_fail "Git object integrity check failed"; exit 1; }
guard_hardened_git "$git_dir" merge-base --is-ancestor "$base" "$candidate" \
  >/dev/null 2>&1 ||
  { guard_fail "candidate ancestry is ambiguous or non-descendant"; exit 1; }

changed_paths=$scan_tmp/changed-paths
guard_hardened_git "$git_dir" diff-tree -r --no-commit-id --name-only -z \
  "$base" "$candidate" > "$changed_paths" ||
  { guard_fail "candidate path inventory failed"; exit 1; }
set +e
/usr/bin/perl -MEncode -MUnicode::Normalize -0ne '
  use strict;
  use warnings;
  my $raw = $_;
  $raw =~ s/\0\z//;
  my $name = eval { Encode::decode("UTF-8", $raw, Encode::FB_CROAK) };
  exit 2 if $@ || !defined($name) || NFC($name) ne $name;
  exit 2 if $name =~ /[\x00-\x1f\x7f-\x9f]/;
  my $fold = lc NFC($name);
  exit 3 if $fold =~ m{(?:^|/)(?:guard|config/guard-activation[^/]*|\.gitleaks(?:\.toml|ignore)?|\.gitattributes|\.gitmodules|tests/test_guard_[^/]*\.sh)(?:/|$)};
' "$changed_paths"
path_rc=$?
set -e
case "$path_rc" in
  0) ;;
  3) guard_fail "candidate changes guard or scanner policy"; exit 1 ;;
  *) guard_fail "candidate path is not canonical UTF-8"; exit 1 ;;
esac

base_ids=$scan_tmp/base.ids
candidate_ids=$scan_tmp/candidate.ids
outgoing_ids=$scan_tmp/outgoing.ids
resident_base_ids=$scan_tmp/resident-base.ids
guard_hardened_git "$git_dir" rev-list --objects --no-object-names "$base" |
  LC_ALL=C /usr/bin/sort -u > "$base_ids"
guard_hardened_git "$git_dir" rev-list --objects --no-object-names "$candidate" |
  LC_ALL=C /usr/bin/sort -u > "$candidate_ids"
LC_ALL=C /usr/bin/comm -23 "$candidate_ids" "$base_ids" > "$outgoing_ids"
LC_ALL=C /usr/bin/comm -12 "$candidate_ids" "$base_ids" > "$resident_base_ids"

set_contains() {
  set_oid=$1
  set_file=$2
  LC_ALL=C /usr/bin/grep -F -x "$set_oid" "$set_file" >/dev/null 2>&1
}

while IFS= read -r oid; do
  [ -n "$oid" ] || continue
  if set_contains "$oid" "$base_ids"; then
    set_contains "$oid" "$resident_base_ids" &&
      ! set_contains "$oid" "$outgoing_ids" ||
      { guard_fail "resident-base membership check failed"; exit 1; }
  else
    set_contains "$oid" "$outgoing_ids" &&
      ! set_contains "$oid" "$resident_base_ids" ||
      { guard_fail "outgoing membership check failed"; exit 1; }
  fi
done < "$candidate_ids"
while IFS= read -r oid; do
  [ -n "$oid" ] || continue
  set_contains "$oid" "$candidate_ids" &&
    ! set_contains "$oid" "$base_ids" &&
    ! set_contains "$oid" "$resident_base_ids" ||
    { guard_fail "outgoing set contains an invalid member"; exit 1; }
done < "$outgoing_ids"
while IFS= read -r oid; do
  [ -n "$oid" ] || continue
  set_contains "$oid" "$candidate_ids" &&
    set_contains "$oid" "$base_ids" &&
    ! set_contains "$oid" "$outgoing_ids" ||
    { guard_fail "resident-base set contains an invalid member"; exit 1; }
done < "$resident_base_ids"

object_format=$(guard_hardened_git "$git_dir" rev-parse --show-object-format 2>/dev/null) ||
  { guard_fail "object format is unavailable"; exit 1; }
case "$object_format" in
  sha1) oid_width=20 ;;
  sha256) oid_width=32 ;;
  *) guard_fail "unsupported Git object format"; exit 1 ;;
esac

for inventory in "$base_ids" "$candidate_ids"; do
  while IFS= read -r oid; do
    [ -n "$oid" ] || continue
    object_type=$(guard_hardened_git "$git_dir" cat-file -t "$oid" 2>/dev/null) ||
      { guard_fail "object type lookup failed"; exit 1; }
    case "$object_type" in
      commit|tree|blob) ;;
      *) guard_fail "unexpected Git object type"; exit 1 ;;
    esac
  done < "$inventory"
done

validate_payload() {
  payload_type=$1
  payload_path=$2
  /usr/bin/perl -MEncode -MUnicode::Normalize -e '
    use strict;
    use warnings;
    my ($type,$path,$oid_width,$bot_name,$bot_email)=@ARGV;
    open my $fh, "<:raw", $path or exit 90;
    local $/;
    my $raw=<$fh>;
    close $fh or exit 91;
    sub text {
      my ($bytes,$placement)=@_;
      return undef if $bytes =~ /^\xEF\xBB\xBF|^\xFF\xFE|^\xFE\xFF|\x00/;
      return undef if $bytes =~
        /(?:\x00[\x01-\x7f]){2}|(?:[\x01-\x7f]\x00){2}|(?:\x00\x00\x00[\x01-\x7f])|(?:[\x01-\x7f]\x00\x00\x00)/;
      my $s=eval { Encode::decode("UTF-8",$bytes,Encode::FB_CROAK) };
      return undef if $@ || !defined $s || NFC($s) ne $s;
      return undef if $s =~ /[\x{7f}-\x{9f}\x{fdd0}-\x{fdef}\p{Noncharacter_Code_Point}\p{Bidi_Control}]/;
      return undef if $s =~ /[\x00-\x08\x0b\x0c\x0e-\x1f]/;
      return undef if !$placement && $s =~ /[\x09\x0a\x0d]/;
      return undef if $s =~ /\x0d/;
      return $s;
    }
    if ($type eq "blob") {
      exit 2 unless defined text($raw,1);
      exit 2 if $raw =~ /\+[A-Za-z0-9\/]{2,}-/;
      exit 2 if $raw =~ /^(?:\x1f\x8b|PK\x03\x04|%PDF|\x7fELF|\x00asm|\x89PNG|\xff\xd8\xff|GIF8|OggS|\x1a\x45\xdf\xa3|BZh|\xfd7zXZ\x00|7z\xbc\xaf\x27\x1c|\x28\xb5\x2f\xfd|Rar!)/s;
      exit 2 if length($raw) > 262 && substr($raw,257,5) eq "ustar";
      exit 0;
    }
    if ($type eq "commit") {
      my $s=text($raw,1);
      exit 3 unless defined $s;
      my ($headers,$message)=split(/\n\n/,$s,2);
      exit 3 unless defined $message;
      my @h=split(/\n/,$headers,-1);
      exit 3 unless @h >= 3 && $h[0] =~ /^tree [a-f0-9]+$/;
      my $phase="parent";
      my ($author,$committer)=(0,0);
      for my $i (1..$#h) {
        my $line=$h[$i];
        exit 3 if $line =~ /^\s/;
        if ($line =~ /^parent [a-f0-9]+$/ && !$author) { next; }
        if ($line =~ /^author (.+) ([0-9]+ [+-][0-9]{4})$/ && !$author) {
          exit 4 unless $1 eq "$bot_name <$bot_email>";
          $author=1; next;
        }
        if ($line =~ /^committer (.+) ([0-9]+ [+-][0-9]{4})$/ && $author && !$committer) {
          exit 4 unless $1 eq "$bot_name <$bot_email>";
          $committer=1; next;
        }
        exit 3;
      }
      exit 3 unless $author && $committer;
      exit 5 if $message =~ m{https?://|www\.|<[^>]+>|(?:^|[^\w])\@\w|(?:^|[^\w])\#\d|GH-\d|[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\#\d}i;
      exit 5 if $message =~ /\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+\S+/i;
      exit 5 if $message =~ /(?:^|[^a-f0-9])[a-f0-9]{7,40}(?:[^a-f0-9]|$)/i;
      exit 5 if $message =~ /^\s*[-*]\s+\[[ xX]\]/m;
      exit 0;
    }
    if ($type eq "tree") {
      my $pos=0;
      my $last="";
      while ($pos < length($raw)) {
        my $space=index($raw," ",$pos);
        exit 6 if $space < 0;
        my $mode=substr($raw,$pos,$space-$pos);
        exit 6 unless $mode =~ /^(?:100644|100755|120000|40000)$/;
        my $nul=index($raw,"\0",$space+1);
        exit 6 if $nul < 0;
        my $name=substr($raw,$space+1,$nul-$space-1);
        my $decoded=text($name,0);
        exit 6 unless defined $decoded && length($name)>0;
        exit 6 if $decoded =~ m{/|^\.$|^\.\.$};
        my $sort_key=$name . ($mode eq "40000" ? "/" : "");
        exit 6 if $last ne "" && $last ge $sort_key;
        $last=$sort_key;
        $pos=$nul+1+$oid_width;
        exit 6 if $pos > length($raw);
      }
      exit 6 unless $pos == length($raw);
      exit 0;
    }
    exit 99;
  ' "$payload_type" "$payload_path" "$oid_width" "$bot_name" "$bot_email"
}

scan_payload() {
  scan_input=$1
  scan_expect=$2
  scan_label=$3
  report=$scan_tmp/report-"$scan_label".json
  diagnostics=$scan_tmp/diagnostics-"$scan_label".log
  scan_bytes=$(/usr/bin/wc -c < "$scan_input" | /usr/bin/tr -d ' ')
  set +e
  /bin/cat "$scan_input" |
    /opt/homebrew/Cellar/gitleaks/8.30.1/bin/gitleaks stdin \
      --config "$config_path" \
      --gitleaks-ignore-path "$ignore_path" \
      --ignore-gitleaks-allow \
      --max-archive-depth=0 \
      --max-decode-depth=0 \
      --max-target-megabytes=0 \
      --timeout=0 \
      --report-format=json \
      --report-path="$report" \
      --redact=100 \
      --log-level=debug \
      --no-banner \
      --no-color \
      > /dev/null 2> "$diagnostics"
  pipe_status=("${PIPESTATUS[@]}")
  set -e
  [ "${pipe_status[0]}" -eq 0 ] ||
    { guard_fail "scanner feeder short write or broken pipe"; return 1; }
  scanner_rc=${pipe_status[1]}
  [ -f "$report" ] ||
    { guard_fail "scanner report is missing"; return 1; }
  /usr/bin/jq -e 'type == "array"' "$report" >/dev/null 2>&1 ||
    { guard_fail "scanner report is malformed"; return 1; }
  if LC_ALL=C /usr/bin/grep -E -i \
    'skipping binary|skipped|truncat|timed? out|zero bytes|0 bytes scanned|mime' \
    "$diagnostics" >/dev/null 2>&1; then
    guard_fail "scanner diagnostics are ambiguous or indicate a skip"
    return 1
  fi
  if [ "$scan_bytes" -eq 0 ]; then
    LC_ALL=C /usr/bin/grep -E 'scanned ~0 bytes \(0\)' \
      "$diagnostics" >/dev/null 2>&1 ||
      { guard_fail "scanner-attributed zero-byte count is absent or mismatched"; return 1; }
  else
    /usr/bin/grep -F "($scan_bytes bytes)" "$diagnostics" >/dev/null 2>&1 ||
      { guard_fail "scanner-attributed consumed byte count is absent or mismatched"; return 1; }
  fi
  if [ "$scan_bytes" -gt 0 ] && [ ! -s "$scan_input" ]; then
    guard_fail "non-empty scanner input became empty"
    return 1
  fi
  case "$scan_expect" in
    clean)
      [ "$scanner_rc" -eq 0 ] && /usr/bin/jq -e 'length == 0' "$report" >/dev/null ||
        { guard_fail "secret detector denied an outgoing object"; return 1; }
      ;;
    canary)
      [ "$scanner_rc" -eq 1 ] &&
        /usr/bin/jq -e 'any(.RuleID == "nightshift-generic-api-key")' "$report" >/dev/null ||
        { guard_fail "representation-matched scanner canary was not detected"; return 1; }
      ;;
    *) guard_fail "internal scanner expectation error"; return 1 ;;
  esac
}

make_canary_variant() {
  canary_type=$1
  source_path=$2
  output_path=$3
  canary_token=$4
  case "$canary_type" in
    blob|commit)
      /bin/cp "$source_path" "$output_path"
      /usr/bin/printf '\napi_key=%s\n' "$canary_token" >> "$output_path"
      ;;
    tree)
      /usr/bin/perl -e '
        use strict;
        use warnings;
        my ($source,$output,$oid_width,$token)=@ARGV;
        open my $fh,"<:raw",$source or exit 90;
        local $/;
        my $raw=<$fh>;
        close $fh or exit 91;
        my @entries;
        my $pos=0;
        while ($pos < length($raw)) {
          my $space=index($raw," ",$pos);
          exit 92 if $space < 0;
          my $mode=substr($raw,$pos,$space-$pos);
          my $nul=index($raw,"\0",$space+1);
          exit 92 if $nul < 0;
          my $name=substr($raw,$space+1,$nul-$space-1);
          my $end=$nul+1+$oid_width;
          exit 92 if $end > length($raw);
          push @entries,{
            mode=>$mode,
            name=>$name,
            raw=>substr($raw,$pos,$end-$pos)
          };
          $pos=$end;
        }
        my $canary_name="nightshift-api_key=$token";
        exit 93 if grep { $_->{name} eq $canary_name } @entries;
        push @entries,{
          mode=>"100644",
          name=>$canary_name,
          raw=>"100644 $canary_name\0" . ("A" x $oid_width)
        };
        sub key {
          my ($entry)=@_;
          return $entry->{name} . ($entry->{mode} eq "40000" ? "/" : "");
        }
        @entries=sort { key($a) cmp key($b) } @entries;
        open my $oh,">:raw",$output or exit 94;
        for my $entry (@entries) {
          print {$oh} $entry->{raw} or exit 95;
        }
        close $oh or exit 96;
      ' "$source_path" "$output_path" "$oid_width" "$canary_token"
      ;;
    *) guard_fail "unsupported canary object type"; return 1 ;;
  esac
}

decode_wrapper() {
  wrapper_input=$1
  wrapper_output=$2
  /usr/bin/perl -MEncode -MURI::Escape -MMIME::Base64 -e '
    use strict;
    use warnings;
    my ($in,$out)=@ARGV;
    open my $fh,"<:raw",$in or exit 90; local $/; my $x=<$fh>; close $fh;
    sub canonical_standard_base64 {
      my ($value)=@_;
      return 0 if length($value)<8;
      return 1 if $value =~
        /\A(?:[A-Za-z0-9+\/]{4})*(?:[A-Za-z0-9+\/]{2}==|[A-Za-z0-9+\/]{3}=)?\z/;
      return 0 unless $value =~ /\A[A-Za-z0-9+\/]+\z/;
      my $remainder=length($value)%4;
      return $remainder==2 || $remainder==3;
    }
    sub decode_standard_base64 {
      my ($value)=@_;
      my $repaired=$value;
      if ($repaired !~ /=\z/) {
        my $remainder=length($repaired)%4;
        $repaired .= "=" x (4-$remainder) if $remainder==2 || $remainder==3;
      }
      return decode_base64($repaired);
    }
    sub canonical_base64url {
      my ($value)=@_;
      return 0 if length($value)<8 || $value !~ /[-_]/;
      return 1 if $value =~
        /\A(?:[A-Za-z0-9_-]{4})*(?:[A-Za-z0-9_-]{2}==|[A-Za-z0-9_-]{3}=)?\z/;
      return 0 unless $value =~ /\A[A-Za-z0-9_-]+\z/;
      my $remainder=length($value)%4;
      return $remainder==2 || $remainder==3;
    }
    sub base64_union_alphabet {
      my ($value)=@_;
      return length($value)>=8 && $value =~ /\A[A-Za-z0-9+\/=_-]+\z/;
    }
    sub classify {
      my ($value)=@_;
      if ($value =~ /\A[0-9A-Fa-f]+\z/ && length($value)>=8 && length($value)%2==0) {
        return ("hex",pack("H*",$value));
      }
      if ($value =~ /\A(?:%[0-9A-Fa-f]{2}){4,}\z/) {
        return ("percent",uri_unescape($value));
      }
      if (canonical_standard_base64($value)) {
        return ("base64",decode_standard_base64($value));
      }
      return;
    }
    sub ambiguous_base64 {
      my ($value)=@_;
      return canonical_base64url($value) || base64_union_alphabet($value);
    }
    sub normalized_wrapper_or_ambiguity {
      my ($value)=@_;
      return 1 if $value =~ /\A[0-9A-Fa-f]+\z/ &&
        length($value)>=8 && length($value)%2==0;
      return 1 if $value =~ /\A(?:%[0-9A-Fa-f]{2}){4,}\z/;
      return 1 if canonical_standard_base64($value);
      return 1 if canonical_base64url($value);
      return 1 if base64_union_alphabet($value);
      return 0;
    }
    my ($kind,$decoded)=classify($x);
    exit 12 if !defined($kind) && ambiguous_base64($x);
    if (!defined($kind) && $x =~ /\n\z/ && $x !~ /\r\n\z/ && $x !~ /\n\n\z/) {
      my $without_lf=substr($x,0,length($x)-1);
      ($kind,$decoded)=classify($without_lf);
      exit 12 if !defined($kind) && ambiguous_base64($without_lf);
    }
    if (!defined($kind)) {
      my $unicode=eval { Encode::decode("UTF-8",$x,Encode::FB_CROAK) };
      if (!$@ && defined($unicode)) {
        my $normalized=$unicode;
        $normalized =~
          s/(?:[ \t\n]|\p{Z}|\p{Cf}|\p{Default_Ignorable_Code_Point})//g;
        if ($normalized ne $unicode) {
          my $normalized_bytes=Encode::encode("UTF-8",$normalized);
          exit 12 if normalized_wrapper_or_ambiguity($normalized_bytes);
        }
      }
      exit 10;
    }
    exit 11 if !defined($decoded) || length($decoded)>10485760;
    open my $oh,">:raw",$out or exit 91; print {$oh} $decoded or exit 92; close $oh or exit 93;
    print $kind;
  ' "$wrapper_input" "$wrapper_output"
}

for type_name in commit tree blob; do
  : > "$scan_tmp/outgoing.$type_name.ids"
  : > "$scan_tmp/base.$type_name.ids"
done
base_raw_records=$scan_tmp/base.raw-records
outgoing_raw_records=$scan_tmp/outgoing.raw-records
: > "$base_raw_records"
: > "$outgoing_raw_records"
while IFS= read -r oid; do
  [ -n "$oid" ] || continue
  object_type=$(guard_hardened_git "$git_dir" cat-file -t "$oid")
  /usr/bin/printf '%s\n' "$oid" >> "$scan_tmp/base.$object_type.ids"
  declared_size=$(guard_hardened_git "$git_dir" cat-file -s "$oid")
  raw_path=$scan_tmp/base-"$oid".raw
  guard_hardened_git "$git_dir" cat-file "$object_type" "$oid" > "$raw_path"
  emitted_size=$(/usr/bin/wc -c < "$raw_path" | /usr/bin/tr -d ' ')
  [ "$declared_size" -eq "$emitted_size" ] ||
    { guard_fail "base object size or raw provenance mismatch"; exit 1; }
  raw_digest=$(guard_sha256 "$raw_path")
  [ -n "$raw_digest" ] || { guard_fail "base raw digest failed"; exit 1; }
  /usr/bin/printf '%s %s %s %s\n' \
    "$oid" "$object_type" "$declared_size" "$raw_digest" >> "$base_raw_records"
  rm -f "$raw_path"
done < "$resident_base_ids"
LC_ALL=C /usr/bin/sort -o "$base_raw_records" "$base_raw_records"

scanned_count=0
while IFS= read -r oid; do
  [ -n "$oid" ] || continue
  object_type=$(guard_hardened_git "$git_dir" cat-file -t "$oid")
  /usr/bin/printf '%s\n' "$oid" >> "$scan_tmp/outgoing.$object_type.ids"
  declared_size=$(guard_hardened_git "$git_dir" cat-file -s "$oid")
  raw_path=$scan_tmp/outgoing-"$oid".raw
  guard_hardened_git "$git_dir" cat-file "$object_type" "$oid" > "$raw_path"
  emitted_size=$(/usr/bin/wc -c < "$raw_path" | /usr/bin/tr -d ' ')
  [ "$declared_size" -eq "$emitted_size" ] ||
    { guard_fail "declared, emitted, and feeder byte counts diverge"; exit 1; }

  if ! validate_payload "$object_type" "$raw_path"; then
    guard_fail "outgoing object representation or commit policy denied"
    exit 1
  fi
  mime_type=$(/usr/bin/file -b --mime-type "$raw_path" 2>/dev/null || :)
  if [ "$object_type" != tree ]; then
    case "$mime_type" in
      text/plain|application/json|application/x-empty|inode/x-empty) ;;
      *) guard_fail "outgoing object has unsupported or opaque classification"; exit 1 ;;
    esac
  fi
  scan_payload "$raw_path" clean "$oid-original"

  canary_path=$scan_tmp/canary-"$oid".raw
  canary_suffix=$(LC_ALL=C /usr/bin/printf '%s' "$oid" |
    /usr/bin/tr '0123456789abcdef' 'ghijklmnopqrstuv')
  canary_token="NSCAN${canary_suffix}PHASEONE"
  make_canary_variant "$object_type" "$raw_path" "$canary_path" "$canary_token"
  if ! validate_payload "$object_type" "$canary_path"; then
    guard_fail "canary variant changed the representation decision"
    exit 1
  fi
  scan_payload "$canary_path" canary "$oid-canary"
  rm -f "$canary_path"

  if [ "$object_type" = blob ]; then
    wrapper_source=$raw_path
    wrapper_depth=0
    while [ "$wrapper_depth" -le 2 ]; do
      decoded_path=$scan_tmp/decoded-"$oid"-"$wrapper_depth".raw
      set +e
      wrapper_kind=$(decode_wrapper "$wrapper_source" "$decoded_path")
      wrapper_rc=$?
      set -e
      if [ "$wrapper_rc" -eq 10 ]; then
        rm -f "$decoded_path"
        break
      fi
      [ "$wrapper_rc" -eq 0 ] ||
        { guard_fail "encoded wrapper is ambiguous or exceeds bounds"; exit 1; }
      [ "$wrapper_depth" -lt 2 ] ||
        { guard_fail "encoded wrapper exceeds supported decode depth"; exit 1; }
      [ -n "$wrapper_kind" ] ||
        { guard_fail "encoded wrapper classification failed"; exit 1; }
      validate_payload blob "$decoded_path" ||
        { guard_fail "decoded representation is unsupported"; exit 1; }
      scan_payload "$decoded_path" clean "$oid-decoded-$wrapper_depth"
      decoded_canary=$scan_tmp/decoded-canary-"$oid"-"$wrapper_depth".raw
      make_canary_variant blob "$decoded_path" "$decoded_canary" "$canary_token"
      validate_payload blob "$decoded_canary" ||
        { guard_fail "decoded canary changed representation"; exit 1; }
      scan_payload "$decoded_canary" canary "$oid-decoded-canary-$wrapper_depth"
      rm -f "$decoded_canary"
      wrapper_source=$decoded_path
      wrapper_depth=$((wrapper_depth + 1))
    done
  fi
  raw_digest=$(guard_sha256 "$raw_path")
  [ -n "$raw_digest" ] || { guard_fail "outgoing raw digest failed"; exit 1; }
  /usr/bin/printf '%s %s %s %s\n' \
    "$oid" "$object_type" "$declared_size" "$raw_digest" >> "$outgoing_raw_records"
  rm -f "$raw_path"
  scanned_count=$((scanned_count + 1))
done < "$outgoing_ids"
LC_ALL=C /usr/bin/sort -o "$outgoing_raw_records" "$outgoing_raw_records"

digest_ids() {
  digest_file=$1
  guard_sha256 "$digest_file"
}

base_count=$(/usr/bin/wc -l < "$resident_base_ids" | /usr/bin/tr -d ' ')
outgoing_count=$(/usr/bin/wc -l < "$outgoing_ids" | /usr/bin/tr -d ' ')
resident_count=$(/usr/bin/wc -l < "$candidate_ids" | /usr/bin/tr -d ' ')
[ "$scanned_count" -eq "$outgoing_count" ] ||
  { guard_fail "scanned object set does not equal outgoing set"; exit 1; }

/usr/bin/jq -cn \
  --arg mode "$GUARD_MODE" \
  --arg repo_id "$repo_id" \
  --arg base "$base" \
  --arg candidate "$candidate" \
  --arg git_sha256 "$(guard_sha256 /opt/homebrew/Cellar/git/2.48.1/bin/git)" \
  --arg gitleaks_sha256 "$(guard_sha256 /opt/homebrew/Cellar/gitleaks/8.30.1/bin/gitleaks)" \
  --arg scanner_policy_sha256 "$(scanner_policy_digest)" \
  --arg base_set_sha256 "$(digest_ids "$resident_base_ids")" \
  --arg outgoing_set_sha256 "$(digest_ids "$outgoing_ids")" \
  --arg resident_set_sha256 "$(digest_ids "$candidate_ids")" \
  --arg base_local_raw_sha256 "$(digest_ids "$base_raw_records")" \
  --arg outgoing_local_raw_sha256 "$(digest_ids "$outgoing_raw_records")" \
  --arg base_commit_sha256 "$(digest_ids "$scan_tmp/base.commit.ids")" \
  --arg base_tree_sha256 "$(digest_ids "$scan_tmp/base.tree.ids")" \
  --arg base_blob_sha256 "$(digest_ids "$scan_tmp/base.blob.ids")" \
  --arg outgoing_commit_sha256 "$(digest_ids "$scan_tmp/outgoing.commit.ids")" \
  --arg outgoing_tree_sha256 "$(digest_ids "$scan_tmp/outgoing.tree.ids")" \
  --arg outgoing_blob_sha256 "$(digest_ids "$scan_tmp/outgoing.blob.ids")" \
  --argjson base_count "$base_count" \
  --argjson outgoing_count "$outgoing_count" \
  --argjson resident_count "$resident_count" '
  {
    schema:"alpha-nightshift/object-scan-evidence/v1",
    mode:$mode,
    write_mode:false,
    verdict:"PASS_LOCAL_ONLY",
    evidence_scope:"CALLER_SUPPLIED_LOCAL_BASE_NO_REMOTE_PROOF",
    repo_id:$repo_id,
    base_sha:$base,
    candidate_sha:$candidate,
    counts:{base:$base_count,outgoing:$outgoing_count,resident:$resident_count},
    sets:{
      base_sha256:$base_set_sha256,
      outgoing_sha256:$outgoing_set_sha256,
      resident_sha256:$resident_set_sha256,
      explicit_membership_check:"PASS_LOCAL",
      local_raw_records:{
        resident_base_sha256:$base_local_raw_sha256,
        outgoing_sha256:$outgoing_local_raw_sha256
      },
      base_by_type:{commit:$base_commit_sha256,tree:$base_tree_sha256,blob:$base_blob_sha256},
      outgoing_by_type:{commit:$outgoing_commit_sha256,tree:$outgoing_tree_sha256,blob:$outgoing_blob_sha256}
    },
    tools:{git_sha256:$git_sha256,gitleaks_sha256:$gitleaks_sha256,gitleaks_version:"8.30.1"},
    scanner_policy_sha256:$scanner_policy_sha256
  }'
