#!/bin/bash
set -euo pipefail

GUARD_MODE=LOCAL_ONLY_REMOTE_UNPROVEN
export GUARD_MODE
GUARD_GIT_BIN=/opt/homebrew/Cellar/git/2.48.1/bin/git
GUARD_GITLEAKS_BIN=/opt/homebrew/Cellar/gitleaks/8.30.1/bin/gitleaks
GUARD_CURL_BIN=/usr/bin/curl
GUARD_OPENSSL_BIN=/usr/bin/openssl
export GUARD_GIT_BIN GUARD_GITLEAKS_BIN GUARD_CURL_BIN GUARD_OPENSSL_BIN

guard_root() {
  CDPATH='' cd -- "$(dirname "$0")/.." && pwd -P
}

guard_fail() {
  guard_reason=$1
  printf '%s: %s\n' "$GUARD_MODE" "$guard_reason" >&2
  return 1
}

guard_sha256() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

guard_has_control() {
  LC_ALL=C /usr/bin/printf '%s' "$1" |
    /usr/bin/grep '[[:cntrl:]]' >/dev/null 2>&1
}

guard_validate_absolute_path() {
  guard_path=$1
  guard_kind=${2:-any}
  case "$guard_path" in
    /*) ;;
    *) guard_fail "path must be absolute"; return 1 ;;
  esac
  if guard_has_control "$guard_path"; then
    guard_fail "path contains a control character"
    return 1
  fi
  if LC_ALL=C /usr/bin/printf '%s' "$guard_path" |
    /usr/bin/grep '[^ -~]' >/dev/null 2>&1; then
    guard_fail "path contains non-ASCII or normalization-ambiguous bytes"
    return 1
  fi
  case "$guard_path" in
    *//*|*/../*|*/./*|*/..|*/.|*"/~"*) guard_fail "path is not canonical"; return 1 ;;
  esac
  case "$guard_kind" in
    file) [ -f "$guard_path" ] || { guard_fail "file is unavailable"; return 1; } ;;
    dir) [ -d "$guard_path" ] || { guard_fail "directory is unavailable"; return 1; } ;;
    executable) [ -f "$guard_path" ] && [ -x "$guard_path" ] ||
      { guard_fail "executable is unavailable"; return 1; } ;;
    output)
      guard_parent=${guard_path%/*}
      [ -n "$guard_parent" ] || guard_parent=/
      [ -d "$guard_parent" ] || { guard_fail "output parent is unavailable"; return 1; }
      ;;
    any) [ -e "$guard_path" ] || { guard_fail "path is unavailable"; return 1; } ;;
    *) guard_fail "internal path-kind error"; return 1 ;;
  esac
  guard_parent=${guard_path%/*}
  [ -n "$guard_parent" ] || guard_parent=/
  guard_name=${guard_path##*/}
  guard_resolved_parent=$(CDPATH='' cd -- "$guard_parent" 2>/dev/null && pwd -P) ||
    { guard_fail "path parent cannot be resolved"; return 1; }
  guard_resolved=$guard_resolved_parent
  [ -z "$guard_name" ] || guard_resolved="$guard_resolved_parent/$guard_name"
  if [ "$guard_kind" != output ]; then
    guard_full_resolved=$(/usr/bin/perl -MCwd=abs_path -e '
      my $path=abs_path($ARGV[0]);
      exit 1 unless defined $path;
      print $path;
    ' "$guard_path") || { guard_fail "path cannot be fully canonicalized"; return 1; }
    guard_resolved=$guard_full_resolved
  fi
  [ "$guard_resolved" = "$guard_path" ] ||
    { guard_fail "path contains an alias or symlink: $guard_path"; return 1; }
}

guard_validate_repo_id() {
  guard_repo_id=$1
  guard_has_control "$guard_repo_id" &&
    { guard_fail "repository id contains a control character"; return 1; }
  LC_ALL=C /usr/bin/printf '%s\n' "$guard_repo_id" |
    /usr/bin/grep -E '^[a-z][a-z0-9-]{0,38}/[a-z][a-z0-9._-]{0,99}$' >/dev/null ||
    { guard_fail "invalid repository id"; return 1; }
  case "$guard_repo_id" in
    *..*|*--*|*__*|*//*|*/*/*) guard_fail "ambiguous repository id"; return 1 ;;
  esac
}

guard_validate_request_id() {
  guard_request_id=$1
  LC_ALL=C /usr/bin/printf '%s\n' "$guard_request_id" |
    /usr/bin/grep -E '^REQ-[0-9]{8}-[0-9]{4}-[a-f0-9]{16}$' >/dev/null ||
    { guard_fail "invalid request id"; return 1; }
}

guard_validate_sha() {
  guard_sha=$1
  LC_ALL=C /usr/bin/printf '%s\n' "$guard_sha" |
    /usr/bin/grep -E '^[a-f0-9]{40}([a-f0-9]{24})?$' >/dev/null ||
    { guard_fail "invalid object id"; return 1; }
}

guard_validate_nonzero_sha() {
  guard_sha=$1
  guard_validate_sha "$guard_sha" || return 1
  case "$guard_sha" in
    0000000000000000000000000000000000000000|\
    0000000000000000000000000000000000000000000000000000000000000000)
      guard_fail "all-zero object id is forbidden"
      return 1
      ;;
  esac
}

guard_validate_positive_integer() {
  guard_integer=$1
  LC_ALL=C /usr/bin/printf '%s\n' "$guard_integer" |
    /usr/bin/grep -E '^[1-9][0-9]*$' >/dev/null ||
    { guard_fail "positive integer is required"; return 1; }
}

guard_json_sha256() {
  guard_json_path=$1
  guard_validate_absolute_path "$guard_json_path" file || return 1
  /usr/bin/jq -cS . "$guard_json_path" |
    /usr/bin/shasum -a 256 |
    /usr/bin/awk '{print $1}'
}

guard_git_dir_for_repo() {
  guard_repo=$1
  guard_validate_absolute_path "$guard_repo" dir || return 1
  if [ -d "$guard_repo/.git" ]; then
    /usr/bin/printf '%s\n' "$guard_repo/.git"
    return 0
  fi
  if [ -f "$guard_repo/.git" ]; then
    guard_gitdir_line=$(/usr/bin/sed -n '1p' "$guard_repo/.git")
    case "$guard_gitdir_line" in
      "gitdir: "/*)
        /usr/bin/printf '%s\n' "${guard_gitdir_line#gitdir: }"
        return 0
        ;;
    esac
  fi
  guard_fail "repository has no explicit Git directory"
  return 1
}

guard_json_no_duplicate_paths() {
  guard_json=$1
  guard_validate_absolute_path "$guard_json" file || return 1
  /usr/bin/jq --stream -r '
    select(length == 2) | .[0] | @json
  ' "$guard_json" 2>/dev/null |
    LC_ALL=C /usr/bin/sort |
    /usr/bin/uniq -d |
    /usr/bin/grep . >/dev/null 2>&1 && {
      guard_fail "JSON contains duplicate fields"
      return 1
    }
  /usr/bin/jq -e . "$guard_json" >/dev/null 2>&1 ||
    { guard_fail "malformed JSON"; return 1; }
}

guard_json_exact_keys() {
  guard_json=$1
  guard_keys_json=$2
  /usr/bin/jq -e --argjson expected "$guard_keys_json" '
    (keys | sort) == ($expected | sort)
  ' "$guard_json" >/dev/null ||
    { guard_fail "JSON has missing or unknown fields"; return 1; }
}

guard_hardened_git() {
  guard_git_dir=$1
  shift
  /usr/bin/env -i \
    HOME=/var/empty \
    XDG_CONFIG_HOME=/var/empty \
    LANG=C \
    LC_ALL=C \
    PATH=/usr/bin:/bin \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_SYSTEM=/dev/null \
    GIT_ATTR_NOSYSTEM=1 \
    GIT_TERMINAL_PROMPT=0 \
    GIT_ASKPASS=/usr/bin/false \
    SSH_ASKPASS=/usr/bin/false \
    GIT_NO_REPLACE_OBJECTS=1 \
    "$GUARD_GIT_BIN" \
      --no-pager \
      --git-dir="$guard_git_dir" \
      -c core.hooksPath=/dev/null \
      -c core.fsmonitor=false \
      -c credential.helper= \
      -c protocol.file.allow=never \
      "$@"
}

guard_mode_json() {
  /usr/bin/jq -cn --arg mode "$GUARD_MODE" \
    '{schema:"alpha-nightshift/guard-status/v1",mode:$mode,write_mode:false}'
}
