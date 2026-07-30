#!/bin/bash -p
set -euo pipefail

GUARD_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)
# shellcheck source=guard/common.sh
. "$GUARD_DIR/common.sh"
# shellcheck source=guard/publisher-lib.sh
. "$GUARD_DIR/publisher-lib.sh"

publisher_disable_secret_leak_paths

phase=
policy=
request=
repo=
expected_request_sha256=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --phase)
      [ "$#" -ge 2 ] || { guard_fail "missing remote preflight phase"; exit 1; }
      phase=$2
      shift 2
      ;;
    --policy)
      [ "$#" -ge 2 ] || { guard_fail "missing publisher policy"; exit 1; }
      policy=$2
      shift 2
      ;;
    --request)
      [ "$#" -ge 2 ] || { guard_fail "missing publish request"; exit 1; }
      request=$2
      shift 2
      ;;
    --repo)
      [ "$#" -ge 2 ] || { guard_fail "missing repository path"; exit 1; }
      repo=$2
      shift 2
      ;;
    --request-sha256)
      [ "$#" -ge 2 ] || { guard_fail "missing expected request digest"; exit 1; }
      expected_request_sha256=$2
      shift 2
      ;;
    *)
      guard_fail "unknown remote preflight field"
      exit 1
      ;;
  esac
done

[ -n "$phase" ] && [ -n "$policy" ] && [ -n "$request" ] && [ -n "$repo" ] &&
  [ -n "$expected_request_sha256" ] ||
  { guard_fail "remote preflight requires phase, policy, request, repo, and request digest"; exit 1; }
LC_ALL=C /usr/bin/printf '%s\n' "$expected_request_sha256" |
  /usr/bin/grep -E '^[a-f0-9]{64}$' >/dev/null ||
  { guard_fail "expected request digest is malformed"; exit 1; }

publisher_load_request "$request"
[ "$PUBLISH_REQUEST_DIGEST" = "$expected_request_sha256" ] ||
  { guard_fail "publish request changed after broker acceptance"; exit 1; }
publisher_load_policy "$policy"
publisher_validate_repo_state "$repo"
publisher_prepare_active_policy

IFS= read -r preflight_token || {
  guard_fail "remote preflight requires a token on stdin"
  exit 1
}
[ -n "$preflight_token" ] ||
  { guard_fail "remote preflight received an empty token"; exit 1; }
builtin printf '%s\n' "$preflight_token" |
  LC_ALL=C /usr/bin/grep -E '^[A-Za-z0-9_]{20,}$' >/dev/null ||
  { preflight_token=; guard_fail "remote preflight token grammar is invalid"; exit 1; }

preflight_tmp=$(/usr/bin/mktemp -d /tmp/nightshift-remote-preflight.XXXXXX)
preflight_tmp=$(CDPATH='' cd -- "$preflight_tmp" && pwd -P)
cleanup_remote_preflight() {
  rm -rf "$preflight_tmp"
}
trap cleanup_remote_preflight EXIT

publisher_verify_remote_state "$phase" "$preflight_token" "$preflight_tmp"
