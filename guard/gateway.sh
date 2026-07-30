#!/bin/bash -p
set -euo pipefail

GUARD_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)
# shellcheck source=guard/common.sh
. "$GUARD_DIR/common.sh"

gateway_remote_denied() {
  guard_fail "publication operation is unavailable in Phase 1a"
}

gateway_proposal() {
  [ "$#" -eq 2 ] && [ "$1" = "--json" ] ||
    { guard_fail "proposal accepts only --json ABSOLUTE_PATH"; return 1; }
  proposal_path=$2
  guard_json_no_duplicate_paths "$proposal_path" || return 1
  guard_json_exact_keys "$proposal_path" \
    '["schema","operation","request_id","repo_id","candidate_sha"]' || return 1
  /usr/bin/jq -e '
    .schema == "alpha-nightshift/local-proposal/v1" and
    .operation == "validate" and
    ([.schema,.operation,.request_id,.repo_id,.candidate_sha] | all(type == "string"))
  ' "$proposal_path" >/dev/null ||
    { guard_fail "invalid proposal grammar"; return 1; }
  proposal_request=$(/usr/bin/jq -r '.request_id' "$proposal_path")
  proposal_repo=$(/usr/bin/jq -r '.repo_id' "$proposal_path")
  proposal_sha=$(/usr/bin/jq -r '.candidate_sha' "$proposal_path")
  guard_validate_request_id "$proposal_request" || return 1
  guard_validate_repo_id "$proposal_repo" || return 1
  guard_validate_sha "$proposal_sha" || return 1
  /usr/bin/jq -cn \
    --arg mode "$GUARD_MODE" \
    --arg request_id "$proposal_request" \
    --arg repo_id "$proposal_repo" \
    --arg candidate_sha "$proposal_sha" \
    '{schema:"alpha-nightshift/proposal-verdict/v1",mode:$mode,write_mode:false,
      valid:true,request_id:$request_id,repo_id:$repo_id,candidate_sha:$candidate_sha}'
}

gateway_main() {
  [ "$#" -ge 1 ] || { guard_fail "missing typed operation"; return 1; }
  gateway_operation=$1
  shift
  case "$gateway_operation" in
    status|inspect)
      [ "$#" -eq 0 ] || { guard_fail "$gateway_operation accepts no fields"; return 1; }
      guard_mode_json
      ;;
    preflight)
      exec "$GUARD_DIR/broker.sh" preflight "$@"
      ;;
    scan)
      exec "$GUARD_DIR/broker.sh" scan "$@"
      ;;
    publish_status)
      exec "$GUARD_DIR/broker.sh" publish_status "$@"
      ;;
    validate_text)
      exec "$GUARD_DIR/broker.sh" validate_text "$@"
      ;;
    publish_branch)
      exec "$GUARD_DIR/broker.sh" publish_branch "$@"
      ;;
    proposal)
      gateway_proposal "$@"
      ;;
    publish|create_draft_pr|create_issue|push|merge|comment|label|api|request|graphql)
      gateway_remote_denied
      ;;
    *)
      guard_fail "unknown operation"
      ;;
  esac
}

gateway_main "$@"
