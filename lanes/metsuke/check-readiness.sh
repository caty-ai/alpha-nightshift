#!/bin/bash
set -euo pipefail
export LC_ALL=C

if [ -L "$0" ]; then
  printf '%s\n' "readiness: checker_self: final-component symlink is refused" >&2
  exit 1
fi

SCRIPT_DIR=$(cd -P "$(/usr/bin/dirname "$0")" && pwd -P)
PLAYWRIGHT_VERSION=1.55.0
CHROMIUM_REVISION=1187

LP_CHECKOUT=
BROWSER_CACHE=
CODEX_BIN=
STATE_DIR=
LP_CHECKOUT_SET=false
BROWSER_CACHE_SET=false
CODEX_BIN_SET=false
STATE_DIR_SET=false
CANONICAL_PATH=

fail() {
  printf 'readiness: %s: %s\n' "$1" "$2" >&2
  exit 1
}

validate_path_text() {
  local cell=$1
  local value=$2
  case "$value" in
    /*) ;;
    *) fail "$cell" "path must be absolute" ;;
  esac
  case "$value" in
    *[![:print:]]*) fail "$cell" "path contains a control character" ;;
    *'"'*|*'\'*) fail "$cell" "path contains a refused character" ;;
    //*) fail "$cell" "path is not canonical" ;;
    *//*|*/./*|*/../*|*/.|*/..) fail "$cell" "path is not canonical" ;;
    */) [ "$value" = / ] || fail "$cell" "path is not canonical" ;;
  esac
}

canonical_dir() {
  local cell=$1
  local value=$2
  local resolved
  validate_path_text "$cell" "$value"
  [ ! -L "$value" ] || fail "$cell" "symlink paths are refused"
  [ -d "$value" ] || fail "$cell" "directory does not exist"
  resolved=$(cd -P "$value" 2>/dev/null && pwd -P) ||
    fail "$cell" "directory cannot be resolved"
  [ "$resolved" = "$value" ] || fail "$cell" "path is an alias"
  CANONICAL_PATH=$resolved
}

canonical_file() {
  local cell=$1
  local value=$2
  local required_root=$3
  local parent
  local base
  local resolved_parent
  local resolved
  validate_path_text "$cell" "$value"
  [ ! -L "$value" ] || fail "$cell" "symlink files are refused"
  [ -f "$value" ] || fail "$cell" "regular file does not exist"
  parent=${value%/*}
  base=${value##*/}
  [ -n "$parent" ] || parent=/
  resolved_parent=$(cd -P "$parent" 2>/dev/null && pwd -P) ||
    fail "$cell" "file parent cannot be resolved"
  if [ "$resolved_parent" = / ]; then
    resolved="/$base"
  else
    resolved="$resolved_parent/$base"
  fi
  [ "$resolved" = "$value" ] || fail "$cell" "path is an alias"
  case "$resolved" in
    "$required_root"/*) ;;
    *) fail "$cell" "file is outside its required root" ;;
  esac
  CANONICAL_PATH=$resolved
}

canonical_executable() {
  local cell=$1
  local value=$2
  local required_root=$3
  canonical_file "$cell" "$value" "$required_root"
  [ -x "$value" ] || fail "$cell" "file is not executable"
}

read_package_version() {
  local metadata_file=$1
  local expected_name=$2
  /usr/bin/jq -e -r -s --arg expected_name "$expected_name" '
    select(length == 1)
    | .[0]
    | select(
      type == "object" and
      .name == $expected_name and
      (.version | type == "string")
    )
    | .version
  ' "$metadata_file"
}

read_browser_revision() {
  local metadata_file=$1
  local browser_name=$2
  /usr/bin/jq -e -r --arg wanted "$browser_name" '
    select(type == "object" and (.browsers | type == "array"))
    | [.browsers[] | select(type == "object" and .name == $wanted)] as $matches
    | select(($matches | length) == 1)
    | $matches[0]
    | select(.revision | type == "string")
    | .revision
  ' "$metadata_file"
}

check_local_writable_state_parent() {
  local candidate=$1
  local parent
  validate_path_text state_dir "$candidate"
  [ "$candidate" != / ] || fail state_dir "filesystem root is not a state directory"
  parent=$candidate
  while [ ! -e "$parent" ] && [ ! -L "$parent" ]; do
    [ "$parent" != / ] || fail state_parent "no existing parent"
    parent=${parent%/*}
    [ -n "$parent" ] || parent=/
  done
  canonical_dir state_parent "$parent"
  [ -w "$parent" ] || fail state_parent "nearest existing parent is not writable"
  /bin/df -lP "$parent" 2>/dev/null |
    /usr/bin/awk 'NR == 2 { found = 1 } END { exit !found }' ||
    fail state_parent "nearest existing parent is not on a local filesystem"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --lp-checkout)
      [ "$LP_CHECKOUT_SET" = false ] || fail arguments "duplicate --lp-checkout"
      [ "$#" -ge 2 ] || fail arguments "missing value for --lp-checkout"
      LP_CHECKOUT=$2
      LP_CHECKOUT_SET=true
      shift 2
      ;;
    --browser-cache)
      [ "$BROWSER_CACHE_SET" = false ] || fail arguments "duplicate --browser-cache"
      [ "$#" -ge 2 ] || fail arguments "missing value for --browser-cache"
      BROWSER_CACHE=$2
      BROWSER_CACHE_SET=true
      shift 2
      ;;
    --codex-bin)
      [ "$CODEX_BIN_SET" = false ] || fail arguments "duplicate --codex-bin"
      [ "$#" -ge 2 ] || fail arguments "missing value for --codex-bin"
      CODEX_BIN=$2
      CODEX_BIN_SET=true
      shift 2
      ;;
    --state-dir)
      [ "$STATE_DIR_SET" = false ] || fail arguments "duplicate --state-dir"
      [ "$#" -ge 2 ] || fail arguments "missing value for --state-dir"
      STATE_DIR=$2
      STATE_DIR_SET=true
      shift 2
      ;;
    *) fail arguments "unknown argument" ;;
  esac
done

[ "$LP_CHECKOUT_SET" = true ] || fail arguments "missing --lp-checkout"
[ "$BROWSER_CACHE_SET" = true ] || fail arguments "missing --browser-cache"
[ "$CODEX_BIN_SET" = true ] || fail arguments "missing --codex-bin"
[ "$STATE_DIR_SET" = true ] || fail arguments "missing --state-dir"

canonical_dir lp_checkout "$LP_CHECKOUT"
LP_CHECKOUT=$CANONICAL_PATH
canonical_dir lp_node_modules "$LP_CHECKOUT/node_modules"

canonical_dir browser_cache "$BROWSER_CACHE"
BROWSER_CACHE=$CANONICAL_PATH

playwright_metadata="$SCRIPT_DIR/node_modules/playwright/package.json"
canonical_file playwright_package "$playwright_metadata" "$SCRIPT_DIR"
installed_playwright_version=$(read_package_version "$playwright_metadata" playwright) ||
  fail playwright_version "package version metadata is malformed"
[ "$installed_playwright_version" = "$PLAYWRIGHT_VERSION" ] ||
  fail playwright_version "expected 1.55.0"

playwright_core_metadata="$SCRIPT_DIR/node_modules/playwright-core/package.json"
canonical_file playwright_core_package "$playwright_core_metadata" "$SCRIPT_DIR"
installed_core_version=$(read_package_version "$playwright_core_metadata" playwright-core) ||
  fail playwright_core_version "package version metadata is malformed"
[ "$installed_core_version" = "$PLAYWRIGHT_VERSION" ] ||
  fail playwright_core_version "expected 1.55.0"

browser_metadata="$SCRIPT_DIR/node_modules/playwright-core/browsers.json"
canonical_file playwright_browser_metadata "$browser_metadata" "$SCRIPT_DIR"
installed_chromium_revision=$(read_browser_revision "$browser_metadata" chromium) ||
  fail chromium_revision "browser metadata is malformed"
[ "$installed_chromium_revision" = "$CHROMIUM_REVISION" ] ||
  fail chromium_revision "expected revision 1187"
installed_headless_shell_revision=$(
  read_browser_revision "$browser_metadata" chromium-headless-shell
) || fail chromium_headless_shell_revision "browser metadata is malformed"
[ "$installed_headless_shell_revision" = "$CHROMIUM_REVISION" ] ||
  fail chromium_headless_shell_revision "expected revision 1187"

[ "$(/usr/bin/uname -s)" = Darwin ] ||
  fail chromium_headless_shell_executable "unsupported operating system"
headless_shell_executable="$BROWSER_CACHE/chromium_headless_shell-$CHROMIUM_REVISION/chrome-mac/headless_shell"
canonical_executable \
  chromium_headless_shell_executable \
  "$headless_shell_executable" \
  "$BROWSER_CACHE"

codex_parent=${CODEX_BIN%/*}
[ -n "$codex_parent" ] || codex_parent=/
canonical_dir codex_parent "$codex_parent"
canonical_executable codex_bin "$CODEX_BIN" "$CANONICAL_PATH"

check_local_writable_state_parent "$STATE_DIR"

printf '{"ready":true,"playwright_version":"%s","chromium_revision":"%s","lp_checkout":"%s","browser_cache":"%s","codex_bin":"%s","state_dir":"%s"}\n' \
  "$PLAYWRIGHT_VERSION" \
  "$CHROMIUM_REVISION" \
  "$LP_CHECKOUT" \
  "$BROWSER_CACHE" \
  "$CODEX_BIN" \
  "$STATE_DIR"
