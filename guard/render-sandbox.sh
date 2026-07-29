#!/bin/bash
set -euo pipefail

GUARD_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
# shellcheck source=guard/common.sh
. "$GUARD_DIR/common.sh"

workspace=
state=
fixture=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace)
      [ "$#" -ge 2 ] || { guard_fail "missing workspace"; exit 1; }
      workspace=$2
      shift 2
      ;;
    --state)
      [ "$#" -ge 2 ] || { guard_fail "missing state"; exit 1; }
      state=$2
      shift 2
      ;;
    --fixture)
      [ "$#" -ge 2 ] || { guard_fail "missing fixture"; exit 1; }
      fixture=$2
      shift 2
      ;;
    *)
      guard_fail "unknown sandbox field"
      exit 1
      ;;
  esac
done

[ -n "$workspace" ] && [ -n "$state" ] ||
  { guard_fail "workspace and state are required"; exit 1; }
guard_validate_absolute_path "$workspace" dir
guard_validate_absolute_path "$state" dir
for sandbox_root in "$workspace" "$state"; do
  if ! LC_ALL=C /usr/bin/perl -e '
    exit($ARGV[0] =~ /\A[A-Za-z0-9._\/-]+\z/ ? 0 : 1);
  ' "$sandbox_root"; then
    guard_fail "sandbox root contains a profile metacharacter"
    exit 1
  fi
done
[ "$workspace" != "$state" ] || { guard_fail "sandbox roots must be distinct"; exit 1; }
case "$workspace:$state" in
  "$workspace":"$workspace"/*|"$state"/*:"$state") guard_fail "sandbox roots overlap"; exit 1 ;;
esac

fixture_rule='; fixture network remains denied'
if [ -n "$fixture" ]; then
  LC_ALL=C /usr/bin/printf '%s\n' "$fixture" |
    /usr/bin/grep -E '^127\.0\.0\.1:([1-9][0-9]{0,4})$' >/dev/null ||
    { guard_fail "fixture must be exact loopback IPv4 and port"; exit 1; }
  fixture_port=${fixture##*:}
  [ "$fixture_port" -le 65535 ] ||
    { guard_fail "fixture port is outside the TCP range"; exit 1; }
  fixture_rule="(allow network-outbound (remote tcp \"$fixture\"))"
fi

/usr/bin/perl -e '
  use strict;
  use warnings;
  my ($template,$workspace,$state,$fixture)=@ARGV;
  open my $fh, "<:raw", $template or exit 90;
  local $/;
  my $profile=<$fh>;
  close $fh or exit 91;
  sub replace_literal {
    my ($text,$needle,$replacement)=@_;
    my $offset=0;
    while ((my $at=index($$text,$needle,$offset)) >= 0) {
      substr($$text,$at,length($needle),$replacement);
      $offset=$at+length($replacement);
    }
  }
  replace_literal(\$profile,q{@@WORKSPACE@@},$workspace);
  replace_literal(\$profile,q{@@STATE@@},$state);
  replace_literal(\$profile,q{@@FIXTURE_RULE@@},$fixture);
  exit 92 if $profile =~ /\@\@[A-Z_]+\@\@/;
  print $profile or exit 93;
' "$GUARD_DIR/sandbox.sb" "$workspace" "$state" "$fixture_rule"
