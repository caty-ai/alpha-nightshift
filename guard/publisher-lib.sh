#!/bin/bash
set -euo pipefail

PUBLISH_POLICY_PATH=
PUBLISH_REQUEST_PATH=
PUBLISH_REPO_PATH=
PUBLISH_GIT_DIR=
PUBLISH_OBJECT_DIRECTORY=
PUBLISH_SCRATCH_GIT_DIR=
PUBLISH_POLICY_DIGEST=
PUBLISH_REQUEST_DIGEST=
PUBLISH_REQUEST_ID=
PUBLISH_REPO_ID=
PUBLISH_REPOSITORY_ID=
PUBLISH_BASE_SHA=
PUBLISH_CANDIDATE_SHA=
PUBLISH_REQUEST_POLICY_SHA256=
PUBLISH_DESTINATION_REF=
PUBLISH_POLICY_MODE=
PUBLISH_WRITE_MODE=
PUBLISH_POLICY_REPO_ID=
PUBLISH_POLICY_REPOSITORY_ID=
PUBLISH_APP_ID=
PUBLISH_INSTALLATION_ID=
PUBLISH_API_BASE=
PUBLISH_GIT_REMOTE_BASE=
PUBLISH_PRIVATE_KEY_PATH=
PUBLISH_PRIVATE_KEY_SHA256=
PUBLISH_AUDIT_DIR=
PUBLISH_AUDIT_DIR_IDENTITY_SHA256=
PUBLISH_SCAN_MANIFEST_PATH=
PUBLISH_RULESET_IDS_JSON=
PUBLISH_EXPECTED_RULESET_DEFINITIONS_SHA256=
PUBLISH_EXPECTED_MAIN_RULES_SHA256=
PUBLISH_EXPECTED_DESTINATION_RULES_SHA256=
PUBLISH_MAIN_BRANCH=
PUBLISH_GENERATED_BRANCH_PREFIX=
PUBLISH_EXPECTED_REPOSITORY_PRIVATE=
PUBLISH_EXPECTED_REPOSITORY_SELECTION=
PUBLISH_EXPECTED_METADATA_PERMISSION=
PUBLISH_EXPECTED_TAGS_COUNT=
PUBLISH_EXPECTED_RELEASES_COUNT=
PUBLISH_PUBLISHER_EUID=
PUBLISH_RUNTIME_JSON=

publisher_urlencode() {
  builtin printf '%s' "$1" | /usr/bin/jq -sRr @uri
}

publisher_request_exact_keys='["schema","operation","request_id","repo_id","repository_id","base_sha","candidate_sha","policy_sha256"]'
publisher_policy_exact_keys='["schema","mode","write_mode","repo_id","repository_id","app_id","installation_id","api_base","git_remote_base","private_key_path","private_key_sha256","audit_dir","audit_dir_identity_sha256","scan_manifest_path","publisher_euid","runtime","rulesets","expected"]'

publisher_load_request() {
  PUBLISH_REQUEST_PATH=$1
  publisher_request_digest_before=$(guard_json_sha256 "$PUBLISH_REQUEST_PATH") || return 1
  guard_json_no_duplicate_paths "$PUBLISH_REQUEST_PATH" || return 1
  guard_json_exact_keys "$PUBLISH_REQUEST_PATH" "$publisher_request_exact_keys" || return 1
  /usr/bin/jq -e '
    .schema == "alpha-nightshift/publish-request/v1" and
    .operation == "publish_branch" and
    (.request_id | type == "string") and
    (.repo_id | type == "string") and
    (.repository_id | type == "number" and floor == . and . > 0) and
    (.base_sha | type == "string") and
    (.candidate_sha | type == "string") and
    (.policy_sha256 | type == "string")
  ' "$PUBLISH_REQUEST_PATH" >/dev/null ||
    { guard_fail "publish request grammar is invalid"; return 1; }
  PUBLISH_REQUEST_ID=$(/usr/bin/jq -r '.request_id' "$PUBLISH_REQUEST_PATH")
  PUBLISH_REPO_ID=$(/usr/bin/jq -r '.repo_id' "$PUBLISH_REQUEST_PATH")
  PUBLISH_REPOSITORY_ID=$(/usr/bin/jq -r '.repository_id' "$PUBLISH_REQUEST_PATH")
  PUBLISH_BASE_SHA=$(/usr/bin/jq -r '.base_sha' "$PUBLISH_REQUEST_PATH")
  PUBLISH_CANDIDATE_SHA=$(/usr/bin/jq -r '.candidate_sha' "$PUBLISH_REQUEST_PATH")
  PUBLISH_REQUEST_POLICY_SHA256=$(/usr/bin/jq -r '.policy_sha256' "$PUBLISH_REQUEST_PATH")
  publisher_request_digest_after=$(guard_json_sha256 "$PUBLISH_REQUEST_PATH") || return 1
  [ "$publisher_request_digest_before" = "$publisher_request_digest_after" ] ||
    { guard_fail "publish request changed while being accepted"; return 1; }
  # shellcheck disable=SC2034 # consumed by publisher.sh and remote-preflight.sh
  PUBLISH_REQUEST_DIGEST=$publisher_request_digest_before

  guard_validate_request_id "$PUBLISH_REQUEST_ID" || return 1
  guard_validate_repo_id "$PUBLISH_REPO_ID" || return 1
  guard_validate_positive_integer "$PUBLISH_REPOSITORY_ID" || return 1
  guard_validate_nonzero_sha "$PUBLISH_BASE_SHA" || return 1
  guard_validate_nonzero_sha "$PUBLISH_CANDIDATE_SHA" || return 1
  LC_ALL=C /usr/bin/printf '%s\n' "$PUBLISH_REQUEST_POLICY_SHA256" |
    /usr/bin/grep -E '^[a-f0-9]{64}$' >/dev/null ||
    { guard_fail "policy digest must be 64 hex"; return 1; }

  request_date=${PUBLISH_REQUEST_ID#REQ-}
  request_date=${request_date%%-*}
  request_tail=${PUBLISH_REQUEST_ID#REQ-"$request_date"-}
  request_seq=${request_tail%%-*}
  request_hex=${PUBLISH_REQUEST_ID##*-}
  request_hex8=${request_hex%????????}
  PUBLISH_DESTINATION_REF="refs/heads/night-bot/run-$request_date-$request_seq-$request_hex8"
}

publisher_load_policy() {
  PUBLISH_POLICY_PATH=$1
  publisher_policy_digest_before=$(guard_json_sha256 "$PUBLISH_POLICY_PATH") || return 1
  guard_json_no_duplicate_paths "$PUBLISH_POLICY_PATH" || return 1
  guard_json_exact_keys "$PUBLISH_POLICY_PATH" "$publisher_policy_exact_keys" || return 1
  /usr/bin/jq -e '
    .schema == "alpha-nightshift/publisher-policy/v1" and
    (.mode | type == "string" and (. == "INACTIVE" or . == "ACTIVE")) and
    (.write_mode | type == "boolean") and
    (.repo_id | type == "string") and
    (.repository_id | type == "number" and floor == . and . >= 0) and
    (.app_id | type == "number" and floor == . and . >= 0) and
    (.installation_id | type == "number" and floor == . and . >= 0) and
    (.api_base | type == "string") and
    (.git_remote_base | type == "string") and
    ((.private_key_path == null) or (.private_key_path | type == "string")) and
    ((.private_key_sha256 == null) or
      (.private_key_sha256 | type == "string" and test("^[a-f0-9]{64}$"))) and
    ((.audit_dir == null) or (.audit_dir | type == "string")) and
    ((.audit_dir_identity_sha256 == null) or
      (.audit_dir_identity_sha256 | type == "string" and test("^[a-f0-9]{64}$"))) and
    ((.scan_manifest_path == null) or (.scan_manifest_path | type == "string")) and
    (.publisher_euid | type == "number" and floor == . and . >= 0) and
    (.runtime | type == "object") and
    ((.runtime | keys | sort) == ["programs","tools"]) and
    ((.runtime.tools | keys | sort) == ["bash","curl","git","gitleaks","jq","openssl"]) and
    ((.runtime.programs | keys | sort) == ["askpass","common","publisher","publisher_lib","remote_preflight","scan"]) and
    (all(.runtime.tools[],.runtime.programs[];
      (keys | sort) == ["mode","sha256","uid"] and
      ((.sha256 == null) or (.sha256 | type == "string" and test("^[a-f0-9]{64}$"))) and
      ((.uid == null) or (.uid | type == "number" and floor == . and . >= 0)) and
      ((.mode == null) or (.mode | type == "string" and test("^[0-7]{3,4}$")))
    )) and
    (.rulesets | type == "object") and
    (.expected | type == "object") and
    ((.rulesets | keys | sort) == ["expected","generated_branch_prefix","ids","main_branch"]) and
    ((.rulesets.expected | keys | sort) ==
      ["definitions_sha256","generated_effective_sha256","main_effective_sha256"]) and
    (all(
      .rulesets.expected.definitions_sha256,
      .rulesets.expected.main_effective_sha256,
      .rulesets.expected.generated_effective_sha256;
      . == null or (type == "string" and test("^[a-f0-9]{64}$"))
    )) and
    ((.expected | keys | sort) == ["permissions","releases_count","repository_private","repository_selection","tags_count"]) and
    ((.expected.permissions | keys | sort) == ["contents","metadata"]) and
    ((.rulesets.ids | type == "array") and
      (.rulesets.ids | length <= 32) and
      (.rulesets.ids | length == (unique | length)) and
      all(.rulesets.ids[]?; type == "number" and floor == . and . > 0)) and
    (.rulesets.main_branch == "main") and
    (.rulesets.generated_branch_prefix | type == "string" and . == "night-bot/run-") and
    (.expected.repository_private == true) and
    (.expected.repository_selection == "selected") and
    (.expected.permissions | type == "object") and
    (.expected.permissions.metadata == "read") and
    (.expected.permissions.contents == "write") and
    (.expected.tags_count == 0) and
    (.expected.releases_count == 0)
  ' "$PUBLISH_POLICY_PATH" >/dev/null ||
    { guard_fail "publisher policy schema is invalid"; return 1; }

  PUBLISH_POLICY_MODE=$(/usr/bin/jq -r '.mode' "$PUBLISH_POLICY_PATH")
  PUBLISH_WRITE_MODE=$(/usr/bin/jq -r '.write_mode' "$PUBLISH_POLICY_PATH")
  PUBLISH_POLICY_REPO_ID=$(/usr/bin/jq -r '.repo_id' "$PUBLISH_POLICY_PATH")
  PUBLISH_POLICY_REPOSITORY_ID=$(/usr/bin/jq -r '.repository_id' "$PUBLISH_POLICY_PATH")
  PUBLISH_APP_ID=$(/usr/bin/jq -r '.app_id' "$PUBLISH_POLICY_PATH")
  PUBLISH_INSTALLATION_ID=$(/usr/bin/jq -r '.installation_id' "$PUBLISH_POLICY_PATH")
  PUBLISH_API_BASE=$(/usr/bin/jq -r '.api_base' "$PUBLISH_POLICY_PATH")
  PUBLISH_GIT_REMOTE_BASE=$(/usr/bin/jq -r '.git_remote_base' "$PUBLISH_POLICY_PATH")
  PUBLISH_PRIVATE_KEY_PATH=$(/usr/bin/jq -r '.private_key_path // ""' "$PUBLISH_POLICY_PATH")
  PUBLISH_PRIVATE_KEY_SHA256=$(/usr/bin/jq -r '.private_key_sha256 // ""' "$PUBLISH_POLICY_PATH")
  PUBLISH_AUDIT_DIR=$(/usr/bin/jq -r '.audit_dir // ""' "$PUBLISH_POLICY_PATH")
  PUBLISH_AUDIT_DIR_IDENTITY_SHA256=$(
    /usr/bin/jq -r '.audit_dir_identity_sha256 // ""' "$PUBLISH_POLICY_PATH"
  )
  PUBLISH_SCAN_MANIFEST_PATH=$(/usr/bin/jq -r '.scan_manifest_path // ""' "$PUBLISH_POLICY_PATH")
  PUBLISH_PUBLISHER_EUID=$(/usr/bin/jq -r '.publisher_euid' "$PUBLISH_POLICY_PATH")
  PUBLISH_RUNTIME_JSON=$(/usr/bin/jq -c '.runtime' "$PUBLISH_POLICY_PATH")
  PUBLISH_RULESET_IDS_JSON=$(/usr/bin/jq -c '.rulesets.ids' "$PUBLISH_POLICY_PATH")
  PUBLISH_EXPECTED_RULESET_DEFINITIONS_SHA256=$(
    /usr/bin/jq -r '.rulesets.expected.definitions_sha256 // ""' "$PUBLISH_POLICY_PATH"
  )
  PUBLISH_EXPECTED_MAIN_RULES_SHA256=$(
    /usr/bin/jq -r '.rulesets.expected.main_effective_sha256 // ""' "$PUBLISH_POLICY_PATH"
  )
  PUBLISH_EXPECTED_DESTINATION_RULES_SHA256=$(
    /usr/bin/jq -r '.rulesets.expected.generated_effective_sha256 // ""' "$PUBLISH_POLICY_PATH"
  )
  PUBLISH_MAIN_BRANCH=$(/usr/bin/jq -r '.rulesets.main_branch' "$PUBLISH_POLICY_PATH")
  PUBLISH_GENERATED_BRANCH_PREFIX=$(/usr/bin/jq -r '.rulesets.generated_branch_prefix' "$PUBLISH_POLICY_PATH")
  PUBLISH_EXPECTED_REPOSITORY_PRIVATE=$(/usr/bin/jq -r '.expected.repository_private' "$PUBLISH_POLICY_PATH")
  PUBLISH_EXPECTED_REPOSITORY_SELECTION=$(/usr/bin/jq -r '.expected.repository_selection' "$PUBLISH_POLICY_PATH")
  PUBLISH_EXPECTED_METADATA_PERMISSION=$(/usr/bin/jq -r '.expected.permissions.metadata' "$PUBLISH_POLICY_PATH")
  PUBLISH_EXPECTED_TAGS_COUNT=$(/usr/bin/jq -r '.expected.tags_count' "$PUBLISH_POLICY_PATH")
  PUBLISH_EXPECTED_RELEASES_COUNT=$(/usr/bin/jq -r '.expected.releases_count' "$PUBLISH_POLICY_PATH")
  publisher_policy_digest_after=$(guard_json_sha256 "$PUBLISH_POLICY_PATH") || return 1
  [ "$publisher_policy_digest_before" = "$publisher_policy_digest_after" ] ||
    { guard_fail "publisher policy changed while being accepted"; return 1; }
  PUBLISH_POLICY_DIGEST=$publisher_policy_digest_before

  guard_validate_repo_id "$PUBLISH_POLICY_REPO_ID" || return 1
  case "$PUBLISH_EXPECTED_TAGS_COUNT" in
    0|[1-9][0-9]*) ;;
    *) guard_fail "expected tag count is malformed"; return 1 ;;
  esac
  case "$PUBLISH_EXPECTED_RELEASES_COUNT" in
    0|[1-9][0-9]*) ;;
    *) guard_fail "expected release count is malformed"; return 1 ;;
  esac
}

publisher_validate_repo_state() {
  PUBLISH_REPO_PATH=$1
  guard_validate_absolute_path "$PUBLISH_REPO_PATH" dir || return 1
  PUBLISH_GIT_DIR=$(guard_git_dir_for_repo "$PUBLISH_REPO_PATH") || return 1
  guard_validate_absolute_path "$PUBLISH_GIT_DIR" dir || return 1
  publisher_common_dir=$(
    guard_hardened_git "$PUBLISH_GIT_DIR" \
      rev-parse --path-format=absolute --git-common-dir
  ) || { guard_fail "repository common Git directory is unavailable"; return 1; }
  guard_validate_absolute_path "$publisher_common_dir" dir || return 1
  PUBLISH_OBJECT_DIRECTORY=$publisher_common_dir/objects
  guard_validate_absolute_path "$PUBLISH_OBJECT_DIRECTORY" dir || return 1
  [ "$PUBLISH_REPO_ID" = "$PUBLISH_POLICY_REPO_ID" ] ||
    { guard_fail "request repo id does not match policy"; return 1; }
  [ "$PUBLISH_REPOSITORY_ID" = "$PUBLISH_POLICY_REPOSITORY_ID" ] ||
    { guard_fail "request repository id does not match policy"; return 1; }
  [ "$PUBLISH_REQUEST_POLICY_SHA256" = "$PUBLISH_POLICY_DIGEST" ] ||
    { guard_fail "request policy digest does not match the selected policy"; return 1; }
  base_type=$(guard_hardened_git "$PUBLISH_GIT_DIR" cat-file -t "$PUBLISH_BASE_SHA" 2>/dev/null) ||
    { guard_fail "base object is unavailable"; return 1; }
  candidate_type=$(guard_hardened_git "$PUBLISH_GIT_DIR" cat-file -t "$PUBLISH_CANDIDATE_SHA" 2>/dev/null) ||
    { guard_fail "candidate object is unavailable"; return 1; }
  [ "$base_type" = commit ] || { guard_fail "base object must be a commit"; return 1; }
  [ "$candidate_type" = commit ] || { guard_fail "candidate object must be a commit"; return 1; }
  guard_hardened_git "$PUBLISH_GIT_DIR" merge-base --is-ancestor \
    "$PUBLISH_BASE_SHA" "$PUBLISH_CANDIDATE_SHA" >/dev/null 2>&1 ||
    { guard_fail "base must be an ancestor of candidate"; return 1; }
}

publisher_policy_is_active() {
  [ "$PUBLISH_POLICY_MODE" = ACTIVE ] && [ "$PUBLISH_WRITE_MODE" = true ]
}

publisher_emit_status_json() {
  /usr/bin/jq -cn \
    --arg mode "$GUARD_MODE" \
    --arg policy_mode "$PUBLISH_POLICY_MODE" \
    --arg policy_sha256 "$PUBLISH_POLICY_DIGEST" \
    --arg repo_id "$PUBLISH_POLICY_REPO_ID" \
    --argjson repository_id "$PUBLISH_POLICY_REPOSITORY_ID" \
    --arg destination_prefix "$PUBLISH_GENERATED_BRANCH_PREFIX" \
    --argjson write_mode "$PUBLISH_WRITE_MODE" \
    '{
      schema:"alpha-nightshift/publisher-status/v1",
      mode:$mode,
      policy_mode:$policy_mode,
      write_mode:$write_mode,
      repo_id:$repo_id,
      repository_id:$repository_id,
      generated_branch_prefix:$destination_prefix,
      policy_sha256:$policy_sha256,
      live_credentials:false,
      network_access:false
    }'
}

publisher_emit_publish_json() {
  publisher_verdict=$1
  publisher_reason=$2
  publisher_detail_json=${3:-'{}'}
  /usr/bin/jq -cn \
    --arg mode "$GUARD_MODE" \
    --arg verdict "$publisher_verdict" \
    --arg reason "$publisher_reason" \
    --arg request_id "$PUBLISH_REQUEST_ID" \
    --arg repo_id "$PUBLISH_REPO_ID" \
    --argjson repository_id "$PUBLISH_REPOSITORY_ID" \
    --arg base_sha "$PUBLISH_BASE_SHA" \
    --arg candidate_sha "$PUBLISH_CANDIDATE_SHA" \
    --arg destination_ref "$PUBLISH_DESTINATION_REF" \
    --arg policy_sha256 "$PUBLISH_POLICY_DIGEST" \
    --arg policy_mode "$PUBLISH_POLICY_MODE" \
    --argjson write_mode "$PUBLISH_WRITE_MODE" \
    --argjson detail "$publisher_detail_json" '
    {
      schema:"alpha-nightshift/publish-result/v1",
      mode:$mode,
      verdict:$verdict,
      reason:$reason,
      policy_mode:$policy_mode,
      write_mode:$write_mode,
      request_id:$request_id,
      repo_id:$repo_id,
      repository_id:$repository_id,
      base_sha:$base_sha,
      candidate_sha:$candidate_sha,
      destination_ref:$destination_ref,
      policy_sha256:$policy_sha256,
      detail:$detail
    }'
}

publisher_require_owned_private_path() {
  publisher_path=$1
  publisher_label=$2
  publisher_kind=$3
  publisher_required_mode=$4
  guard_validate_absolute_path "$publisher_path" "$publisher_kind" || return 1
  publisher_uid=$(/usr/bin/stat -f '%u' "$publisher_path") ||
    { guard_fail "$publisher_label owner is unavailable"; return 1; }
  publisher_mode=$(/usr/bin/stat -f '%Lp' "$publisher_path") ||
    { guard_fail "$publisher_label mode is unavailable"; return 1; }
  [ "$publisher_uid" = "$(/usr/bin/id -u)" ] ||
    { guard_fail "$publisher_label owner must equal the publisher EUID"; return 1; }
  [ "$publisher_mode" = "$publisher_required_mode" ] ||
    { guard_fail "$publisher_label mode must be $publisher_required_mode"; return 1; }
}

publisher_audit_directory_identity_sha256() {
  publisher_identity_path=$1
  guard_validate_absolute_path "$publisher_identity_path" dir || return 1
  publisher_identity_device=$(/usr/bin/stat -f '%d' "$publisher_identity_path") || return 1
  publisher_identity_inode=$(/usr/bin/stat -f '%i' "$publisher_identity_path") || return 1
  builtin printf 'path=%s\ndevice=%s\ninode=%s\n' \
    "$publisher_identity_path" \
    "$publisher_identity_device" \
    "$publisher_identity_inode" |
    /usr/bin/shasum -a 256 |
    /usr/bin/awk '{print $1}'
}

publisher_prepare_active_policy() {
  publisher_policy_is_active ||
    { guard_fail "publisher policy is inactive"; return 1; }
  guard_validate_positive_integer "$PUBLISH_APP_ID" || return 1
  guard_validate_positive_integer "$PUBLISH_INSTALLATION_ID" || return 1
  guard_validate_positive_integer "$PUBLISH_PUBLISHER_EUID" || return 1
  [ "$PUBLISH_PUBLISHER_EUID" = "$(/usr/bin/id -u)" ] ||
    { guard_fail "publisher EUID does not match the owner-sealed policy"; return 1; }
  [ -n "$PUBLISH_PRIVATE_KEY_PATH" ] ||
    { guard_fail "active publisher policy requires a private key path"; return 1; }
  [ -n "$PUBLISH_PRIVATE_KEY_SHA256" ] ||
    { guard_fail "active publisher policy requires a private key digest"; return 1; }
  [ -n "$PUBLISH_AUDIT_DIR" ] ||
    { guard_fail "active publisher policy requires an audit directory"; return 1; }
  [ -n "$PUBLISH_AUDIT_DIR_IDENTITY_SHA256" ] ||
    { guard_fail "active publisher policy requires an audit directory identity"; return 1; }
  [ -n "$PUBLISH_SCAN_MANIFEST_PATH" ] ||
    { guard_fail "active publisher policy requires a scanner manifest"; return 1; }
  builtin printf '%s' "$PUBLISH_RULESET_IDS_JSON" |
    /usr/bin/jq -e 'length > 0' >/dev/null 2>&1 ||
    { guard_fail "active publisher policy requires one or more ruleset ids"; return 1; }
  for publisher_expected_ruleset_digest in \
    "$PUBLISH_EXPECTED_RULESET_DEFINITIONS_SHA256" \
    "$PUBLISH_EXPECTED_MAIN_RULES_SHA256" \
    "$PUBLISH_EXPECTED_DESTINATION_RULES_SHA256"; do
    LC_ALL=C /usr/bin/printf '%s\n' "$publisher_expected_ruleset_digest" |
      /usr/bin/grep -E '^[a-f0-9]{64}$' >/dev/null ||
      { guard_fail "active publisher policy requires complete ruleset content digests"; return 1; }
  done
  [ "$PUBLISH_API_BASE" = "https://api.github.com" ] ||
    { guard_fail "active publisher policy must use the pinned GitHub API"; return 1; }
  [ "$PUBLISH_GIT_REMOTE_BASE" = "https://github.com" ] ||
    { guard_fail "active publisher policy must use the pinned GitHub remote"; return 1; }
  publisher_require_owned_private_path "$PUBLISH_POLICY_PATH" "publisher policy" file 600 || return 1
  [ "$(guard_json_sha256 "$PUBLISH_POLICY_PATH")" = "$PUBLISH_POLICY_DIGEST" ] ||
    { guard_fail "publisher policy digest drifted after acceptance"; return 1; }
  publisher_require_owned_private_path "$PUBLISH_PRIVATE_KEY_PATH" "publisher private key" file 600 || return 1
  [ "$(guard_sha256 "$PUBLISH_PRIVATE_KEY_PATH")" = "$PUBLISH_PRIVATE_KEY_SHA256" ] ||
    { guard_fail "publisher private key content digest drifted"; return 1; }
  publisher_require_owned_private_path "$PUBLISH_AUDIT_DIR" "publisher audit directory" dir 700 || return 1
  [ "$(publisher_audit_directory_identity_sha256 "$PUBLISH_AUDIT_DIR")" = \
    "$PUBLISH_AUDIT_DIR_IDENTITY_SHA256" ] ||
    { guard_fail "publisher audit directory identity drifted"; return 1; }
  publisher_require_owned_private_path \
    "$PUBLISH_SCAN_MANIFEST_PATH" "publisher scanner manifest" file 600 || return 1
  publisher_require_owned_private_path "$GUARD_DIR" "publisher program directory" dir 700 || return 1
  for publisher_runtime_name in bash curl git gitleaks jq openssl; do
    case "$publisher_runtime_name" in
      bash) publisher_runtime_path=/bin/bash ;;
      curl) publisher_runtime_path=$GUARD_CURL_BIN ;;
      git) publisher_runtime_path=$GUARD_GIT_BIN ;;
      gitleaks) publisher_runtime_path=$GUARD_GITLEAKS_BIN ;;
      jq) publisher_runtime_path=/usr/bin/jq ;;
      openssl) publisher_runtime_path=$GUARD_OPENSSL_BIN ;;
    esac
    publisher_verify_sealed_runtime_path \
      "$publisher_runtime_path" \
      "$publisher_runtime_name tool" \
      "$(builtin printf '%s' "$PUBLISH_RUNTIME_JSON" |
        /usr/bin/jq -c --arg name "$publisher_runtime_name" '.tools[$name]')" || return 1
  done
  for publisher_runtime_name in askpass common publisher publisher_lib remote_preflight scan; do
    case "$publisher_runtime_name" in
      askpass) publisher_runtime_path=$GUARD_DIR/publisher-askpass.sh ;;
      common) publisher_runtime_path=$GUARD_DIR/common.sh ;;
      publisher) publisher_runtime_path=$GUARD_DIR/publisher.sh ;;
      publisher_lib) publisher_runtime_path=$GUARD_DIR/publisher-lib.sh ;;
      remote_preflight) publisher_runtime_path=$GUARD_DIR/remote-preflight.sh ;;
      scan) publisher_runtime_path=$GUARD_DIR/scan.sh ;;
    esac
    publisher_verify_sealed_runtime_path \
      "$publisher_runtime_path" \
      "$publisher_runtime_name program" \
      "$(builtin printf '%s' "$PUBLISH_RUNTIME_JSON" |
        /usr/bin/jq -c --arg name "$publisher_runtime_name" '.programs[$name]')" || return 1
  done
}

publisher_verify_sealed_runtime_path() {
  publisher_runtime_path=$1
  publisher_runtime_label=$2
  publisher_runtime_spec=$3
  guard_validate_absolute_path "$publisher_runtime_path" executable || return 1
  publisher_runtime_expected_sha=$(
    builtin printf '%s' "$publisher_runtime_spec" | /usr/bin/jq -r '.sha256 // ""'
  )
  publisher_runtime_expected_uid=$(
    builtin printf '%s' "$publisher_runtime_spec" | /usr/bin/jq -r '.uid // ""'
  )
  publisher_runtime_expected_mode=$(
    builtin printf '%s' "$publisher_runtime_spec" | /usr/bin/jq -r '.mode // ""'
  )
  [ -n "$publisher_runtime_expected_sha" ] &&
    [ -n "$publisher_runtime_expected_uid" ] &&
    [ -n "$publisher_runtime_expected_mode" ] ||
    { guard_fail "$publisher_runtime_label seal is incomplete"; return 1; }
  publisher_runtime_actual_sha=$(guard_sha256 "$publisher_runtime_path") || return 1
  publisher_runtime_actual_uid=$(/usr/bin/stat -f '%u' "$publisher_runtime_path") || return 1
  publisher_runtime_actual_mode=$(/usr/bin/stat -f '%Lp' "$publisher_runtime_path") || return 1
  [ "$publisher_runtime_actual_sha" = "$publisher_runtime_expected_sha" ] &&
    [ "$publisher_runtime_actual_uid" = "$publisher_runtime_expected_uid" ] &&
    [ "$publisher_runtime_actual_mode" = "$publisher_runtime_expected_mode" ] ||
    { guard_fail "$publisher_runtime_label digest, owner, or mode drifted"; return 1; }
}

publisher_disable_secret_leak_paths() {
  set +x
  ulimit -c 0 >/dev/null 2>&1 || true
  unset BASH_ENV ENV BASH_XTRACEFD CDPATH
  unset CURL_HOME CURLRC CURL_CONFIG CURL_CA_BUNDLE SSLKEYLOGFILE
  unset GIT_TRACE GIT_TRACE_SETUP GIT_TRACE_PACKET GIT_TRACE_CURL
  unset GIT_TRACE_CURL_NO_DATA GIT_CONFIG GIT_CONFIG_COUNT GIT_DIR GIT_WORK_TREE
  unset GIT_ASKPASS SSH_ASKPASS SSH_AUTH_SOCK SSH_AGENT_PID
  unset GIT_HTTP_PROXY GIT_PROXY_COMMAND ALL_PROXY HTTPS_PROXY HTTP_PROXY NO_PROXY
  unset TMPDIR
  publisher_exported_names=$(compgen -e)
  # Exported names are shell identifiers; remove their export attribute before
  # any credential exists so later children receive only explicit env -i data.
  if [ -n "$publisher_exported_names" ]; then
    # shellcheck disable=SC2086,SC2163
    export -n $publisher_exported_names 2>/dev/null || true
  fi
  umask 077
}

publisher_git_remote_url() {
  publisher_remote_authority=${PUBLISH_GIT_REMOTE_BASE#https://}
  builtin printf 'https://x-access-token@%s/%s.git\n' \
    "${publisher_remote_authority%/}" "$PUBLISH_REPO_ID"
}

publisher_api_request() {
  local publisher_method=$1
  local publisher_url=$2
  local publisher_token=$3
  local publisher_body_json=$4
  local publisher_expected_status=$5
  local publisher_body_path=$6
  local publisher_headers_path=$7
  local publisher_request_body_path=
  local publisher_status=
  [ -n "$publisher_body_json" ] && {
    publisher_request_body_path=$(/usr/bin/mktemp /tmp/nightshift-publish-body.XXXXXX)
    builtin printf '%s' "$publisher_body_json" > "$publisher_request_body_path"
  }
  publisher_status=$(
    {
      builtin printf '%s\n' "request = \"$publisher_method\""
      builtin printf '%s\n' "url = \"$publisher_url\""
      builtin printf '%s\n' "header = \"Accept: application/vnd.github+json\""
      builtin printf '%s\n' "header = \"X-GitHub-Api-Version: 2022-11-28\""
      builtin printf '%s\n' "header = \"Authorization: Bearer $publisher_token\""
      builtin printf '%s\n' "output = \"$publisher_body_path\""
      builtin printf '%s\n' "dump-header = \"$publisher_headers_path\""
      builtin printf '%s\n' 'connect-timeout = 10'
      builtin printf '%s\n' 'max-time = 20'
      builtin printf '%s\n' 'silent'
      builtin printf '%s\n' 'show-error'
      if [ -n "$publisher_request_body_path" ]; then
        builtin printf '%s\n' "header = \"Content-Type: application/json\""
        builtin printf '%s\n' "data-binary = \"@$publisher_request_body_path\""
      fi
    } | /usr/bin/env -i \
      HOME=/var/empty \
      LANG=C \
      LC_ALL=C \
      PATH=/usr/bin:/bin \
      "$GUARD_CURL_BIN" -q -K - -w '%{http_code}'
  ) || {
    [ -z "$publisher_request_body_path" ] || /bin/rm -f "$publisher_request_body_path"
    guard_fail "GitHub API request failed"
    return 1
  }
  [ -z "$publisher_request_body_path" ] || /bin/rm -f "$publisher_request_body_path"
  [ "$publisher_status" = "$publisher_expected_status" ] ||
    { guard_fail "GitHub API returned an unexpected status"; return 1; }
  case "$publisher_expected_status" in
    204) : ;;
    *) /usr/bin/jq -e . "$publisher_body_path" >/dev/null 2>&1 ||
         { guard_fail "GitHub API body is malformed"; return 1; } ;;
  esac
}

publisher_api_request_memory() {
  local publisher_method=$1
  local publisher_url=$2
  local publisher_token=$3
  local publisher_body_json=$4
  local publisher_expected_status=$5
  local publisher_request_body_path=
  local publisher_exchange=
  local publisher_status=
  local publisher_response=
  if [ -n "$publisher_body_json" ]; then
    publisher_request_body_path=$(/usr/bin/mktemp /tmp/nightshift-publish-body.XXXXXX)
    builtin printf '%s' "$publisher_body_json" > "$publisher_request_body_path"
  fi
  publisher_exchange=$(
    {
      builtin printf '%s\n' "request = \"$publisher_method\""
      builtin printf '%s\n' "url = \"$publisher_url\""
      builtin printf '%s\n' "header = \"Accept: application/vnd.github+json\""
      builtin printf '%s\n' "header = \"X-GitHub-Api-Version: 2022-11-28\""
      builtin printf '%s\n' "header = \"Authorization: Bearer $publisher_token\""
      builtin printf '%s\n' 'connect-timeout = 10'
      builtin printf '%s\n' 'max-time = 20'
      builtin printf '%s\n' 'silent'
      builtin printf '%s\n' 'show-error'
      if [ -n "$publisher_request_body_path" ]; then
        builtin printf '%s\n' "header = \"Content-Type: application/json\""
        builtin printf '%s\n' "data-binary = \"@$publisher_request_body_path\""
      fi
    } | /usr/bin/env -i \
      HOME=/var/empty \
      LANG=C \
      LC_ALL=C \
      PATH=/usr/bin:/bin \
      "$GUARD_CURL_BIN" -q -K - -w '\n%{http_code}'
  ) || {
    [ -z "$publisher_request_body_path" ] || /bin/rm -f "$publisher_request_body_path"
    guard_fail "GitHub API request failed"
    return 1
  }
  [ -z "$publisher_request_body_path" ] || /bin/rm -f "$publisher_request_body_path"
  publisher_status=${publisher_exchange##*$'\n'}
  publisher_response=${publisher_exchange%$'\n'*}
  [ "$publisher_status" = "$publisher_expected_status" ] ||
    { guard_fail "GitHub API returned an unexpected status"; return 1; }
  case "$publisher_expected_status" in
    204)
      [ -z "$publisher_response" ] ||
        { guard_fail "GitHub API 204 response unexpectedly contained a body"; return 1; }
      ;;
    *)
      builtin printf '%s' "$publisher_response" |
        /usr/bin/jq -e . >/dev/null 2>&1 ||
        { guard_fail "GitHub API body is malformed"; return 1; }
      ;;
  esac
  builtin printf '%s' "$publisher_response"
}

publisher_sha256_literal() {
  literal_value=$1
  builtin printf '%s' "$literal_value" |
    /usr/bin/shasum -a 256 |
    /usr/bin/awk '{print $1}'
}

publisher_base64url_stream() {
  /usr/bin/env -i \
    HOME=/var/empty \
    LANG=C \
    LC_ALL=C \
    PATH=/usr/bin:/bin \
    "$GUARD_OPENSSL_BIN" base64 -A |
    /usr/bin/tr '+/' '-_' |
    /usr/bin/tr -d '='
}

publisher_generate_jwt() {
  publisher_key_path=$1
  publisher_app_id=$2
  publisher_now=$(/bin/date -u +%s)
  publisher_iat=$((publisher_now - 10))
  publisher_exp=$((publisher_now + 50))
  publisher_header='{"alg":"RS256","typ":"JWT"}'
  publisher_payload=$(/usr/bin/jq -cn \
    --argjson iat "$publisher_iat" \
    --argjson exp "$publisher_exp" \
    --argjson iss "$publisher_app_id" \
    '{iat:$iat,exp:$exp,iss:$iss}')
  publisher_header_b64=$(builtin printf '%s' "$publisher_header" | publisher_base64url_stream)
  publisher_payload_b64=$(builtin printf '%s' "$publisher_payload" | publisher_base64url_stream)
  publisher_sign_input=$publisher_header_b64.$publisher_payload_b64
  publisher_signature_b64=$(
    builtin printf '%s' "$publisher_sign_input" |
      /usr/bin/env -i \
        HOME=/var/empty \
        LANG=C \
        LC_ALL=C \
        PATH=/usr/bin:/bin \
        "$GUARD_OPENSSL_BIN" dgst -sha256 -binary -sign "$publisher_key_path" |
      publisher_base64url_stream
  ) || { guard_fail "JWT signing failed"; return 1; }
  builtin printf '%s.%s.%s\n' \
    "$publisher_header_b64" "$publisher_payload_b64" "$publisher_signature_b64"
}

publisher_verify_installation_token_response() {
  local publisher_response=$1
  local publisher_expected_contents=$2
  local publisher_expires_at=
  local publisher_expires_epoch=
  local publisher_now_epoch=
  local publisher_lifetime=
  builtin printf '%s' "$publisher_response" |
    /usr/bin/jq -e \
    --arg repo_id "$PUBLISH_REPO_ID" \
    --argjson repository_id "$PUBLISH_REPOSITORY_ID" \
    --arg selection "$PUBLISH_EXPECTED_REPOSITORY_SELECTION" \
    --arg metadata_perm "$PUBLISH_EXPECTED_METADATA_PERMISSION" \
    --arg contents_perm "$publisher_expected_contents" '
    ((keys | sort) == ["expires_at","permissions","repositories","repository_selection","token"]) and
    (.token | type == "string" and test("^[A-Za-z0-9_]{20,}$")) and
    (.expires_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
    ((.permissions | keys | sort) == ["contents","metadata"]) and
    (.permissions.metadata == $metadata_perm) and
    (.permissions.contents == $contents_perm) and
    (.repository_selection == $selection) and
    (
      (.repositories | type == "array") and
      (.repositories | length == 1) and
      (.repositories[0].full_name == $repo_id) and
      (.repositories[0].id == $repository_id)
    )
  ' >/dev/null ||
    { guard_fail "installation token scope or repository set is invalid"; return 1; }
  publisher_expires_at=$(
    builtin printf '%s' "$publisher_response" | /usr/bin/jq -r '.expires_at'
  )
  publisher_expires_epoch=$(
    /bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$publisher_expires_at" '+%s' 2>/dev/null
  ) || { guard_fail "installation token expiry is malformed"; return 1; }
  publisher_now_epoch=$(/bin/date -u +%s)
  publisher_lifetime=$((publisher_expires_epoch - publisher_now_epoch))
  [ "$publisher_lifetime" -gt 0 ] && [ "$publisher_lifetime" -le 3660 ] ||
    { guard_fail "installation token expiry is outside the accepted window"; return 1; }
}

publisher_revoke_token() {
  local publisher_token=$1
  publisher_api_request_memory DELETE "$PUBLISH_API_BASE/installation/token" \
    "$publisher_token" '' 204 >/dev/null
}

publisher_scan_candidate() {
  publisher_scan_output=$1
  "$GUARD_DIR/scan.sh" \
    --repo "$PUBLISH_REPO_PATH" \
    --repo-id "$PUBLISH_REPO_ID" \
    --base "$PUBLISH_BASE_SHA" \
    --candidate "$PUBLISH_CANDIDATE_SHA" \
    --manifest "$PUBLISH_SCAN_MANIFEST_PATH" > "$publisher_scan_output"
  /usr/bin/jq -e '
    .schema == "alpha-nightshift/object-scan-evidence/v1" and
    .verdict == "PASS_LOCAL_ONLY"
  ' "$publisher_scan_output" >/dev/null ||
    { guard_fail "local scan did not produce a passing evidence packet"; return 1; }
}

publisher_append_audit_json() {
  publisher_audit_dir=$1
  publisher_request_id=$2
  publisher_payload=$3
  publisher_audit_path=$publisher_audit_dir/"$publisher_request_id".jsonl
  /usr/bin/perl -MFcntl=:DEFAULT,:flock -e '
    use strict;
    use warnings;
    use IO::Handle;
    my ($path,$payload)=@ARGV;
    sysopen my $fh,$path,O_WRONLY|O_APPEND|O_CREAT|O_NOFOLLOW,0600 or die $!;
    flock $fh,LOCK_EX or die $!;
    my @st=stat($fh);
    die "audit target is not regular\n" unless -f $fh;
    die "audit owner mismatch\n" unless $st[4] == $>;
    die "audit mode mismatch\n" unless ($st[2] & 07777) == 0600;
    die "audit hard link forbidden\n" unless $st[3] == 1;
    my $record=$payload."\n";
    my $written=syswrite($fh,$record);
    die "short audit append\n" unless defined($written) && $written == length($record);
    $fh->flush or die $!;
    $fh->sync or die $!;
    close $fh or die $!;
  ' "$publisher_audit_path" "$publisher_payload" ||
    { guard_fail "audit append failed"; return 1; }
  /usr/bin/printf '%s\n' "$publisher_audit_path"
}

publisher_prepare_scratch_git() {
  PUBLISH_SCRATCH_GIT_DIR=$1
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
    "$GUARD_GIT_BIN" init --bare --quiet "$PUBLISH_SCRATCH_GIT_DIR" ||
    { guard_fail "publisher scratch Git directory initialization failed"; return 1; }
  guard_validate_absolute_path "$PUBLISH_SCRATCH_GIT_DIR" dir || return 1
}

publisher_verify_push_output() {
  publisher_push_output=$1
  publisher_status_lines=$(
    /usr/bin/awk -F '\t' 'NF == 3 && $1 ~ /^[*+!= -]$/ { print }' "$publisher_push_output"
  )
  [ "$(/usr/bin/printf '%s\n' "$publisher_status_lines" | /usr/bin/awk 'NF { count++ } END { print count+0 }')" -eq 1 ] ||
    { guard_fail "publish push did not report exactly one ref status"; return 1; }
  builtin printf '%s\n' "$publisher_status_lines" |
    /usr/bin/awk -F '\t' \
      -v refspec="$PUBLISH_CANDIDATE_SHA:$PUBLISH_DESTINATION_REF" '
      $1 == "*" && $2 == refspec && $3 ~ /^\[new branch\]/ { ok=1 }
      END { exit(ok ? 0 : 1) }
    ' ||
    { guard_fail "publish push did not report the exact generated branch create"; return 1; }
}

publisher_git_push() {
  local publisher_token=$1
  local publisher_push_output=$2
  local publisher_git_url
  local publisher_expected_prompt
  local publisher_remote_authority
  publisher_git_url=$(publisher_git_remote_url)
  publisher_remote_authority=${PUBLISH_GIT_REMOTE_BASE#https://}
  publisher_expected_prompt="Password for 'https://x-access-token@${publisher_remote_authority%/}': "
  if ! {
    builtin printf '%s\n%s\n' "$publisher_expected_prompt" "$publisher_token"
  } | (
      exec 3<&0
      exec </dev/null
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
        GIT_ASKPASS="$GUARD_DIR/publisher-askpass.sh" \
        SSH_ASKPASS=/usr/bin/false \
        GIT_NO_REPLACE_OBJECTS=1 \
        GIT_OBJECT_DIRECTORY="$PUBLISH_OBJECT_DIRECTORY" \
        "$GUARD_GIT_BIN" \
          --no-pager \
          --git-dir="$PUBLISH_SCRATCH_GIT_DIR" \
          -c core.hooksPath=/dev/null \
          -c core.fsmonitor=false \
          -c credential.helper= \
          -c protocol.file.allow=never \
          push --porcelain \
          "$publisher_git_url" \
          "$PUBLISH_CANDIDATE_SHA:$PUBLISH_DESTINATION_REF"
    ) > "$publisher_push_output" 2>&1; then
    guard_fail "publish push failed"
    return 1
  fi
  publisher_verify_push_output "$publisher_push_output"
}

publisher_require_unpaginated() {
  publisher_headers_path=$1
  if LC_ALL=C /usr/bin/grep -i '^Link:.*rel="next"' "$publisher_headers_path" >/dev/null 2>&1; then
    guard_fail "GitHub API response was paginated or truncated"
    return 1
  fi
}

publisher_verify_read_prepush_pair() {
  publisher_read_json=$1
  publisher_prepush_json=$2
  /usr/bin/jq -s -e '
    def valid_ruleset_result:
      type == "object" and
      (keys | sort) == [
        "destination_effective_sha256",
        "main_effective_sha256",
        "ruleset_definitions_sha256",
        "rulesets_sha256"
      ] and
      all(.[]; type == "string" and test("^[a-f0-9]{64}$"));
    length == 2 and
    .[0].phase == "read" and
    .[1].phase == "prepush" and
    .[0].destination_state == "ABSENT" and
    .[1].destination_state == "ABSENT" and
    .[0].destination_sha == null and
    .[1].destination_sha == null and
    (.[0].main_tip_sha | type == "string" and test("^[a-f0-9]{40}([a-f0-9]{24})?$")) and
    (.[1].main_tip_sha | type == "string" and test("^[a-f0-9]{40}([a-f0-9]{24})?$")) and
    (.[0].ruleset_result | valid_ruleset_result) and
    (.[1].ruleset_result | valid_ruleset_result) and
    .[0].rule_suite_result == "UNPROVEN_NO_ADMIN_READ" and
    .[1].rule_suite_result == "UNPROVEN_NO_ADMIN_READ" and
    .[0].main_tip_sha == .[1].main_tip_sha and
    .[0].ruleset_result == .[1].ruleset_result and
    .[0].rule_suite_result == .[1].rule_suite_result
  ' "$publisher_read_json" "$publisher_prepush_json" >/dev/null ||
    { guard_fail "read-before-write remote preflight drifted"; return 1; }
}

publisher_verify_postpush_pair() {
  publisher_prepush_json=$1
  publisher_postpush_json=$2
  /usr/bin/jq -s -e --arg candidate_sha "$PUBLISH_CANDIDATE_SHA" '
    def valid_ruleset_result:
      type == "object" and
      (keys | sort) == [
        "destination_effective_sha256",
        "main_effective_sha256",
        "ruleset_definitions_sha256",
        "rulesets_sha256"
      ] and
      all(.[]; type == "string" and test("^[a-f0-9]{64}$"));
    length == 2 and
    .[0].phase == "prepush" and
    .[1].phase == "postpush" and
    .[0].destination_state == "ABSENT" and
    .[0].destination_sha == null and
    .[1].destination_state == "MATCH" and
    .[1].destination_sha == $candidate_sha and
    (.[0].main_tip_sha | type == "string" and test("^[a-f0-9]{40}([a-f0-9]{24})?$")) and
    (.[1].main_tip_sha | type == "string" and test("^[a-f0-9]{40}([a-f0-9]{24})?$")) and
    (.[0].ruleset_result | valid_ruleset_result) and
    (.[1].ruleset_result | valid_ruleset_result) and
    .[0].rule_suite_result == "UNPROVEN_NO_ADMIN_READ" and
    .[1].rule_suite_result == "UNPROVEN_NO_ADMIN_READ" and
    .[0].main_tip_sha == .[1].main_tip_sha and
    .[0].ruleset_result == .[1].ruleset_result and
    .[0].rule_suite_result == .[1].rule_suite_result
  ' "$publisher_prepush_json" "$publisher_postpush_json" >/dev/null ||
    { guard_fail "post-push readback did not prove the generated ref"; return 1; }
}

publisher_verify_remote_state() {
  publisher_phase=$1
  publisher_token=$2
  publisher_tmp=$3
  publisher_repo_json=$publisher_tmp/repo.json
  publisher_installation_repos_json=$publisher_tmp/installation-repositories.json
  publisher_rulesets_json=$publisher_tmp/rulesets.json
  publisher_ruleset_details_jsonl=$publisher_tmp/ruleset-details.jsonl
  publisher_main_rules_json=$publisher_tmp/main-rules.json
  publisher_destination_rules_json=$publisher_tmp/destination-rules.json
  publisher_main_ref_json=$publisher_tmp/main-ref.json
  publisher_destination_ref_json=$publisher_tmp/destination-ref.json
  publisher_tags_json=$publisher_tmp/tags.json
  publisher_releases_json=$publisher_tmp/releases.json
  publisher_headers=$publisher_tmp/headers.txt

  publisher_encoded_main=$(publisher_urlencode "$PUBLISH_MAIN_BRANCH")
  publisher_destination_branch=${PUBLISH_DESTINATION_REF#refs/heads/}
  publisher_encoded_destination=$(publisher_urlencode "$publisher_destination_branch")
  publisher_git_ref_path_main=${PUBLISH_MAIN_BRANCH#refs/heads/}
  publisher_git_ref_path_destination=${PUBLISH_DESTINATION_REF#refs/}

  publisher_api_request GET "$PUBLISH_API_BASE/repos/$PUBLISH_REPO_ID" \
    "$publisher_token" '' 200 "$publisher_repo_json" "$publisher_headers"
  /usr/bin/jq -e \
    --arg repo_id "$PUBLISH_REPO_ID" \
    --argjson repository_id "$PUBLISH_REPOSITORY_ID" \
    --argjson repo_private "$PUBLISH_EXPECTED_REPOSITORY_PRIVATE" '
    .full_name == $repo_id and .id == $repository_id and .private == $repo_private
  ' "$publisher_repo_json" >/dev/null ||
    { guard_fail "repository metadata did not match the pinned repository"; return 1; }

  publisher_api_request GET "$PUBLISH_API_BASE/installation/repositories?per_page=2" \
    "$publisher_token" '' 200 "$publisher_installation_repos_json" "$publisher_headers"
  publisher_require_unpaginated "$publisher_headers" || return 1
  /usr/bin/jq -e \
    --arg repo_id "$PUBLISH_REPO_ID" \
    --argjson repository_id "$PUBLISH_REPOSITORY_ID" '
    .total_count == 1 and
    (.repositories | length == 1) and
    .repositories[0].full_name == $repo_id and
    .repositories[0].id == $repository_id
  ' "$publisher_installation_repos_json" >/dev/null ||
    { guard_fail "installation repository scope changed"; return 1; }

  publisher_api_request GET "$PUBLISH_API_BASE/repos/$PUBLISH_REPO_ID/rulesets?includes_parents=true&per_page=100" \
    "$publisher_token" '' 200 "$publisher_rulesets_json" "$publisher_headers"
  publisher_require_unpaginated "$publisher_headers" || return 1
  /usr/bin/jq -e --argjson expected "$PUBLISH_RULESET_IDS_JSON" '
    ($expected | length) > 0 and
    ([.[]?.id] | sort) == ($expected | sort)
  ' "$publisher_rulesets_json" >/dev/null ||
    { guard_fail "readable ruleset ids did not exactly match policy"; return 1; }
  : > "$publisher_ruleset_details_jsonl"
  builtin printf '%s' "$PUBLISH_RULESET_IDS_JSON" |
    /usr/bin/jq -r 'sort[]' |
    while IFS= read -r publisher_ruleset_id; do
      publisher_ruleset_detail=$publisher_tmp/ruleset-"$publisher_ruleset_id".json
      publisher_api_request GET \
        "$PUBLISH_API_BASE/repos/$PUBLISH_REPO_ID/rulesets/$publisher_ruleset_id" \
        "$publisher_token" '' 200 "$publisher_ruleset_detail" "$publisher_headers"
      publisher_require_unpaginated "$publisher_headers" || exit 1
      /usr/bin/jq -e --argjson expected_id "$publisher_ruleset_id" \
        '.id == $expected_id and (.rules | type == "array")' \
        "$publisher_ruleset_detail" >/dev/null ||
        { guard_fail "readable ruleset definition did not match policy"; exit 1; }
      /usr/bin/jq -cS . "$publisher_ruleset_detail" >> "$publisher_ruleset_details_jsonl"
    done || return 1

  publisher_api_request GET "$PUBLISH_API_BASE/repos/$PUBLISH_REPO_ID/rules/branches/$publisher_encoded_main?per_page=100" \
    "$publisher_token" '' 200 "$publisher_main_rules_json" "$publisher_headers"
  publisher_require_unpaginated "$publisher_headers" || return 1
  publisher_api_request GET "$PUBLISH_API_BASE/repos/$PUBLISH_REPO_ID/rules/branches/$publisher_encoded_destination?per_page=100" \
    "$publisher_token" '' 200 "$publisher_destination_rules_json" "$publisher_headers"
  publisher_require_unpaginated "$publisher_headers" || return 1

  publisher_api_request GET "$PUBLISH_API_BASE/repos/$PUBLISH_REPO_ID/git/ref/heads/$publisher_git_ref_path_main" \
    "$publisher_token" '' 200 "$publisher_main_ref_json" "$publisher_headers"
  /usr/bin/jq -e --arg base_sha "$PUBLISH_BASE_SHA" '.object.sha == $base_sha' \
    "$publisher_main_ref_json" >/dev/null ||
    { guard_fail "readable main tip no longer matches the accepted base"; return 1; }
  publisher_main_tip_sha=$(/usr/bin/jq -er '.object.sha' "$publisher_main_ref_json") ||
    { guard_fail "readable main tip response omitted an object SHA"; return 1; }

  case "$publisher_phase" in
    read|prepush)
      publisher_api_request GET "$PUBLISH_API_BASE/repos/$PUBLISH_REPO_ID/git/ref/$publisher_git_ref_path_destination" \
        "$publisher_token" '' 404 "$publisher_destination_ref_json" "$publisher_headers"
      publisher_destination_state=ABSENT
      publisher_destination_sha=
      ;;
    postpush)
      publisher_api_request GET "$PUBLISH_API_BASE/repos/$PUBLISH_REPO_ID/git/ref/$publisher_git_ref_path_destination" \
        "$publisher_token" '' 200 "$publisher_destination_ref_json" "$publisher_headers"
      publisher_destination_sha=$(/usr/bin/jq -r '.object.sha' "$publisher_destination_ref_json")
      [ "$publisher_destination_sha" = "$PUBLISH_CANDIDATE_SHA" ] ||
        { guard_fail "remote ref readback did not equal the candidate SHA"; return 1; }
      publisher_destination_state=MATCH
      ;;
    *)
      guard_fail "unknown remote verification phase"
      return 1
      ;;
  esac

  publisher_api_request GET "$PUBLISH_API_BASE/repos/$PUBLISH_REPO_ID/tags?per_page=1" \
    "$publisher_token" '' 200 "$publisher_tags_json" "$publisher_headers"
  publisher_require_unpaginated "$publisher_headers" || return 1
  publisher_api_request GET "$PUBLISH_API_BASE/repos/$PUBLISH_REPO_ID/releases?per_page=1" \
    "$publisher_token" '' 200 "$publisher_releases_json" "$publisher_headers"
  publisher_require_unpaginated "$publisher_headers" || return 1
  publisher_tags_count=$(/usr/bin/jq 'length' "$publisher_tags_json")
  publisher_releases_count=$(/usr/bin/jq 'length' "$publisher_releases_json")
  [ "$publisher_tags_count" = "$PUBLISH_EXPECTED_TAGS_COUNT" ] ||
    { guard_fail "readable tag count drifted"; return 1; }
  [ "$publisher_releases_count" = "$PUBLISH_EXPECTED_RELEASES_COUNT" ] ||
    { guard_fail "readable release count drifted"; return 1; }

  publisher_rulesets_sha256=$(guard_json_sha256 "$publisher_rulesets_json") || return 1
  publisher_ruleset_definitions_sha256=$(guard_sha256 "$publisher_ruleset_details_jsonl") || return 1
  publisher_main_rules_sha256=$(guard_json_sha256 "$publisher_main_rules_json") || return 1
  publisher_destination_rules_sha256=$(guard_json_sha256 "$publisher_destination_rules_json") || return 1
  for publisher_remote_digest in \
    "$publisher_rulesets_sha256" \
    "$publisher_ruleset_definitions_sha256" \
    "$publisher_main_rules_sha256" \
    "$publisher_destination_rules_sha256"; do
    LC_ALL=C /usr/bin/printf '%s\n' "$publisher_remote_digest" |
      /usr/bin/grep -E '^[a-f0-9]{64}$' >/dev/null ||
      { guard_fail "remote evidence digest is invalid"; return 1; }
  done
  [ "$publisher_ruleset_definitions_sha256" = \
    "$PUBLISH_EXPECTED_RULESET_DEFINITIONS_SHA256" ] ||
    { guard_fail "ruleset definitions drifted from the owner-sealed baseline"; return 1; }
  [ "$publisher_main_rules_sha256" = "$PUBLISH_EXPECTED_MAIN_RULES_SHA256" ] ||
    { guard_fail "main effective rules drifted from the owner-sealed baseline"; return 1; }
  [ "$publisher_destination_rules_sha256" = \
    "$PUBLISH_EXPECTED_DESTINATION_RULES_SHA256" ] ||
    { guard_fail "generated-branch effective rules drifted from the owner-sealed baseline"; return 1; }

  /usr/bin/jq -cn \
    --arg phase "$publisher_phase" \
    --arg repo_id "$PUBLISH_REPO_ID" \
    --argjson repository_id "$PUBLISH_REPOSITORY_ID" \
    --arg main_branch "$PUBLISH_MAIN_BRANCH" \
    --arg main_tip_sha "$publisher_main_tip_sha" \
    --arg destination_ref "$PUBLISH_DESTINATION_REF" \
    --arg destination_state "$publisher_destination_state" \
    --arg destination_sha "${publisher_destination_sha:-}" \
    --arg rulesets_sha256 "$publisher_rulesets_sha256" \
    --arg ruleset_definitions_sha256 "$publisher_ruleset_definitions_sha256" \
    --arg main_rules_sha256 "$publisher_main_rules_sha256" \
    --arg destination_rules_sha256 "$publisher_destination_rules_sha256" \
    --arg rule_suite_result UNPROVEN_NO_ADMIN_READ \
    --argjson tags_count "$publisher_tags_count" \
    --argjson releases_count "$publisher_releases_count" '
    {
      schema:"alpha-nightshift/remote-preflight/v1",
      mode:"REMOTE_PUBLISH",
      phase:$phase,
      repo_id:$repo_id,
      repository_id:$repository_id,
      main_branch:$main_branch,
      main_tip_sha:$main_tip_sha,
      destination_ref:$destination_ref,
      destination_state:$destination_state,
      destination_sha:($destination_sha | if . == "" then null else . end),
      ruleset_result:{
        rulesets_sha256:$rulesets_sha256,
        ruleset_definitions_sha256:$ruleset_definitions_sha256,
        main_effective_sha256:$main_rules_sha256,
        destination_effective_sha256:$destination_rules_sha256
      },
      rule_suite_result:$rule_suite_result,
      tags_count:$tags_count,
      releases_count:$releases_count
    }'
}
