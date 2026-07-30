#!/bin/bash -p
set -euo pipefail

GUARD_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)
# shellcheck source=guard/common.sh
. "$GUARD_DIR/common.sh"
# shellcheck source=guard/publisher-lib.sh
. "$GUARD_DIR/publisher-lib.sh"

publisher_status_main() {
  [ "$#" -eq 2 ] && [ "$1" = "--policy" ] ||
    { guard_fail "status accepts only --policy ABSOLUTE_PATH"; exit 1; }
  publisher_load_policy "$2"
  publisher_emit_status_json
}

publisher_record_result() {
  publisher_kind=$1
  publisher_verdict=$2
  publisher_reason=$3
  publisher_detail_json=$4
  publisher_record=$(
    /usr/bin/jq -cn \
      --arg type "$publisher_kind" \
      --arg request_id "$PUBLISH_REQUEST_ID" \
      --arg repo_id "$PUBLISH_REPO_ID" \
      --arg destination_ref "$PUBLISH_DESTINATION_REF" \
      --arg verdict "$publisher_verdict" \
      --arg reason "$publisher_reason" \
      --arg occurred_at "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson detail "$publisher_detail_json" '
      {
        type:$type,
        request_id:$request_id,
        repo_id:$repo_id,
        destination_ref:$destination_ref,
        verdict:$verdict,
        reason:$reason,
        occurred_at:$occurred_at,
        detail:$detail
      }'
  )
  publisher_append_audit_json "$PUBLISH_AUDIT_DIR" "$PUBLISH_REQUEST_ID" "$publisher_record" >/dev/null
}

publisher_publish_branch_main() {
  publisher_policy=
  publisher_request=
  publisher_repo=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --policy)
        [ "$#" -ge 2 ] || { guard_fail "missing publisher policy"; exit 1; }
        publisher_policy=$2
        shift 2
        ;;
      --request)
        [ "$#" -ge 2 ] || { guard_fail "missing publish request"; exit 1; }
        publisher_request=$2
        shift 2
        ;;
      --repo)
        [ "$#" -ge 2 ] || { guard_fail "missing repository path"; exit 1; }
        publisher_repo=$2
        shift 2
        ;;
      *)
        guard_fail "unknown publish_branch field"
        exit 1
        ;;
    esac
  done

  [ -n "$publisher_policy" ] && [ -n "$publisher_request" ] && [ -n "$publisher_repo" ] ||
    { guard_fail "publish_branch requires --policy, --request, and --repo"; exit 1; }

  publisher_load_request "$publisher_request"
  publisher_load_policy "$publisher_policy"
  publisher_validate_repo_state "$publisher_repo"

  if ! publisher_policy_is_active; then
    publisher_emit_publish_json DENY_INACTIVE \
      "checked-in publisher policy remains inactive before key or network access" \
      '{"network_access":false,"key_access":false,"rule_suite_result":"UNPROVEN_NO_ADMIN_READ"}'
    exit 1
  fi

  publisher_prepare_active_policy
  publisher_disable_secret_leak_paths
  case "${#PUBLISH_CANDIDATE_SHA}" in
    40) PUBLISH_ZERO_OID=0000000000000000000000000000000000000000 ;;
    64) PUBLISH_ZERO_OID=0000000000000000000000000000000000000000000000000000000000000000 ;;
    *) guard_fail "candidate object id length is unsupported"; exit 1 ;;
  esac

  publisher_tmp=
  read_token=
  write_token=
  publisher_attempt_recorded=false
  publisher_result_recorded=false
  publisher_completed=false
  publisher_exit_reason="publisher exited before a terminal result"
  cleanup_publisher() {
    publisher_exit_status=$?
    trap - EXIT HUP INT TERM
    publisher_revoke_failed=false
    if [ -n "${write_token:-}" ]; then
      if ! publisher_revoke_token "$write_token" >/dev/null 2>&1; then
        publisher_revoke_failed=true
      fi
      write_token=
    fi
    if [ -n "${read_token:-}" ]; then
      if ! publisher_revoke_token "$read_token" >/dev/null 2>&1; then
        publisher_revoke_failed=true
      fi
      read_token=
    fi
    if [ "$publisher_revoke_failed" = true ]; then
      publisher_exit_status=1
      publisher_exit_reason="$publisher_exit_reason; token revocation was not proven"
    fi
    if [ "${publisher_attempt_recorded:-false}" = true ] &&
      [ "${publisher_result_recorded:-false}" != true ]; then
      publisher_cleanup_detail=$(
        /usr/bin/jq -cn \
          --arg reason "$publisher_exit_reason" \
          --argjson revoke_failed "$publisher_revoke_failed" \
          '{cleanup_reason:$reason,revoke_failed:$revoke_failed}'
      )
      if publisher_record_result publish_result PUBLISH_UNVERIFIED_INCIDENT \
        "$publisher_exit_reason" "$publisher_cleanup_detail" >/dev/null 2>&1; then
        publisher_result_recorded=true
      fi
      publisher_exit_status=1
    fi
    /bin/rm -rf "$publisher_tmp"
    if [ "$publisher_completed" = true ] &&
      [ "$publisher_exit_status" -eq 0 ] &&
      [ "$publisher_revoke_failed" = false ]; then
      exit 0
    fi
    [ "$publisher_exit_status" -ne 0 ] || publisher_exit_status=1
    exit "$publisher_exit_status"
  }

  publisher_tmp=$(/usr/bin/mktemp -d /tmp/nightshift-publisher.XXXXXX)
  publisher_tmp=$(CDPATH='' cd -- "$publisher_tmp" && pwd -P)
  trap cleanup_publisher EXIT
  trap 'publisher_exit_reason="publisher received SIGHUP"; exit 129' HUP
  trap 'publisher_exit_reason="publisher received SIGINT"; exit 130' INT
  trap 'publisher_exit_reason="publisher received SIGTERM"; exit 143' TERM
  publisher_prepare_scratch_git "$publisher_tmp/git"

  scan_output=$publisher_tmp/scan.json
  prepush_scan_output=$publisher_tmp/prepush-scan.json
  app_json=$publisher_tmp/app.json
  installation_json=$publisher_tmp/installation.json
  headers_path=$publisher_tmp/headers.txt
  push_output=$publisher_tmp/push.txt
  read_preflight_json=$publisher_tmp/read-preflight.json
  prepush_json=$publisher_tmp/prepush.json
  postpush_json=$publisher_tmp/postpush.json
  publisher_scan_candidate "$scan_output"
  initial_scan_sha256=$(guard_json_sha256 "$scan_output")

  publisher_jwt=$(publisher_generate_jwt "$PUBLISH_PRIVATE_KEY_PATH" "$PUBLISH_APP_ID")
  publisher_api_request GET "$PUBLISH_API_BASE/app" \
    "$publisher_jwt" '' 200 "$app_json" "$headers_path"
  publisher_api_request GET "$PUBLISH_API_BASE/app/installations/$PUBLISH_INSTALLATION_ID" \
    "$publisher_jwt" '' 200 "$installation_json" "$headers_path"
  /usr/bin/jq -e \
    --argjson app_id "$PUBLISH_APP_ID" '
    .id == $app_id and (.slug | type == "string" and length > 0)
  ' "$app_json" >/dev/null ||
    { guard_fail "GitHub App identity did not match the pinned app id"; exit 1; }
  /usr/bin/jq -e \
    --argjson installation_id "$PUBLISH_INSTALLATION_ID" \
    --arg selection "$PUBLISH_EXPECTED_REPOSITORY_SELECTION" \
    --arg metadata_perm "$PUBLISH_EXPECTED_METADATA_PERMISSION" '
    .id == $installation_id and
    (.account.login | type == "string" and length > 0) and
    .repository_selection == $selection and
    ((.permissions | keys | sort) == ["contents","metadata"]) and
    .permissions.metadata == $metadata_perm and
    .permissions.contents == "write" and
    (
      (.repositories_url? | type == "string" and length > 0) or
      (.target_type? | type == "string")
    )
  ' "$installation_json" >/dev/null ||
    { guard_fail "installation identity did not match the pinned installation"; exit 1; }
  app_slug=$(/usr/bin/jq -r '.slug' "$app_json")

  read_token_body=$(
    /usr/bin/jq -cn \
      --argjson repository_id "$PUBLISH_REPOSITORY_ID" \
      '{repository_ids:[$repository_id],permissions:{contents:"read"}}'
  )
  read_token_json=$(
    publisher_api_request_memory POST \
      "$PUBLISH_API_BASE/app/installations/$PUBLISH_INSTALLATION_ID/access_tokens" \
      "$publisher_jwt" "$read_token_body" 201
  )
  read_token=$(
    builtin printf '%s' "$read_token_json" |
      /usr/bin/jq -er '.token | select(type == "string" and test("^[A-Za-z0-9_]{20,}$"))'
  ) || { guard_fail "read installation token response omitted a revocable token"; exit 1; }
  publisher_verify_installation_token_response "$read_token_json" read
  unset read_token_json
  {
    builtin printf '%s\n' "$read_token"
  } | /usr/bin/env -i \
        HOME=/var/empty \
        LANG=C \
        LC_ALL=C \
        PATH=/usr/bin:/bin \
        /bin/bash -p "$GUARD_DIR/remote-preflight.sh" \
        --phase read \
        --policy "$PUBLISH_POLICY_PATH" \
        --request "$PUBLISH_REQUEST_PATH" \
        --request-sha256 "$PUBLISH_REQUEST_DIGEST" \
        --repo "$PUBLISH_REPO_PATH" > "$read_preflight_json"
  if ! publisher_revoke_token "$read_token"; then
    publisher_exit_reason="read installation token revoke failed before publish attempt"
    publisher_read_revoke_detail=$(
      /usr/bin/jq -cn \
        --arg phase read_token_revoke \
        --arg revoke_result UNPROVEN \
        '{phase:$phase,revoke_result:$revoke_result,network_write_attempted:false}'
    )
    publisher_record_result publish_result PUBLISH_UNVERIFIED_INCIDENT \
      "$publisher_exit_reason" "$publisher_read_revoke_detail"
    publisher_result_recorded=true
    guard_fail "$publisher_exit_reason"
    exit 1
  fi
  read_token=

  unset publisher_jwt
  publisher_jwt=$(publisher_generate_jwt "$PUBLISH_PRIVATE_KEY_PATH" "$PUBLISH_APP_ID")
  write_token_body=$(
    /usr/bin/jq -cn \
      --argjson repository_id "$PUBLISH_REPOSITORY_ID" \
      '{repository_ids:[$repository_id],permissions:{contents:"write"}}'
  )
  write_token_json=$(
    publisher_api_request_memory POST \
      "$PUBLISH_API_BASE/app/installations/$PUBLISH_INSTALLATION_ID/access_tokens" \
      "$publisher_jwt" "$write_token_body" 201
  )
  write_token=$(
    builtin printf '%s' "$write_token_json" |
      /usr/bin/jq -er '.token | select(type == "string" and test("^[A-Za-z0-9_]{20,}$"))'
  ) || { guard_fail "write installation token response omitted a revocable token"; exit 1; }
  publisher_verify_installation_token_response "$write_token_json" write
  unset write_token_json publisher_jwt
  {
    builtin printf '%s\n' "$write_token"
  } | /usr/bin/env -i \
        HOME=/var/empty \
        LANG=C \
        LC_ALL=C \
        PATH=/usr/bin:/bin \
        /bin/bash -p "$GUARD_DIR/remote-preflight.sh" \
        --phase prepush \
        --policy "$PUBLISH_POLICY_PATH" \
        --request "$PUBLISH_REQUEST_PATH" \
        --request-sha256 "$PUBLISH_REQUEST_DIGEST" \
        --repo "$PUBLISH_REPO_PATH" > "$prepush_json"
  publisher_verify_read_prepush_pair "$read_preflight_json" "$prepush_json" ||
    {
      publisher_exit_reason="read-before-write remote preflight drifted"
      guard_fail "read-before-write remote preflight drifted"
      exit 1
    }

  publisher_scan_candidate "$prepush_scan_output"
  scan_sha256=$(guard_json_sha256 "$prepush_scan_output")
  [ "$scan_sha256" = "$initial_scan_sha256" ] ||
    {
      publisher_exit_reason="local scan evidence drifted before push"
      guard_fail "$publisher_exit_reason"
      exit 1
    }
  /usr/bin/jq -e \
    --arg base_sha "$PUBLISH_BASE_SHA" \
    --arg candidate_sha "$PUBLISH_CANDIDATE_SHA" '
    .base_sha == $base_sha and
    .candidate_sha == $candidate_sha and
    .verdict == "PASS_LOCAL_ONLY"
  ' "$prepush_scan_output" >/dev/null ||
    {
      publisher_exit_reason="prepush scan did not bind the accepted commits"
      guard_fail "$publisher_exit_reason"
      exit 1
    }
  scanner_policy_sha256=$(/usr/bin/jq -r '.scanner_policy_sha256' "$prepush_scan_output")
  scan_counts_json=$(/usr/bin/jq -c '.counts' "$prepush_scan_output")
  scan_manifest_sha256=$(guard_json_sha256 "$PUBLISH_SCAN_MANIFEST_PATH")
  read_preflight_detail=$(/usr/bin/jq -c . "$read_preflight_json")
  prepush_detail=$(/usr/bin/jq -c . "$prepush_json")
  for publisher_audit_digest in \
    "$PUBLISH_REQUEST_DIGEST" \
    "$PUBLISH_POLICY_DIGEST" \
    "$scan_sha256" \
    "$scanner_policy_sha256" \
    "$scan_manifest_sha256"; do
    LC_ALL=C /usr/bin/printf '%s\n' "$publisher_audit_digest" |
      /usr/bin/grep -E '^[a-f0-9]{64}$' >/dev/null ||
      { guard_fail "publisher audit digest is invalid"; exit 1; }
  done

  audit_detail_json=$(
    /usr/bin/jq -cn \
      --arg request_sha256 "$PUBLISH_REQUEST_DIGEST" \
      --arg policy_sha256 "$PUBLISH_POLICY_DIGEST" \
      --arg scan_sha256 "$scan_sha256" \
      --arg scanner_policy_sha256 "$scanner_policy_sha256" \
      --arg scan_manifest_sha256 "$scan_manifest_sha256" \
      --arg branch "$PUBLISH_DESTINATION_REF" \
      --arg rule_suite_result UNPROVEN_NO_ADMIN_READ \
      --argjson scan_counts "$scan_counts_json" \
      --argjson read_preflight "$read_preflight_detail" \
      --argjson prepush "$prepush_detail" '
      {
        request_sha256:$request_sha256,
        policy_sha256:$policy_sha256,
        scan_sha256:$scan_sha256,
        scanner_policy_sha256:$scanner_policy_sha256,
        scan_manifest_sha256:$scan_manifest_sha256,
        branch:$branch,
        rule_suite_result:$rule_suite_result,
        scan_counts:$scan_counts,
        read_preflight:$read_preflight,
        prepush:$prepush
      }'
  )
  publisher_attempt_occurred_at=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)
  publisher_attempt_record=$(
    /usr/bin/jq -cn \
      --arg type publish_attempt \
      --arg request_id "$PUBLISH_REQUEST_ID" \
      --arg repo_id "$PUBLISH_REPO_ID" \
      --arg before_sha "$PUBLISH_ZERO_OID" \
      --arg candidate_sha "$PUBLISH_CANDIDATE_SHA" \
      --arg branch "$PUBLISH_DESTINATION_REF" \
      --arg occurred_at "$publisher_attempt_occurred_at" \
      --argjson detail "$audit_detail_json" '
      {
        type:$type,
        request_id:$request_id,
        repo_id:$repo_id,
        before_sha:$before_sha,
        candidate_sha:$candidate_sha,
        branch:$branch,
        occurred_at:$occurred_at,
        detail:$detail
      }'
  )
  audit_path=$(publisher_append_audit_json \
    "$PUBLISH_AUDIT_DIR" "$PUBLISH_REQUEST_ID" "$publisher_attempt_record")
  publisher_attempt_recorded=true

  if ! publisher_git_push "$write_token" "$push_output"; then
    publisher_exit_reason="push failed after attempt record"
    exit 1
  fi

  {
    builtin printf '%s\n' "$write_token"
  } | /usr/bin/env -i \
        HOME=/var/empty \
        LANG=C \
        LC_ALL=C \
        PATH=/usr/bin:/bin \
        /bin/bash -p "$GUARD_DIR/remote-preflight.sh" \
        --phase postpush \
        --policy "$PUBLISH_POLICY_PATH" \
        --request "$PUBLISH_REQUEST_PATH" \
        --request-sha256 "$PUBLISH_REQUEST_DIGEST" \
        --repo "$PUBLISH_REPO_PATH" > "$postpush_json"
  publisher_verify_postpush_pair "$prepush_json" "$postpush_json" ||
    {
      publisher_exit_reason="post-push readback did not prove the generated ref"
      exit 1
    }

  if ! publisher_revoke_token "$write_token"; then
    publisher_exit_reason="write installation token revoke failed after push"
    exit 1
  fi
  write_token=

  push_sha256=$(guard_sha256 "$push_output")
  postpush_detail=$(/usr/bin/jq -c . "$postpush_json")
  for publisher_result_digest in "$PUBLISH_REQUEST_DIGEST" "$push_sha256"; do
    LC_ALL=C /usr/bin/printf '%s\n' "$publisher_result_digest" |
      /usr/bin/grep -E '^[a-f0-9]{64}$' >/dev/null ||
      { guard_fail "publisher result digest is invalid"; exit 1; }
  done
  success_detail=$(
    /usr/bin/jq -cn \
      --arg audit_path "$audit_path" \
      --arg app_principal "app/$app_slug#installation/$PUBLISH_INSTALLATION_ID" \
      --arg actor_source github_app_installation \
      --arg request_sha256 "$PUBLISH_REQUEST_DIGEST" \
      --arg policy_sha256 "$PUBLISH_POLICY_DIGEST" \
      --arg push_sha256 "$push_sha256" \
      --arg scan_sha256 "$scan_sha256" \
      --arg scanner_policy_sha256 "$scanner_policy_sha256" \
      --arg scan_manifest_sha256 "$scan_manifest_sha256" \
      --arg rule_suite_result UNPROVEN_NO_ADMIN_READ \
      --arg before_sha "$PUBLISH_ZERO_OID" \
      --arg revoke_result HTTP_204 \
      --argjson read_preflight "$read_preflight_detail" \
      --argjson prepush "$prepush_detail" \
      --argjson postpush "$postpush_detail" '
      {
        audit_path:$audit_path,
        actor:$app_principal,
        actor_source:$actor_source,
        request_sha256:$request_sha256,
        policy_sha256:$policy_sha256,
        before_sha:$before_sha,
        after_sha:$postpush.destination_sha,
        push_output_sha256:$push_sha256,
        scan_sha256:$scan_sha256,
        scanner_policy_sha256:$scanner_policy_sha256,
        scan_manifest_sha256:$scan_manifest_sha256,
        ruleset_result:$postpush.ruleset_result,
        rule_suite_result:$rule_suite_result,
        revoke_result:$revoke_result,
        read_preflight:$read_preflight,
        prepush:$prepush,
        postpush:$postpush
      }'
  )
  publisher_result_occurred_at=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)
  publisher_success_record=$(
    /usr/bin/jq -cn \
      --arg type publish_result \
      --arg request_id "$PUBLISH_REQUEST_ID" \
      --arg repo_id "$PUBLISH_REPO_ID" \
      --arg branch "$PUBLISH_DESTINATION_REF" \
      --arg occurred_at "$publisher_result_occurred_at" \
      --arg verdict SUCCESS \
      --argjson detail "$success_detail" '
      {
        type:$type,
        request_id:$request_id,
        repo_id:$repo_id,
        branch:$branch,
        occurred_at:$occurred_at,
        verdict:$verdict,
        detail:$detail
      }'
  )
  publisher_append_audit_json \
    "$PUBLISH_AUDIT_DIR" \
    "$PUBLISH_REQUEST_ID" \
    "$publisher_success_record" >/dev/null
  publisher_result_recorded=true

  publisher_emit_publish_json SUCCESS \
    "created one fresh broker-generated run branch and revoked all installation tokens" \
    "$success_detail"
  publisher_completed=true
}

publisher_main() {
  [ "$#" -ge 1 ] || { guard_fail "missing publisher operation"; exit 1; }
  publisher_operation=$1
  shift
  case "$publisher_operation" in
    status)
      publisher_status_main "$@"
      ;;
    publish_branch)
      publisher_publish_branch_main "$@"
      ;;
    *)
      guard_fail "unknown publisher operation"
      exit 1
      ;;
  esac
}

publisher_main "$@"
