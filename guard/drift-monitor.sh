#!/bin/bash -p
set -euo pipefail

GUARD_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)
# shellcheck source=guard/common.sh
. "$GUARD_DIR/common.sh"
# shellcheck source=guard/publisher-lib.sh
. "$GUARD_DIR/publisher-lib.sh"

MONITOR_CONFIG_PATH=
MONITOR_CONFIG_DIGEST=
MONITOR_CONFIG_MODE=
MONITOR_PUBLISHER_POLICY_PATH=
MONITOR_PUBLISHER_POLICY_SHA256=
MONITOR_EXPECTED_APP_SLUG=
MONITOR_EXPECTED_INSTALLATION_ACCOUNT=
MONITOR_REPRESENTATIVE_REF=
MONITOR_RUNTIME_JSON=
MONITOR_RUN_ID=
MONITOR_TMP=
MONITOR_READ_TOKEN=
MONITOR_READ_TOKEN_MINTED=false
MONITOR_READ_TOKEN_REVOKE_READY=false
MONITOR_RESULT_VERDICT=
MONITOR_RESULT_REASON=
MONITOR_RESULT_DETAIL_JSON='{}'
MONITOR_DETECTED_VERDICT=
MONITOR_DETECTED_REASON=
MONITOR_DETECTED_DETAIL_JSON='{}'
MONITOR_REVOKE_ATTEMPTED=false
MONITOR_REVOKE_RESULT=NOT_ATTEMPTED
MONITOR_REVOKE_REASON=
MONITOR_AUDIT_ATTEMPTED=false
MONITOR_AUDIT_RESULT=NOT_ATTEMPTED
MONITOR_AUDIT_REASON=
MONITOR_EMPTY_DETAIL_JSON='{}'

monitor_exact_keys='["schema","mode","write_mode","publisher_policy_path","publisher_policy_sha256","expected_app_slug","expected_installation_account","representative_ref","runtime"]'

monitor_load_config() {
  MONITOR_CONFIG_PATH=$1
  monitor_digest_before=$(guard_json_sha256 "$MONITOR_CONFIG_PATH") || return 1
  guard_json_no_duplicate_paths "$MONITOR_CONFIG_PATH" || return 1
  guard_json_exact_keys "$MONITOR_CONFIG_PATH" "$monitor_exact_keys" || return 1
  /usr/bin/jq -e '
    .schema == "alpha-nightshift/drift-monitor-policy/v1" and
    (.mode | type == "string" and (. == "INACTIVE" or . == "ACTIVE")) and
    (.write_mode == false) and
    ((.publisher_policy_path == null) or (.publisher_policy_path | type == "string")) and
    ((.publisher_policy_sha256 == null) or
      (.publisher_policy_sha256 | type == "string" and test("^[a-f0-9]{64}$"))) and
    ((.expected_app_slug == null) or
      (.expected_app_slug | type == "string" and test("^[a-z0-9][a-z0-9-]{0,38}$"))) and
    ((.expected_installation_account == null) or
      (.expected_installation_account | type == "string" and test("^[A-Za-z0-9-]{1,39}$"))) and
    ((.representative_ref == null) or
      (.representative_ref | type == "string" and
        test("^refs/heads/night-bot/run-[0-9]{8}-[0-9]{4}-[a-f0-9]{8}$"))) and
    (.runtime | type == "object") and
    ((.runtime | keys | sort) == ["programs"]) and
    ((.runtime.programs | keys | sort) == ["drift_monitor"]) and
    ((.runtime.programs.drift_monitor | keys | sort) == ["mode","sha256","uid"]) and
    (
      .runtime.programs.drift_monitor.sha256 == null or
      (.runtime.programs.drift_monitor.sha256 | type == "string" and test("^[a-f0-9]{64}$"))
    ) and
    (
      .runtime.programs.drift_monitor.uid == null or
      (.runtime.programs.drift_monitor.uid | type == "number" and floor == . and . >= 0)
    ) and
    (
      .runtime.programs.drift_monitor.mode == null or
      (.runtime.programs.drift_monitor.mode | type == "string" and test("^[0-7]{3,4}$"))
    ) and
    (
      .mode == "INACTIVE" or
      (
        .publisher_policy_path != null and
        .publisher_policy_sha256 != null and
        .expected_app_slug != null and
        .expected_installation_account != null and
        .representative_ref != null and
        (.runtime.programs.drift_monitor.sha256 != null) and
        (.runtime.programs.drift_monitor.uid != null) and
        (.runtime.programs.drift_monitor.mode != null)
      )
    )
  ' "$MONITOR_CONFIG_PATH" >/dev/null ||
    { guard_fail "drift monitor config schema is invalid"; return 1; }

  MONITOR_CONFIG_MODE=$(/usr/bin/jq -r '.mode' "$MONITOR_CONFIG_PATH")
  MONITOR_PUBLISHER_POLICY_PATH=$(/usr/bin/jq -r '.publisher_policy_path // ""' "$MONITOR_CONFIG_PATH")
  MONITOR_PUBLISHER_POLICY_SHA256=$(/usr/bin/jq -r '.publisher_policy_sha256 // ""' "$MONITOR_CONFIG_PATH")
  MONITOR_EXPECTED_APP_SLUG=$(/usr/bin/jq -r '.expected_app_slug // ""' "$MONITOR_CONFIG_PATH")
  MONITOR_EXPECTED_INSTALLATION_ACCOUNT=$(
    /usr/bin/jq -r '.expected_installation_account // ""' "$MONITOR_CONFIG_PATH"
  )
  MONITOR_REPRESENTATIVE_REF=$(/usr/bin/jq -r '.representative_ref // ""' "$MONITOR_CONFIG_PATH")
  MONITOR_RUNTIME_JSON=$(/usr/bin/jq -c '.runtime' "$MONITOR_CONFIG_PATH")
  monitor_digest_after=$(guard_json_sha256 "$MONITOR_CONFIG_PATH") || return 1
  [ "$monitor_digest_before" = "$monitor_digest_after" ] ||
    { guard_fail "drift monitor config changed while being accepted"; return 1; }
  MONITOR_CONFIG_DIGEST=$monitor_digest_before
  if [ -n "$MONITOR_PUBLISHER_POLICY_PATH" ]; then
    guard_validate_absolute_path "$MONITOR_PUBLISHER_POLICY_PATH" file || return 1
  fi
}

monitor_require_active_config_seal() {
  local monitor_uid=
  local monitor_mode=
  monitor_uid=$(/usr/bin/stat -f '%u' "$MONITOR_CONFIG_PATH") ||
    { guard_fail "drift monitor config owner is unavailable"; return 1; }
  monitor_mode=$(/usr/bin/stat -f '%Lp' "$MONITOR_CONFIG_PATH") ||
    { guard_fail "drift monitor config mode is unavailable"; return 1; }
  [ "$monitor_uid" = "$(/usr/bin/id -u)" ] ||
    { guard_fail "drift monitor config owner must equal the effective UID"; return 1; }
  [ "$monitor_mode" = 600 ] ||
    { guard_fail "drift monitor config mode must be 600"; return 1; }
  [ "$(guard_json_sha256 "$MONITOR_CONFIG_PATH")" = "$MONITOR_CONFIG_DIGEST" ] ||
    { guard_fail "drift monitor config digest drifted after acceptance"; return 1; }
}

monitor_emit_status_json() {
  /usr/bin/jq -cn \
    --arg mode "$GUARD_MODE" \
    --arg config_mode "$MONITOR_CONFIG_MODE" \
    --arg config_sha256 "$MONITOR_CONFIG_DIGEST" \
    --arg representative_ref "$MONITOR_REPRESENTATIVE_REF" \
    --arg publisher_policy_path "$MONITOR_PUBLISHER_POLICY_PATH" '
    {
      schema:"alpha-nightshift/drift-monitor-status/v1",
      mode:$mode,
      config_mode:$config_mode,
      write_mode:false,
      config_sha256:$config_sha256,
      representative_ref:($representative_ref | if . == "" then null else . end),
      publisher_policy_path:($publisher_policy_path | if . == "" then null else . end),
      live_credentials:false,
      network_access:false
    }'
}

monitor_set_result() {
  MONITOR_RESULT_VERDICT=$1
  MONITOR_RESULT_REASON=$2
  MONITOR_RESULT_DETAIL_JSON=${3:-$MONITOR_EMPTY_DETAIL_JSON}
}

monitor_set_detected_result() {
  MONITOR_DETECTED_VERDICT=$1
  MONITOR_DETECTED_REASON=$2
  MONITOR_DETECTED_DETAIL_JSON=${3:-$MONITOR_EMPTY_DETAIL_JSON}
  monitor_set_result "$1" "$2" "${3:-$MONITOR_EMPTY_DETAIL_JSON}"
}

monitor_emit_result_json() {
  /usr/bin/jq -cn \
    --arg mode REMOTE_DRIFT_MONITOR \
    --arg verdict "${MONITOR_RESULT_VERDICT:-MONITOR_UNVERIFIED}" \
    --arg reason "${MONITOR_RESULT_REASON:-drift monitor exited before a terminal result}" \
    --arg config_mode "${MONITOR_CONFIG_MODE:-}" \
    --arg config_sha256 "${MONITOR_CONFIG_DIGEST:-}" \
    --arg repo_id "${PUBLISH_REPO_ID:-}" \
    --arg representative_ref "${MONITOR_REPRESENTATIVE_REF:-}" \
    --arg publisher_policy_sha256 "${PUBLISH_POLICY_DIGEST:-}" \
    --arg repository_id "${PUBLISH_REPOSITORY_ID:-0}" \
    --arg detected_verdict "${MONITOR_DETECTED_VERDICT:-}" \
    --arg detected_reason "${MONITOR_DETECTED_REASON:-}" \
    --arg revoke_attempted "$MONITOR_REVOKE_ATTEMPTED" \
    --arg revoke_result "${MONITOR_REVOKE_RESULT:-NOT_ATTEMPTED}" \
    --arg revoke_reason "${MONITOR_REVOKE_REASON:-}" \
    --arg audit_attempted "$MONITOR_AUDIT_ATTEMPTED" \
    --arg audit_result "${MONITOR_AUDIT_RESULT:-NOT_ATTEMPTED}" \
    --arg audit_reason "${MONITOR_AUDIT_REASON:-}" \
    --argjson detail "${MONITOR_RESULT_DETAIL_JSON}" \
    --argjson detected_detail "${MONITOR_DETECTED_DETAIL_JSON}" '
    {
      schema:"alpha-nightshift/drift-monitor-result/v1",
      mode:$mode,
      verdict:$verdict,
      reason:$reason,
      write_mode:false,
      config_mode:($config_mode | if . == "" then null else . end),
      config_sha256:($config_sha256 | if . == "" then null else . end),
      repo_id:($repo_id | if . == "" then null else . end),
      repository_id:($repository_id | tonumber | if . <= 0 then null else . end),
      representative_ref:($representative_ref | if . == "" then null else . end),
      publisher_policy_sha256:($publisher_policy_sha256 | if . == "" then null else . end),
      detail:($detail + {
        detected_verdict:($detected_verdict | if . == "" then null else . end),
        detected_reason:($detected_reason | if . == "" then null else . end),
        detected_detail:$detected_detail,
        revoke_attempted:($revoke_attempted == "true"),
        revoke_result:$revoke_result,
        revoke_reason:($revoke_reason | if . == "" then null else . end),
        audit_attempted:($audit_attempted == "true"),
        audit_result:$audit_result,
        audit_reason:($audit_reason | if . == "" then null else . end)
      })
    }'
}

monitor_extract_reason() {
  monitor_error_path=$1
  monitor_reason=$(/usr/bin/sed -n '$s/^[^:]*: //p' "$monitor_error_path")
  if [ -z "$monitor_reason" ]; then
    monitor_reason=$(/usr/bin/tr '\n' ' ' < "$monitor_error_path" | /usr/bin/sed 's/[[:space:]]*$//')
  fi
  [ -n "$monitor_reason" ] || monitor_reason='operation failed without a reason'
  /usr/bin/printf '%s\n' "$monitor_reason"
}

monitor_try() {
  monitor_error_path=$1
  shift
  if "$@" 2> "$monitor_error_path"; then
    return 0
  fi
  MONITOR_LAST_ERROR=$(monitor_extract_reason "$monitor_error_path")
  return 1
}

monitor_failure_detail_json() {
  local monitor_stage=$1
  local monitor_reason=$2
  /usr/bin/jq -cn \
    --arg stage "$monitor_stage" \
    --arg failure_reason "$monitor_reason" \
    '{failure_stage:$stage,failure_reason:$failure_reason,rule_suite_result:"UNPROVEN_NO_ADMIN_READ"}'
}

monitor_fail_unverified() {
  local monitor_stage=$1
  local monitor_reason=$2
  monitor_set_detected_result \
    MONITOR_UNVERIFIED \
    "$monitor_reason" \
    "$(monitor_failure_detail_json "$monitor_stage" "$monitor_reason")"
  return 1
}

monitor_fail_drift() {
  local monitor_stage=$1
  local monitor_reason=$2
  monitor_set_detected_result \
    DRIFT_DENY \
    "$monitor_reason" \
    "$(monitor_failure_detail_json "$monitor_stage" "$monitor_reason")"
  return 1
}

monitor_policy_prepare_is_drift_reason() {
  case "$1" in
    *"digest drifted"* | \
    *"identity drifted"* | \
    *"digest, owner, or mode drifted" | \
    *"seal is incomplete" | \
    *"owner must equal"* | \
    *"mode must be "* | \
    *"must use the pinned GitHub "*)
      return 0
      ;;
  esac
  return 1
}

monitor_config_seal_is_drift_reason() {
  case "$1" in
    *"owner must equal the effective UID"* | \
    *"mode must be 600"* | \
    *"digest drifted after acceptance"*)
      return 0
      ;;
  esac
  return 1
}

monitor_runtime_seal_is_drift_reason() {
  case "$1" in
    *"digest, owner, or mode drifted" | \
    *"seal is incomplete")
      return 0
      ;;
  esac
  return 1
}

monitor_note_signal_failure() {
  local monitor_signal_reason=$1
  if [ -z "${MONITOR_DETECTED_VERDICT:-}" ]; then
    monitor_fail_unverified signal "$monitor_signal_reason" >/dev/null 2>&1 || true
  fi
}

monitor_token_verify_is_drift_reason() {
  case "$1" in
    "installation token scope or repository set is invalid" | \
    "installation token expiry is outside the accepted window")
      return 0
      ;;
  esac
  return 1
}

monitor_remote_verify_is_drift_reason() {
  case "$1" in
    "repository metadata did not match the pinned repository" | \
    "installation repository scope changed" | \
    "readable ruleset ids did not exactly match policy" | \
    "readable ruleset definition did not match policy" | \
    "readable main tip no longer matches the accepted base" | \
    "representative destination ref already exists" | \
    "readable tag count drifted" | \
    "readable release count drifted" | \
    "ruleset definitions drifted from the owner-sealed baseline" | \
    "main effective rules drifted from the owner-sealed baseline" | \
    "generated-branch effective rules drifted from the owner-sealed baseline")
      return 0
      ;;
  esac
  return 1
}

monitor_finalize_result() {
  if [ -z "${MONITOR_DETECTED_VERDICT:-}" ]; then
    monitor_set_detected_result \
      MONITOR_UNVERIFIED \
      "drift monitor exited before a terminal result" \
      '{"failure_stage":"cleanup","failure_reason":"drift monitor exited before a terminal result","rule_suite_result":"UNPROVEN_NO_ADMIN_READ"}'
  fi
  monitor_set_result \
    "$MONITOR_DETECTED_VERDICT" \
    "$MONITOR_DETECTED_REASON" \
    "$MONITOR_DETECTED_DETAIL_JSON"
  if [ "${MONITOR_DETECTED_VERDICT:-MONITOR_UNVERIFIED}" != DRIFT_DENY ] &&
    {
      [ "${MONITOR_REVOKE_RESULT:-NOT_ATTEMPTED}" = UNPROVEN ] ||
      [ "${MONITOR_AUDIT_RESULT:-NOT_ATTEMPTED}" = FAILED ]
    }; then
    MONITOR_RESULT_VERDICT=MONITOR_UNVERIFIED
  fi
  return 0
}

monitor_status_main() {
  [ "$#" -eq 2 ] && [ "$1" = "--config" ] ||
    { guard_fail "status accepts only --config ABSOLUTE_PATH"; exit 1; }
  monitor_load_config "$2"
  monitor_emit_status_json
}

cleanup_monitor() {
  monitor_exit_status=$?
  trap - EXIT HUP INT TERM
  if [ "${MONITOR_READ_TOKEN_MINTED:-false}" = true ]; then
    MONITOR_REVOKE_ATTEMPTED=true
    if [ "${MONITOR_READ_TOKEN_REVOKE_READY:-false}" = true ] &&
      [ -n "${MONITOR_READ_TOKEN:-}" ]; then
      if publisher_revoke_token "$MONITOR_READ_TOKEN" >/dev/null 2>&1; then
        MONITOR_REVOKE_RESULT=VERIFIED
      else
        MONITOR_REVOKE_RESULT=UNPROVEN
        MONITOR_REVOKE_REASON="read installation token revocation was not proven"
      fi
    else
      MONITOR_REVOKE_RESULT=UNPROVEN
      MONITOR_REVOKE_REASON="read installation token could not be safely represented for revocation"
    fi
  fi
  MONITOR_READ_TOKEN=
  MONITOR_READ_TOKEN_MINTED=false
  MONITOR_READ_TOKEN_REVOKE_READY=false
  if [ -n "${MONITOR_TMP:-}" ]; then
    /bin/rm -rf "$MONITOR_TMP" >/dev/null 2>&1 || true
  fi
  monitor_finalize_result || true
  MONITOR_AUDIT_ATTEMPTED=false
  MONITOR_AUDIT_RESULT=NOT_ATTEMPTED
  MONITOR_AUDIT_REASON=
  monitor_result_json=$(monitor_emit_result_json)
  if [ -n "${PUBLISH_TRUSTED_AUDIT_DIR:-}" ]; then
    MONITOR_AUDIT_ATTEMPTED=true
    MONITOR_AUDIT_RESULT=APPEND_REQUESTED
    monitor_result_json=$(monitor_emit_result_json)
    if ! publisher_append_audit_json "$PUBLISH_TRUSTED_AUDIT_DIR" "$MONITOR_RUN_ID" \
      "$monitor_result_json" >/dev/null 2>&1; then
      MONITOR_AUDIT_RESULT=FAILED
      MONITOR_AUDIT_REASON="audit append failed"
    else
      MONITOR_AUDIT_RESULT=APPENDED
    fi
  fi
  monitor_finalize_result || true
  monitor_result_json=$(monitor_emit_result_json)
  /usr/bin/printf '%s\n' "$monitor_result_json"
  if [ "$monitor_exit_status" -eq 0 ] &&
    [ "${MONITOR_RESULT_VERDICT:-}" = MATCH ]; then
    exit 0
  fi
  exit 1
}

monitor_run_main() {
  [ "$#" -eq 2 ] && [ "$1" = "--config" ] ||
    { guard_fail "run accepts only --config ABSOLUTE_PATH"; exit 1; }
  MONITOR_RUN_ID=MON-$(/bin/date -u +%Y%m%dT%H%M%SZ)-$$
  trap cleanup_monitor EXIT
  trap 'monitor_note_signal_failure "drift monitor received SIGHUP"; exit 129' HUP
  trap 'monitor_note_signal_failure "drift monitor received SIGINT"; exit 130' INT
  trap 'monitor_note_signal_failure "drift monitor received SIGTERM"; exit 143' TERM

  MONITOR_TMP=$(/usr/bin/mktemp -d /tmp/nightshift-drift-monitor.XXXXXX)
  MONITOR_TMP=$(CDPATH='' cd -- "$MONITOR_TMP" && pwd -P)
  monitor_error_path=$MONITOR_TMP/error.txt

  if ! monitor_try "$monitor_error_path" monitor_load_config "$2"; then
    monitor_fail_unverified config "$MONITOR_LAST_ERROR" || true
    return 1
  fi
  if [ "$MONITOR_CONFIG_MODE" != ACTIVE ]; then
    monitor_set_detected_result MONITOR_UNVERIFIED \
      "checked-in drift monitor config remains inactive before key or network access" \
      '{"network_access":false,"key_access":false,"rule_suite_result":"UNPROVEN_NO_ADMIN_READ"}'
    return 1
  fi
  if ! monitor_try "$monitor_error_path" monitor_require_active_config_seal; then
    if monitor_config_seal_is_drift_reason "$MONITOR_LAST_ERROR"; then
      monitor_fail_drift config_seal "$MONITOR_LAST_ERROR" || true
    else
      monitor_fail_unverified config_seal "$MONITOR_LAST_ERROR" || true
    fi
    return 1
  fi
  if ! monitor_try "$monitor_error_path" publisher_load_policy "$MONITOR_PUBLISHER_POLICY_PATH"; then
    monitor_fail_unverified policy_load "$MONITOR_LAST_ERROR" || true
    return 1
  fi
  PUBLISH_REPO_ID=$PUBLISH_POLICY_REPO_ID
  PUBLISH_REPOSITORY_ID=$PUBLISH_POLICY_REPOSITORY_ID
  [ "$PUBLISH_POLICY_DIGEST" = "$MONITOR_PUBLISHER_POLICY_SHA256" ] || {
    monitor_fail_drift policy_digest "publisher policy digest does not match drift monitor config" || true
    return 1
  }
  if ! monitor_try "$monitor_error_path" \
    publisher_verify_sealed_runtime_path \
    "$GUARD_DIR/drift-monitor.sh" \
    "drift monitor program" \
    "$(builtin printf '%s' "$MONITOR_RUNTIME_JSON" |
      /usr/bin/jq -c '.programs.drift_monitor')"; then
    if monitor_runtime_seal_is_drift_reason "$MONITOR_LAST_ERROR"; then
      monitor_fail_drift runtime "$MONITOR_LAST_ERROR" || true
    else
      monitor_fail_unverified runtime "$MONITOR_LAST_ERROR" || true
    fi
    return 1
  fi
  if ! monitor_try "$monitor_error_path" publisher_prepare_active_policy; then
    if monitor_policy_prepare_is_drift_reason "$MONITOR_LAST_ERROR"; then
      monitor_fail_drift policy_prepare "$MONITOR_LAST_ERROR" || true
    else
      monitor_fail_unverified policy_prepare "$MONITOR_LAST_ERROR" || true
    fi
    return 1
  fi

  publisher_disable_secret_leak_paths

  monitor_app_json=$MONITOR_TMP/app.json
  monitor_hook_json=$MONITOR_TMP/app-hook.json
  monitor_installation_json=$MONITOR_TMP/installation.json
  monitor_headers=$MONITOR_TMP/headers.txt
  monitor_main_ref_json=$MONITOR_TMP/main-ref.json
  monitor_remote_tmp=$MONITOR_TMP/remote
  /bin/mkdir -p "$monitor_remote_tmp"

  publisher_jwt=$(publisher_generate_jwt "$PUBLISH_PRIVATE_KEY_PATH" "$PUBLISH_APP_ID") || {
    monitor_fail_unverified auth "JWT signing failed" || true
    return 1
  }
  if ! monitor_try "$monitor_error_path" \
    publisher_api_request GET "$PUBLISH_API_BASE/app" \
    "$publisher_jwt" '' 200 "$monitor_app_json" "$monitor_headers"; then
    monitor_fail_unverified app_read "$MONITOR_LAST_ERROR" || true
    return 1
  fi
  if ! monitor_try "$monitor_error_path" \
    publisher_verify_app_identity_json "$monitor_app_json" "$MONITOR_EXPECTED_APP_SLUG"; then
    monitor_fail_drift app_verify "$MONITOR_LAST_ERROR" || true
    return 1
  fi
  monitor_app_slug=$(/usr/bin/jq -er '.slug' "$monitor_app_json") || {
    monitor_fail_unverified app_verify "GitHub App response omitted a slug" || true
    return 1
  }
  if ! monitor_try "$monitor_error_path" \
    publisher_api_request GET "$PUBLISH_API_BASE/app/hook/config" \
    "$publisher_jwt" '' 200 "$monitor_hook_json" "$monitor_headers"; then
    monitor_fail_unverified hook_read "$MONITOR_LAST_ERROR" || true
    return 1
  fi
  if ! monitor_try "$monitor_error_path" \
    publisher_verify_webhook_config_json "$monitor_hook_json"; then
    monitor_fail_drift hook_verify "$MONITOR_LAST_ERROR" || true
    return 1
  fi
  if ! monitor_try "$monitor_error_path" \
    publisher_api_request GET "$PUBLISH_API_BASE/app/installations/$PUBLISH_INSTALLATION_ID" \
    "$publisher_jwt" '' 200 "$monitor_installation_json" "$monitor_headers"; then
    monitor_fail_unverified installation_read "$MONITOR_LAST_ERROR" || true
    return 1
  fi
  if ! monitor_try "$monitor_error_path" \
    publisher_verify_installation_identity_json \
    "$monitor_installation_json" \
    "$MONITOR_EXPECTED_INSTALLATION_ACCOUNT" \
    "$monitor_app_slug"; then
    monitor_fail_drift installation_verify "$MONITOR_LAST_ERROR" || true
    return 1
  fi
  monitor_installation_account=$(/usr/bin/jq -er '.account.login' "$monitor_installation_json") || {
    monitor_fail_unverified installation_verify "installation response omitted an account login" || true
    return 1
  }

  monitor_read_token_body=$(
    /usr/bin/jq -cn \
      --arg repository_id "$PUBLISH_REPOSITORY_ID" \
      '{repository_ids:[($repository_id | tonumber)],permissions:{contents:"read"}}'
  )
  if ! monitor_read_token_json=$(
    publisher_api_request_memory POST \
      "$PUBLISH_API_BASE/app/installations/$PUBLISH_INSTALLATION_ID/access_tokens" \
      "$publisher_jwt" "$monitor_read_token_body" 201 2> "$monitor_error_path"
  ); then
    MONITOR_LAST_ERROR=$(monitor_extract_reason "$monitor_error_path")
    monitor_fail_unverified token_mint "$MONITOR_LAST_ERROR" || true
    return 1
  fi
  MONITOR_READ_TOKEN_MINTED=true
  MONITOR_READ_TOKEN_REVOKE_READY=false
  MONITOR_READ_TOKEN=$(publisher_extract_header_safe_installation_token "$monitor_read_token_json" read 2> "$monitor_error_path") || {
    MONITOR_LAST_ERROR=$(monitor_extract_reason "$monitor_error_path")
    monitor_fail_unverified token_mint "$MONITOR_LAST_ERROR" || true
    return 1
  }
  MONITOR_READ_TOKEN_REVOKE_READY=true
  if ! monitor_try "$monitor_error_path" \
    publisher_verify_installation_token_response "$monitor_read_token_json" read; then
    if monitor_token_verify_is_drift_reason "$MONITOR_LAST_ERROR"; then
      monitor_fail_drift token_verify "$MONITOR_LAST_ERROR" || true
    else
      monitor_fail_unverified token_verify "$MONITOR_LAST_ERROR" || true
    fi
    return 1
  fi

  monitor_main_ref_path=${PUBLISH_MAIN_BRANCH#refs/heads/}
  if ! monitor_try "$monitor_error_path" \
    publisher_api_request GET \
    "$PUBLISH_API_BASE/repos/$PUBLISH_REPO_ID/git/ref/heads/$monitor_main_ref_path" \
    "$MONITOR_READ_TOKEN" '' 200 "$monitor_main_ref_json" "$monitor_headers"; then
    monitor_fail_unverified main_ref "$MONITOR_LAST_ERROR" || true
    return 1
  fi
  PUBLISH_BASE_SHA=$(/usr/bin/jq -er '.object.sha' "$monitor_main_ref_json") || {
    monitor_fail_unverified main_ref "readable main tip response omitted an object SHA" || true
    return 1
  }
  PUBLISH_DESTINATION_REF=$MONITOR_REPRESENTATIVE_REF
  if ! monitor_remote_json=$(
    publisher_verify_remote_state read "$MONITOR_READ_TOKEN" "$monitor_remote_tmp" \
      2> "$monitor_error_path"
  ); then
    MONITOR_LAST_ERROR=$(monitor_extract_reason "$monitor_error_path")
    if monitor_remote_verify_is_drift_reason "$MONITOR_LAST_ERROR"; then
      monitor_fail_drift remote_verify "$MONITOR_LAST_ERROR" || true
    else
      monitor_fail_unverified remote_verify "$MONITOR_LAST_ERROR" || true
    fi
    return 1
  fi

  monitor_detail_json=$(
    /usr/bin/jq -cn \
      --arg app_slug "$monitor_app_slug" \
      --arg installation_account "$monitor_installation_account" \
      --arg representative_ref "$MONITOR_REPRESENTATIVE_REF" \
      --arg policy_mode "$PUBLISH_POLICY_MODE" \
      --arg publisher_write_mode "$PUBLISH_WRITE_MODE" \
      --argjson remote "$monitor_remote_json" '
      {
        app_slug:$app_slug,
        installation_account:$installation_account,
        representative_ref:$representative_ref,
        publisher_policy_mode:$policy_mode,
        publisher_write_mode:($publisher_write_mode == "true"),
        webhook_disabled_url_repr_verified:true,
        oauth_user_auth_result:"UNPROVEN_MANUAL_OWNER_BASELINE",
        policy_runtime_verified:true,
        rule_suite_result:"UNPROVEN_NO_ADMIN_READ",
        remote:$remote
      }'
  )
  monitor_set_detected_result MATCH \
    "read-only drift monitor matched all sealed invariants" \
    "$monitor_detail_json"
  return 0
}

main() {
  [ "$#" -ge 1 ] || { guard_fail "usage: drift-monitor.sh <status|run> --config ABSOLUTE_PATH"; exit 1; }
  command=$1
  shift
  case "$command" in
    status) monitor_status_main "$@" ;;
    run) monitor_run_main "$@" ;;
    *)
      guard_fail "unknown drift monitor command"
      exit 1
      ;;
  esac
}

main "$@"
