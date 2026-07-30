#!/bin/bash
# shellcheck disable=SC1091,SC2016
set -euo pipefail

TEST_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)
ROOT=$(CDPATH='' cd -- "$TEST_DIR/.." && pwd -P)
. "$TEST_DIR/helpers.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-drift-monitor-test.XXXXXX")
cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT
TEST_TMP=$(CDPATH='' cd -- "$TEST_TMP" && pwd -P)

EXAMPLE_CONFIG=$ROOT/config/drift-monitor.example.json
"$ROOT/guard/drift-monitor.sh" status --config "$EXAMPLE_CONFIG" > "$TEST_TMP/example-status.json"
/usr/bin/jq -e '
  .schema == "alpha-nightshift/drift-monitor-status/v1" and
  .config_mode == "INACTIVE" and
  .write_mode == false and
  .network_access == false
' "$TEST_TMP/example-status.json" >/dev/null ||
  fail "checked-in drift monitor status was not inactive"

if "$ROOT/guard/drift-monitor.sh" run --config "$EXAMPLE_CONFIG" \
  > "$TEST_TMP/example-run.json" \
  2> "$TEST_TMP/example-run.err"; then
  fail "inactive checked-in drift monitor config allowed a live run"
fi
/usr/bin/jq -e '
  .verdict == "MONITOR_UNVERIFIED" and
  .write_mode == false and
  .detail.network_access == false and
  .detail.key_access == false and
  .detail.rule_suite_result == "UNPROVEN_NO_ADMIN_READ"
' "$TEST_TMP/example-run.json" >/dev/null ||
  fail "inactive drift monitor did not fail closed before key/network access"

FAKE_GUARD=$TEST_TMP/fake-guard
/bin/mkdir -p "$FAKE_GUARD"
/bin/chmod 700 "$FAKE_GUARD"
for source_name in \
  common.sh publisher-lib.sh publisher.sh publisher-askpass.sh remote-preflight.sh \
  scan.sh text-policy.sh drift-monitor.sh; do
  /bin/cp "$ROOT/guard/$source_name" "$FAKE_GUARD/$source_name"
done
/bin/chmod 755 \
  "$FAKE_GUARD/common.sh" \
  "$FAKE_GUARD/publisher-lib.sh" \
  "$FAKE_GUARD/publisher.sh" \
  "$FAKE_GUARD/publisher-askpass.sh" \
  "$FAKE_GUARD/remote-preflight.sh" \
  "$FAKE_GUARD/scan.sh" \
  "$FAKE_GUARD/text-policy.sh" \
  "$FAKE_GUARD/drift-monitor.sh"

FAKE_KEY=$TEST_TMP/private-key.pem
/usr/bin/printf '%s\n' 'FAKE-PRIVATE-KEY' > "$FAKE_KEY"
/bin/chmod 600 "$FAKE_KEY"
FAKE_MANIFEST=$TEST_TMP/guard-activation.json
/bin/cp "$ROOT/config/guard-activation.example.json" "$FAKE_MANIFEST"
/bin/chmod 600 "$FAKE_MANIFEST"
FAKE_AUDIT=$TEST_TMP/audit
/bin/mkdir -p "$FAKE_AUDIT"
/bin/chmod 700 "$FAKE_AUDIT"
DRIFTED_AUDIT=$TEST_TMP/drifted-audit
/bin/mkdir -p "$DRIFTED_AUDIT"
/bin/chmod 700 "$DRIFTED_AUDIT"
FAKE_KEY_SHA256=$(/usr/bin/shasum -a 256 "$FAKE_KEY" | /usr/bin/awk '{print $1}')
FAKE_AUDIT_DEVICE=$(/usr/bin/stat -f '%d' "$FAKE_AUDIT")
FAKE_AUDIT_INODE=$(/usr/bin/stat -f '%i' "$FAKE_AUDIT")
FAKE_AUDIT_IDENTITY_SHA256=$(
  builtin printf 'path=%s\ndevice=%s\ninode=%s\n' \
    "$FAKE_AUDIT" "$FAKE_AUDIT_DEVICE" "$FAKE_AUDIT_INODE" |
    /usr/bin/shasum -a 256 |
    /usr/bin/awk '{print $1}'
)
DRIFTED_AUDIT_DEVICE=$(/usr/bin/stat -f '%d' "$DRIFTED_AUDIT")
DRIFTED_AUDIT_INODE=$(/usr/bin/stat -f '%i' "$DRIFTED_AUDIT")
DRIFTED_AUDIT_IDENTITY_SHA256=$(
  builtin printf 'path=%s\ndevice=%s\ninode=%s\n' \
    "$DRIFTED_AUDIT" "$DRIFTED_AUDIT_DEVICE" "$DRIFTED_AUDIT_INODE" |
    /usr/bin/shasum -a 256 |
    /usr/bin/awk '{print $1}'
)

FAKE_BEHAVIOR=$TEST_TMP/fake-behavior
FAKE_CALL_LOG=$TEST_TMP/fake-call-log.txt
FAKE_REVOKE_LOG=$TEST_TMP/fake-revoke-log.txt
FAKE_ARGV_CAPTURE=$TEST_TMP/fake-process-argv.txt
FAKE_ENV_CAPTURE=$TEST_TMP/fake-process-env.txt
FAKE_AUDIT_PATH=$FAKE_AUDIT
FAKE_MAIN_REF_COUNT=$TEST_TMP/fake-main-ref-count.txt
MONITOR_IAT_PREFIX='MON_READ_IAT_'
MONITOR_IAT_SUFFIX='0123456789ABCDEF'
MONITOR_SAFE_FUTURE_TOKEN="${MONITOR_IAT_PREFIX}SAFE.-${MONITOR_IAT_SUFFIX}"
MONITOR_UNSAFE_TOKEN="${MONITOR_IAT_PREFIX}BAD:${MONITOR_IAT_SUFFIX}"
/usr/bin/printf '%s\n' success > "$FAKE_BEHAVIOR"

FAKE_GITLEAKS=$TEST_TMP/fake-gitleaks
/usr/bin/printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'if [ "${1-}" = version ]; then printf "%s\n" "8.30.1"; exit 0; fi' \
  'exit 0' > "$FAKE_GITLEAKS"
/bin/chmod 755 "$FAKE_GITLEAKS"

FAKE_OPENSSL=$TEST_TMP/fake-openssl
/usr/bin/printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  "BEHAVIOR_PATH=\"$FAKE_BEHAVIOR\"" \
  "ARGV_CAPTURE=\"$FAKE_ARGV_CAPTURE\"" \
  "ENV_CAPTURE=\"$FAKE_ENV_CAPTURE\"" \
  'printf "openssl" >> "$ARGV_CAPTURE"; for arg in "$@"; do printf " <%s>" "$arg" >> "$ARGV_CAPTURE"; done; printf "\n" >> "$ARGV_CAPTURE"' \
  '/usr/bin/env >> "$ENV_CAPTURE"' \
  'behavior=$(/bin/cat "$BEHAVIOR_PATH")' \
  'case "${1-}" in' \
  '  base64) exec /usr/bin/openssl "$@" ;;' \
  '  dgst) [ "$behavior" != jwt_sign_fail ] || exit 1; printf "signed-by-fake-openssl"; exit 0 ;;' \
  '  *) exec /usr/bin/openssl "$@" ;;' \
  'esac' > "$FAKE_OPENSSL"
/bin/chmod 755 "$FAKE_OPENSSL"

FAKE_GIT=$TEST_TMP/fake-git
/usr/bin/printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  "ARGV_CAPTURE=\"$FAKE_ARGV_CAPTURE\"" \
  "ENV_CAPTURE=\"$FAKE_ENV_CAPTURE\"" \
  'printf "git" >> "$ARGV_CAPTURE"; for arg in "$@"; do printf " <%s>" "$arg" >> "$ARGV_CAPTURE"; done; printf "\n" >> "$ARGV_CAPTURE"' \
  '/usr/bin/env >> "$ENV_CAPTURE"' \
  'if [ "${1-}" = --no-pager ]; then shift; fi' \
  'if [ "${1-}" = --git-dir=* ]; then shift; fi' \
  'while [ "${1-}" = -c ]; do shift 2; done' \
  'case "${1-}" in' \
  '  init) exit 0 ;;' \
  '  *) exit 0 ;;' \
  'esac' > "$FAKE_GIT"
/bin/chmod 755 "$FAKE_GIT"

FAKE_CURL=$TEST_TMP/fake-curl
/usr/bin/printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  "BEHAVIOR_PATH=\"$FAKE_BEHAVIOR\"" \
  "CALL_LOG=\"$FAKE_CALL_LOG\"" \
  "REVOKE_LOG=\"$FAKE_REVOKE_LOG\"" \
  "ARGV_CAPTURE=\"$FAKE_ARGV_CAPTURE\"" \
  "ENV_CAPTURE=\"$FAKE_ENV_CAPTURE\"" \
  "AUDIT_PATH=\"$FAKE_AUDIT_PATH\"" \
  "MAIN_REF_COUNT=\"$FAKE_MAIN_REF_COUNT\"" \
  "TOKEN_PREFIX=\"$MONITOR_IAT_PREFIX\"" \
  "TOKEN_SUFFIX=\"$MONITOR_IAT_SUFFIX\"" \
  'printf "curl" >> "$ARGV_CAPTURE"; for arg in "$@"; do printf " <%s>" "$arg" >> "$ARGV_CAPTURE"; done; printf "\n" >> "$ARGV_CAPTURE"' \
  '/usr/bin/env >> "$ENV_CAPTURE"' \
  'config=$(/bin/cat)' \
  'line_value() {' \
  '  key=$1' \
  '  printf "%s\n" "$config" | /usr/bin/sed -n "s/^$key = \"\\(.*\\)\"$/\\1/p" | /usr/bin/head -1' \
  '}' \
  'url=$(line_value url)' \
  'request=$(line_value request)' \
  'output=$(line_value output)' \
  'headers=$(line_value dump-header)' \
  'data_path=$(printf "%s\n" "$config" | /usr/bin/sed -n "s/^data-binary = \"@\\(.*\\)\"$/\\1/p" | /usr/bin/head -1)' \
  'behavior=$(/bin/cat "$BEHAVIOR_PATH")' \
  'printf "%s %s\n" "$request" "$url" >> "$CALL_LOG"' \
  '[ -z "$headers" ] || { : > "$headers"; printf "%s\n" "HTTP/1.1 200 OK" > "$headers"; }' \
  'status=200' \
  'response_body=' \
  '[ "$behavior" != timeout ] || exit 28' \
  'case "$url" in' \
  '  "https://api.github.test/app")' \
  '    if [ "$behavior" = auth_error ]; then response_body="{\"message\":\"forbidden\"}"; status=403; else response_body="{\"id\":1001,\"slug\":\"night-publisher\",\"permissions\":{\"metadata\":\"read\",\"contents\":\"write\"},\"events\":[]}"; fi' \
  '    [ "$behavior" != app_slug_drift ] || response_body="{\"id\":1001,\"slug\":\"wrong-publisher\",\"permissions\":{\"metadata\":\"read\",\"contents\":\"write\"},\"events\":[]}"' \
  '    [ "$behavior" != app_permissions_drift ] || response_body="{\"id\":1001,\"slug\":\"night-publisher\",\"permissions\":{\"metadata\":\"read\",\"contents\":\"write\",\"workflows\":\"write\"},\"events\":[]}"' \
  '    [ "$behavior" != app_events_drift ] || response_body="{\"id\":1001,\"slug\":\"night-publisher\",\"permissions\":{\"metadata\":\"read\",\"contents\":\"write\"},\"events\":[\"push\"]}"' \
  '    ;;' \
  '  "https://api.github.test/app/hook/config")' \
  '    if [ "$behavior" = post_first_request_api_fail ]; then response_body="{\"message\":\"server error\"}"; status=500; elif [ "$behavior" = webhook_url_drift ]; then response_body="{\"content_type\":\"json\",\"insecure_ssl\":\"0\",\"secret\":\"********\",\"url\":\"https://example.invalid/webhook\"}"; else response_body="{\"content_type\":\"json\",\"insecure_ssl\":\"0\",\"secret\":\"********\",\"url\":\"\"}"; fi' \
  '    ;;' \
  '  "https://api.github.test/app/installations/2002")' \
  '    case "$behavior" in' \
      '      malformed_body) response_body="{" ;;' \
  '      installation_account_drift) response_body="{\"id\":2002,\"app_id\":1001,\"app_slug\":\"night-publisher\",\"account\":{\"login\":\"wrong-account\"},\"repository_selection\":\"selected\",\"permissions\":{\"metadata\":\"read\",\"contents\":\"write\"},\"events\":[],\"suspended_at\":null,\"suspended_by\":null,\"repositories_url\":\"https://api.github.test/installations/2002/repositories\"}" ;;' \
  '      installation_permission_drift) response_body="{\"id\":2002,\"app_id\":1001,\"app_slug\":\"night-publisher\",\"account\":{\"login\":\"night-publisher\"},\"repository_selection\":\"selected\",\"permissions\":{\"metadata\":\"read\",\"contents\":\"write\",\"workflows\":\"write\"},\"events\":[],\"suspended_at\":null,\"suspended_by\":null,\"repositories_url\":\"https://api.github.test/installations/2002/repositories\"}" ;;' \
  '      installation_events_drift) response_body="{\"id\":2002,\"app_id\":1001,\"app_slug\":\"night-publisher\",\"account\":{\"login\":\"night-publisher\"},\"repository_selection\":\"selected\",\"permissions\":{\"metadata\":\"read\",\"contents\":\"write\"},\"events\":[\"push\"],\"suspended_at\":null,\"suspended_by\":null,\"repositories_url\":\"https://api.github.test/installations/2002/repositories\"}" ;;' \
  '      installation_suspended_drift) response_body="{\"id\":2002,\"app_id\":1001,\"app_slug\":\"night-publisher\",\"account\":{\"login\":\"night-publisher\"},\"repository_selection\":\"selected\",\"permissions\":{\"metadata\":\"read\",\"contents\":\"write\"},\"events\":[],\"suspended_at\":\"2026-07-30T16:00:00Z\",\"suspended_by\":{\"login\":\"owner\"},\"repositories_url\":\"https://api.github.test/installations/2002/repositories\"}" ;;' \
  '      *) response_body="{\"id\":2002,\"app_id\":1001,\"app_slug\":\"night-publisher\",\"account\":{\"login\":\"night-publisher\"},\"repository_selection\":\"selected\",\"permissions\":{\"metadata\":\"read\",\"contents\":\"write\"},\"events\":[],\"suspended_at\":null,\"suspended_by\":null,\"repositories_url\":\"https://api.github.test/installations/2002/repositories\"}" ;;' \
  '    esac' \
  '    ;;' \
  '  "https://api.github.test/app/installations/2002/access_tokens")' \
  '    [ -z "$output" ] || exit 91' \
  '    body=$(/bin/cat "$data_path")' \
  '    printf "%s" "$body" | /usr/bin/grep -F "\"contents\":\"read\"" >/dev/null 2>&1 || exit 92' \
  '    expires_at=$(/bin/date -u -v+30M +%Y-%m-%dT%H:%M:%SZ)' \
  '    if [ "$behavior" = token_missing ]; then response_body="{\"expires_at\":\"$expires_at\",\"repository_selection\":\"selected\",\"permissions\":{\"metadata\":\"read\",\"contents\":\"read\"},\"repositories\":[{\"id\":42,\"full_name\":\"sample/repo\"}]}"; status=201; else token="${TOKEN_PREFIX}${TOKEN_SUFFIX}"; [ "$behavior" != token_safe_future ] || token="'"$MONITOR_SAFE_FUTURE_TOKEN"'"; [ "$behavior" != token_unsafe ] || token="'"$MONITOR_UNSAFE_TOKEN"'"; response_body=$(/usr/bin/jq -cn --arg token "$token" --arg expires_at "$expires_at" "{token:\$token,expires_at:\$expires_at,repository_selection:\"selected\",permissions:{metadata:\"read\",contents:\"read\"},repositories:[{id:42,full_name:\"sample/repo\"}]}"); status=201; fi' \
  '    ;;' \
  '  "https://api.github.test/installation/token")' \
  '    [ -z "$output" ] || exit 93' \
  '    if [ "$behavior" = revoke_fail ] || [ "$behavior" = match_revoke_fail ] || [ "$behavior" = main_ref_drift_revoke_fail ]; then response_body="{\"message\":\"revoke failed\"}"; status=500; else response_body=; status=204; fi' \
  '    printf "%s\n" revoke-read >> "$REVOKE_LOG"' \
  '    [ "$behavior" != audit_fail ] || /bin/chmod 500 "$AUDIT_PATH"' \
  '    ;;' \
  '  "https://api.github.test/repos/sample/repo")' \
  '    response_body="{\"id\":42,\"full_name\":\"sample/repo\",\"private\":true,\"default_branch\":\"main\"}"' \
  '    [ "$behavior" != repo_private_drift ] || response_body="{\"id\":42,\"full_name\":\"sample/repo\",\"private\":false,\"default_branch\":\"main\"}"' \
  '    [ "$behavior" != default_branch_drift ] || response_body="{\"id\":42,\"full_name\":\"sample/repo\",\"private\":true,\"default_branch\":\"develop\"}"' \
  '    ;;' \
  '  "https://api.github.test/installation/repositories?per_page=2")' \
  '    response_body="{\"total_count\":1,\"repositories\":[{\"id\":42,\"full_name\":\"sample/repo\"}]}"' \
  '    [ "$behavior" != scope_drift ] || response_body="{\"total_count\":2,\"repositories\":[{\"id\":42,\"full_name\":\"sample/repo\"},{\"id\":99,\"full_name\":\"other/repo\"}]}"' \
  '    [ "$behavior" != pagination ] || printf "%s\n" "Link: <https://api.github.test/installation/repositories?page=2>; rel=\"next\"" >> "$headers"' \
  '    ;;' \
  '  "https://api.github.test/repos/sample/repo/rulesets?includes_parents=true&per_page=100")' \
  '    response_body="[{\"id\":3003},{\"id\":3004}]"' \
  '    [ "$behavior" != ruleset_id_drift ] || response_body="[{\"id\":3003},{\"id\":3999}]"' \
  '    ;;' \
  '  "https://api.github.test/repos/sample/repo/rulesets/3003")' \
  '    response_body="{\"id\":3003,\"rules\":[{\"type\":\"creation\"}]}"' \
  '    [ "$behavior" != ruleset_definition_drift ] || response_body="{\"id\":3003,\"rules\":[{\"type\":\"update\"}]}"' \
  '    ;;' \
  '  "https://api.github.test/repos/sample/repo/rulesets/3004")' \
  '    response_body="{\"id\":3004,\"rules\":[{\"type\":\"update\"}]}"' \
  '    ;;' \
  '  "https://api.github.test/repos/sample/repo/rules/branches/main?per_page=100")' \
  '    response_body="{\"ref\":\"main\",\"rules\":[{\"id\":3003},{\"id\":3004}]}"' \
  '    [ "$behavior" != main_effective_drift ] || response_body="{\"ref\":\"main\",\"rules\":[{\"id\":3003}]}"' \
  '    ;;' \
  '  "https://api.github.test/repos/sample/repo/rules/branches/night-bot%2Frun-20260730-0099-deadbeef?per_page=100")' \
  '    response_body="{\"ref\":\"night-bot/run-20260730-0099-deadbeef\",\"rules\":[{\"id\":3003},{\"id\":3004}]}"' \
  '    [ "$behavior" != representative_effective_drift ] || response_body="{\"ref\":\"night-bot/run-20260730-0099-deadbeef\",\"rules\":[{\"id\":3004}]}"' \
  '    ;;' \
  '  "https://api.github.test/repos/sample/repo/git/ref/heads/main")' \
  '    ref_count=0; [ ! -f "$MAIN_REF_COUNT" ] || ref_count=$(/bin/cat "$MAIN_REF_COUNT")' \
  '    ref_count=$((ref_count + 1)); printf "%s\n" "$ref_count" > "$MAIN_REF_COUNT"' \
  '    response_body="{\"object\":{\"sha\":\"1111111111111111111111111111111111111111\"}}"' \
  '    if { [ "$behavior" = main_ref_drift ] || [ "$behavior" = main_ref_drift_revoke_fail ]; } && [ "$ref_count" -ge 2 ]; then response_body="{\"object\":{\"sha\":\"2222222222222222222222222222222222222222\"}}"; fi' \
  '    ;;' \
  '  "https://api.github.test/repos/sample/repo/git/ref/heads/night-bot/run-20260730-0099-deadbeef")' \
  '    if [ "$behavior" = representative_ref_present ]; then response_body="{\"object\":{\"sha\":\"1111111111111111111111111111111111111111\"}}"; status=200; else response_body="{\"message\":\"Not Found\"}"; [ -z "$headers" ] || printf "%s\n" "HTTP/1.1 404 Not Found" > "$headers"; status=404; fi' \
  '    ;;' \
  '  "https://api.github.test/repos/sample/repo/tags?per_page=1")' \
  '    response_body="[]"' \
  '    [ "$behavior" != tags_drift ] || response_body="[{\"name\":\"v1.0.0\"}]"' \
  '    ;;' \
  '  "https://api.github.test/repos/sample/repo/releases?per_page=1")' \
  '    response_body="[]"' \
  '    [ "$behavior" != releases_drift ] || response_body="[{\"id\":1,\"tag_name\":\"v1.0.0\"}]"' \
  '    ;;' \
  '  *)' \
  '    response_body="{\"message\":\"unexpected url\"}"' \
  '    [ -z "$headers" ] || printf "%s\n" "HTTP/1.1 500 Internal Server Error" > "$headers"' \
  '    status=500' \
  '    ;;' \
  'esac' \
  'if [ -n "$output" ]; then printf "%s" "$response_body" > "$output"; printf "%s" "$status"; else printf "%s\n%s" "$response_body" "$status"; fi' > "$FAKE_CURL"
/bin/chmod 755 "$FAKE_CURL"

/usr/bin/sed \
  -e "s|/opt/homebrew/Cellar/git/2.48.1/bin/git|$FAKE_GIT|g" \
  -e "s|/opt/homebrew/Cellar/gitleaks/8.30.1/bin/gitleaks|$FAKE_GITLEAKS|g" \
  -e "s|/usr/bin/curl|$FAKE_CURL|g" \
  -e "s|/usr/bin/openssl|$FAKE_OPENSSL|g" \
  "$ROOT/guard/common.sh" > "$FAKE_GUARD/common.sh.rewritten"
/bin/mv "$FAKE_GUARD/common.sh.rewritten" "$FAKE_GUARD/common.sh"
/usr/bin/sed \
  -e 's|https://api.github.com|https://api.github.test|g' \
  -e 's|https://github.com|https://github.test|g' \
  "$ROOT/guard/publisher-lib.sh" > "$FAKE_GUARD/publisher-lib.sh.rewritten"
/bin/mv "$FAKE_GUARD/publisher-lib.sh.rewritten" "$FAKE_GUARD/publisher-lib.sh"
/bin/chmod 755 "$FAKE_GUARD/common.sh" "$FAKE_GUARD/publisher-lib.sh"

runtime_spec() {
  runtime_path=$1
  /usr/bin/jq -cn \
    --arg sha256 "$(/usr/bin/shasum -a 256 "$runtime_path" | /usr/bin/awk '{print $1}')" \
    --argjson uid "$(/usr/bin/stat -f '%u' "$runtime_path")" \
    --arg mode "$(/usr/bin/stat -f '%Lp' "$runtime_path")" \
    '{sha256:$sha256,uid:$uid,mode:$mode}'
}

PUBLISHER_RUNTIME_JSON=$(
  /usr/bin/jq -cn \
    --argjson bash "$(runtime_spec /bin/bash)" \
    --argjson curl "$(runtime_spec "$FAKE_CURL")" \
    --argjson git "$(runtime_spec "$FAKE_GIT")" \
    --argjson gitleaks "$(runtime_spec "$FAKE_GITLEAKS")" \
    --argjson jq "$(runtime_spec /usr/bin/jq)" \
    --argjson openssl "$(runtime_spec "$FAKE_OPENSSL")" \
    --argjson askpass "$(runtime_spec "$FAKE_GUARD/publisher-askpass.sh")" \
    --argjson common "$(runtime_spec "$FAKE_GUARD/common.sh")" \
    --argjson publisher "$(runtime_spec "$FAKE_GUARD/publisher.sh")" \
    --argjson publisher_lib "$(runtime_spec "$FAKE_GUARD/publisher-lib.sh")" \
    --argjson remote_preflight "$(runtime_spec "$FAKE_GUARD/remote-preflight.sh")" \
    --argjson scan "$(runtime_spec "$FAKE_GUARD/scan.sh")" '
    {
      tools:{
        bash:$bash,curl:$curl,git:$git,gitleaks:$gitleaks,jq:$jq,openssl:$openssl
      },
      programs:{
        askpass:$askpass,common:$common,publisher:$publisher,
        publisher_lib:$publisher_lib,remote_preflight:$remote_preflight,scan:$scan
      }
    }'
)
MONITOR_RUNTIME_JSON=$(
  /usr/bin/jq -cn \
    --argjson drift_monitor "$(runtime_spec "$FAKE_GUARD/drift-monitor.sh")" '
    {programs:{drift_monitor:$drift_monitor}}'
)

EXPECTED_RULESET_DEFINITIONS_SHA256=$(
  /usr/bin/printf '%s\n%s\n' \
    '{"id":3003,"rules":[{"type":"creation"}]}' \
    '{"id":3004,"rules":[{"type":"update"}]}' |
    /usr/bin/shasum -a 256 |
    /usr/bin/awk '{print $1}'
)
EXPECTED_MAIN_RULES_SHA256=$(
  /usr/bin/printf '%s' \
    '{"ref":"main","rules":[{"id":3003},{"id":3004}]}' |
    /usr/bin/jq -cS . |
    /usr/bin/shasum -a 256 |
    /usr/bin/awk '{print $1}'
)
EXPECTED_DESTINATION_RULES_SHA256=$(
  /usr/bin/printf '%s' \
    '{"ref":"night-bot/run-20260730-0099-deadbeef","rules":[{"id":3003},{"id":3004}]}' |
    /usr/bin/jq -cS . |
    /usr/bin/shasum -a 256 |
    /usr/bin/awk '{print $1}'
)

ACTIVE_POLICY=$TEST_TMP/active-publisher-policy.json
/usr/bin/jq -n \
  --arg key "$FAKE_KEY" \
  --arg key_sha256 "$FAKE_KEY_SHA256" \
  --arg audit "$FAKE_AUDIT" \
  --arg audit_identity_sha256 "$FAKE_AUDIT_IDENTITY_SHA256" \
  --arg manifest "$FAKE_MANIFEST" \
  --arg definitions_sha256 "$EXPECTED_RULESET_DEFINITIONS_SHA256" \
  --arg main_effective_sha256 "$EXPECTED_MAIN_RULES_SHA256" \
  --arg generated_effective_sha256 "$EXPECTED_DESTINATION_RULES_SHA256" \
  --argjson publisher_euid "$(/usr/bin/id -u)" \
  --argjson runtime "$PUBLISHER_RUNTIME_JSON" '
  {
    schema:"alpha-nightshift/publisher-policy/v1",
    mode:"ACTIVE",
    write_mode:true,
    repo_id:"sample/repo",
    repository_id:42,
    app_id:1001,
    installation_id:2002,
    api_base:"https://api.github.test",
    git_remote_base:"https://github.test",
    private_key_path:$key,
    private_key_sha256:$key_sha256,
    audit_dir:$audit,
    audit_dir_identity_sha256:$audit_identity_sha256,
    scan_manifest_path:$manifest,
    publisher_euid:$publisher_euid,
    runtime:$runtime,
    rulesets:{
      ids:[3003,3004],
      main_branch:"main",
      generated_branch_prefix:"night-bot/run-",
      expected:{
        definitions_sha256:$definitions_sha256,
        main_effective_sha256:$main_effective_sha256,
        generated_effective_sha256:$generated_effective_sha256
      }
    },
    expected:{
      repository_private:true,
      repository_selection:"selected",
      permissions:{metadata:"read",contents:"write"},
      tags_count:0,
      releases_count:0
    }
  }' > "$ACTIVE_POLICY"
/bin/chmod 600 "$ACTIVE_POLICY"
ACTIVE_POLICY_SHA=$(/usr/bin/jq -cS . "$ACTIVE_POLICY" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
DRIFTED_POLICY=$TEST_TMP/drifted-publisher-policy.json
/usr/bin/jq \
  --arg audit "$DRIFTED_AUDIT" \
  --arg audit_identity_sha256 "$DRIFTED_AUDIT_IDENTITY_SHA256" \
  '.audit_dir = $audit | .audit_dir_identity_sha256 = $audit_identity_sha256' \
  "$ACTIVE_POLICY" > "$DRIFTED_POLICY"
/bin/chmod 600 "$DRIFTED_POLICY"

ACTIVE_CONFIG=$TEST_TMP/active-drift-monitor.json
/usr/bin/jq -n \
  --arg policy "$ACTIVE_POLICY" \
  --arg policy_sha256 "$ACTIVE_POLICY_SHA" \
  --arg app_slug "night-publisher" \
  --arg installation_account "night-publisher" \
  --arg representative_ref "refs/heads/night-bot/run-20260730-0099-deadbeef" \
  --argjson runtime "$MONITOR_RUNTIME_JSON" '
  {
    schema:"alpha-nightshift/drift-monitor-policy/v1",
    mode:"ACTIVE",
    write_mode:false,
    publisher_policy_path:$policy,
    publisher_policy_sha256:$policy_sha256,
    expected_app_slug:$app_slug,
    expected_installation_account:$installation_account,
    representative_ref:$representative_ref,
    runtime:$runtime
  }' > "$ACTIVE_CONFIG"
/bin/chmod 600 "$ACTIVE_CONFIG"

reset_captures() {
  : > "$FAKE_CALL_LOG"
  : > "$FAKE_REVOKE_LOG"
  : > "$FAKE_ARGV_CAPTURE"
  : > "$FAKE_ENV_CAPTURE"
  : > "$FAKE_MAIN_REF_COUNT"
  /bin/rm -f "$FAKE_AUDIT"/MON-*.jsonl
  /bin/rm -f "$DRIFTED_AUDIT"/MON-*.jsonl
  /bin/chmod 700 "$FAKE_AUDIT"
  /bin/chmod 700 "$DRIFTED_AUDIT"
}

probe_cleanup_monitor() {
  probe_name=$1
  probe_tmp_value=$2
  probe_lib=$FAKE_GUARD/$probe_name-lib.sh
  /usr/bin/sed '$d' "$FAKE_GUARD/drift-monitor.sh" > "$probe_lib"
  /usr/bin/printf '%s\n' \
    'MONITOR_TMP=${1-}' \
    'MONITOR_CONFIG_MODE=ACTIVE' \
    'MONITOR_CONFIG_DIGEST=probe-config' \
    'MONITOR_DETECTED_VERDICT=' \
    'MONITOR_DETECTED_REASON=' \
    'MONITOR_DETECTED_DETAIL_JSON="{}"' \
    'MONITOR_RESULT_VERDICT=' \
    'MONITOR_RESULT_REASON=' \
    'MONITOR_RESULT_DETAIL_JSON="{}"' \
    'MONITOR_READ_TOKEN=' \
    'MONITOR_READ_TOKEN_MINTED=false' \
    'MONITOR_READ_TOKEN_REVOKE_READY=false' \
    'MONITOR_REVOKE_ATTEMPTED=false' \
    'MONITOR_REVOKE_RESULT=NOT_ATTEMPTED' \
    'MONITOR_REVOKE_REASON=' \
    'MONITOR_AUDIT_ATTEMPTED=false' \
    'MONITOR_AUDIT_RESULT=NOT_ATTEMPTED' \
    'MONITOR_AUDIT_REASON=' \
    'PUBLISH_TRUSTED_AUDIT_DIR=' \
    'false || cleanup_monitor' >> "$probe_lib"
  /bin/chmod 755 "$probe_lib"
  if /bin/bash -p "$probe_lib" "$probe_tmp_value" \
    > "$TEST_TMP/$probe_name.out" \
    2> "$TEST_TMP/$probe_name.err"; then
    echo 0 > "$TEST_TMP/$probe_name.status"
  else
    echo $? > "$TEST_TMP/$probe_name.status"
  fi
  [ "$(/bin/cat "$TEST_TMP/$probe_name.status")" = 1 ] ||
    fail "$probe_name cleanup probe exited unexpectedly"
  [ "$(/usr/bin/wc -l < "$TEST_TMP/$probe_name.out" | /usr/bin/tr -d ' ')" = 1 ] ||
    fail "$probe_name cleanup probe did not emit exactly one terminal JSON"
  /usr/bin/jq -e '.verdict == "MONITOR_UNVERIFIED" and .detail.failure_stage == "cleanup"' \
    "$TEST_TMP/$probe_name.out" >/dev/null ||
    fail "$probe_name cleanup probe did not fail closed"
}

run_monitor_case() {
  case_name=$1
  behavior=$2
  config_path=$3
  reset_captures
  /usr/bin/printf '%s\n' "$behavior" > "$FAKE_BEHAVIOR"
  if "$FAKE_GUARD/drift-monitor.sh" run --config "$config_path" \
    > "$TEST_TMP/$case_name.out" \
    2> "$TEST_TMP/$case_name.err"; then
    echo 0 > "$TEST_TMP/$case_name.status"
  else
    echo $? > "$TEST_TMP/$case_name.status"
  fi
}

assert_verdict() {
  case_name=$1
  expected_verdict=$2
  /usr/bin/jq -e --arg verdict "$expected_verdict" \
    '.verdict == $verdict and .detail.rule_suite_result == "UNPROVEN_NO_ADMIN_READ"' \
    "$TEST_TMP/$case_name.out" >/dev/null ||
    fail "$case_name did not emit $expected_verdict"
}

latest_audit_file() {
  /bin/ls "$FAKE_AUDIT"/MON-*.jsonl
}

assert_no_monitor_iat_exposure() {
  for token_sink in "$@"; do
    assert_not_contains "${MONITOR_IAT_PREFIX}${MONITOR_IAT_SUFFIX}" "$token_sink"
  done
}

probe_cleanup_monitor cleanup_empty_tmp ''
probe_cleanup_monitor cleanup_unavailable_tmp /dev/null/blocked

probe_signal_preserves_detected() {
  probe_name=$1
  probe_lib=$FAKE_GUARD/$probe_name-lib.sh
  /usr/bin/sed '$d' "$FAKE_GUARD/drift-monitor.sh" > "$probe_lib"
  /usr/bin/printf '%s\n' \
    'MONITOR_DETECTED_VERDICT=DRIFT_DENY' \
    'MONITOR_DETECTED_REASON="proven drift"' \
    'MONITOR_DETECTED_DETAIL_JSON="{}"' \
    'monitor_note_signal_failure "drift monitor received SIGTERM"' \
    '/usr/bin/printf "%s|%s\n" "$MONITOR_DETECTED_VERDICT" "$MONITOR_DETECTED_REASON"' \
    >> "$probe_lib"
  /bin/chmod 755 "$probe_lib"
  signal_probe=$(/bin/bash -p "$probe_lib")
  [ "$signal_probe" = 'DRIFT_DENY|proven drift' ] ||
    fail "$probe_name signal handling overwrote the detected verdict"
}

probe_signal_preserves_detected signal_preserves_detected

run_monitor_case success success "$ACTIVE_CONFIG"
[ "$(/bin/cat "$TEST_TMP/success.status")" = 0 ] || fail "success case exited nonzero"
[ "$(/usr/bin/wc -l < "$TEST_TMP/success.out" | /usr/bin/tr -d ' ')" -eq 1 ] ||
  fail "success case did not emit exactly one stdout JSON line"
assert_verdict success MATCH
/usr/bin/jq -e '
  .detail.app_slug == "night-publisher" and
  .detail.installation_account == "night-publisher" and
  .detail.publisher_policy_mode == "ACTIVE" and
  .detail.publisher_write_mode == true and
  .detail.webhook_disabled_url_repr_verified == true and
  .detail.oauth_user_auth_result == "UNPROVEN_MANUAL_OWNER_BASELINE" and
  .detail.detected_verdict == "MATCH" and
  .detail.revoke_result == "VERIFIED" and
  .detail.audit_result == "APPENDED" and
  .detail.remote.phase == "read" and
  .detail.remote.destination_state == "ABSENT"
' "$TEST_TMP/success.out" >/dev/null || fail "success case omitted sealed detail"
assert_contains 'GET https://api.github.test/app/hook/config' "$FAKE_CALL_LOG"
assert_contains 'POST https://api.github.test/app/installations/2002/access_tokens' "$FAKE_CALL_LOG"
assert_contains 'DELETE https://api.github.test/installation/token' "$FAKE_CALL_LOG"
assert_not_contains 'contents":"write' "$FAKE_CALL_LOG"
success_audit=$(latest_audit_file)
/usr/bin/jq -e '
  .verdict == "MATCH" and
  .detail.detected_verdict == "MATCH" and
  .detail.revoke_result == "VERIFIED" and
  .detail.audit_result == "APPEND_REQUESTED"
' "$success_audit" >/dev/null ||
  fail "success audit record did not preserve MATCH and append-request intent"
assert_no_monitor_iat_exposure \
  "$TEST_TMP/success.out" \
  "$TEST_TMP/success.err" \
  "$FAKE_ARGV_CAPTURE" \
  "$FAKE_ENV_CAPTURE" \
  "$success_audit"

policy_sha_drift_config=$TEST_TMP/policy-sha-drift.json
/usr/bin/jq \
  --arg policy "$DRIFTED_POLICY" \
  '.publisher_policy_path = $policy | .publisher_policy_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' \
  "$ACTIVE_CONFIG" > "$policy_sha_drift_config"
/bin/chmod 600 "$policy_sha_drift_config"
runtime_sha_drift_config=$TEST_TMP/runtime-sha-drift.json
/usr/bin/jq '.runtime.programs.drift_monitor.sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' \
  "$ACTIVE_CONFIG" > "$runtime_sha_drift_config"
/bin/chmod 600 "$runtime_sha_drift_config"
shared_runtime_sha_drift_policy=$TEST_TMP/shared-runtime-sha-drift-policy.json
/usr/bin/jq '.runtime.tools.curl.sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' \
  "$ACTIVE_POLICY" > "$shared_runtime_sha_drift_policy"
/bin/chmod 600 "$shared_runtime_sha_drift_policy"
shared_runtime_sha_drift_policy_sha=$(
  /usr/bin/jq -cS . "$shared_runtime_sha_drift_policy" |
    /usr/bin/shasum -a 256 |
    /usr/bin/awk '{print $1}'
)
shared_runtime_sha_drift_config=$TEST_TMP/shared-runtime-sha-drift.json
/usr/bin/jq \
  --arg policy "$shared_runtime_sha_drift_policy" \
  --arg policy_sha256 "$shared_runtime_sha_drift_policy_sha" \
  '.publisher_policy_path = $policy | .publisher_policy_sha256 = $policy_sha256' \
  "$ACTIVE_CONFIG" > "$shared_runtime_sha_drift_config"
/bin/chmod 600 "$shared_runtime_sha_drift_config"
wrong_mode_config=$TEST_TMP/wrong-mode-drift-monitor.json
/bin/cp "$ACTIVE_CONFIG" "$wrong_mode_config"
/bin/chmod 644 "$wrong_mode_config"

for drift_case in \
  app_slug_drift \
  app_permissions_drift \
  app_events_drift \
  webhook_url_drift \
  installation_account_drift \
  installation_permission_drift \
  installation_events_drift \
  installation_suspended_drift \
  scope_drift \
  repo_private_drift \
  default_branch_drift \
  ruleset_id_drift \
  ruleset_definition_drift \
  main_ref_drift \
  main_effective_drift \
  representative_ref_present \
  representative_effective_drift \
  tags_drift \
  releases_drift; do
  run_monitor_case "$drift_case" "$drift_case" "$ACTIVE_CONFIG"
  [ "$(/bin/cat "$TEST_TMP/$drift_case.status")" != 0 ] ||
    fail "$drift_case unexpectedly exited zero"
  assert_verdict "$drift_case" DRIFT_DENY
  case "$drift_case" in
    app_slug_drift|app_permissions_drift|app_events_drift|webhook_url_drift|installation_account_drift|installation_permission_drift|installation_events_drift|installation_suspended_drift)
      assert_not_contains 'POST https://api.github.test/app/installations/2002/access_tokens' "$FAKE_CALL_LOG"
      ;;
    main_ref_drift)
      /usr/bin/jq -e '
        .reason == "readable main tip no longer matches the accepted base" and
        .detail.failure_stage == "remote_verify"
      ' "$TEST_TMP/main_ref_drift.out" >/dev/null ||
        fail "main_ref_drift did not preserve the remote drift reason"
      main_ref_audit=$(latest_audit_file)
      /usr/bin/jq -e '.detail.detected_verdict == "DRIFT_DENY"' "$main_ref_audit" >/dev/null ||
        fail "main_ref_drift audit omitted DRIFT_DENY evidence"
      assert_no_monitor_iat_exposure "$TEST_TMP/main_ref_drift.out" "$TEST_TMP/main_ref_drift.err" "$main_ref_audit"
      ;;
    representative_ref_present)
      /usr/bin/jq -e '
        .reason == "representative destination ref already exists" and
        .detail.failure_stage == "remote_verify"
      ' "$TEST_TMP/representative_ref_present.out" >/dev/null ||
        fail "representative_ref_present did not preserve the destination-ref reason"
      representative_ref_audit=$(latest_audit_file)
      /usr/bin/jq -e '.detail.detected_verdict == "DRIFT_DENY"' "$representative_ref_audit" >/dev/null ||
        fail "representative_ref_present audit omitted DRIFT_DENY evidence"
      assert_no_monitor_iat_exposure "$TEST_TMP/representative_ref_present.out" "$TEST_TMP/representative_ref_present.err" "$representative_ref_audit"
      ;;
  esac
done

run_monitor_case policy_sha_drift success "$policy_sha_drift_config"
assert_verdict policy_sha_drift DRIFT_DENY
/usr/bin/jq -e '.detail.failure_stage == "policy_digest"' \
  "$TEST_TMP/policy_sha_drift.out" >/dev/null || fail "policy_sha_drift stage was not preserved"
if /bin/ls "$DRIFTED_AUDIT"/MON-*.jsonl >/dev/null 2>&1; then
  fail "policy_sha_drift unexpectedly wrote to the drifted audit path"
fi
run_monitor_case runtime_sha_drift success "$runtime_sha_drift_config"
assert_verdict runtime_sha_drift DRIFT_DENY
/usr/bin/jq -e '.detail.failure_stage == "runtime"' \
  "$TEST_TMP/runtime_sha_drift.out" >/dev/null || fail "runtime_sha_drift stage was not preserved"
run_monitor_case shared_runtime_sha_drift success "$shared_runtime_sha_drift_config"
assert_verdict shared_runtime_sha_drift DRIFT_DENY
/usr/bin/jq -e '.detail.failure_stage == "policy_prepare"' \
  "$TEST_TMP/shared_runtime_sha_drift.out" >/dev/null ||
  fail "shared_runtime_sha_drift stage was not preserved"
assert_not_contains 'POST https://api.github.test/app/installations/2002/access_tokens' "$FAKE_CALL_LOG"
run_monitor_case wrong_mode success "$wrong_mode_config"
assert_verdict wrong_mode DRIFT_DENY
/usr/bin/jq -e '.detail.failure_stage == "config_seal"' \
  "$TEST_TMP/wrong_mode.out" >/dev/null || fail "wrong_mode stage was not preserved"
assert_not_contains 'POST https://api.github.test/app/installations/2002/access_tokens' "$FAKE_CALL_LOG"

/bin/chmod 644 "$FAKE_OPENSSL"
run_monitor_case shared_runtime_unavailable success "$ACTIVE_CONFIG"
/bin/chmod 755 "$FAKE_OPENSSL"
assert_verdict shared_runtime_unavailable MONITOR_UNVERIFIED
/usr/bin/jq -e '.detail.failure_stage == "policy_prepare"' \
  "$TEST_TMP/shared_runtime_unavailable.out" >/dev/null ||
  fail "shared_runtime_unavailable stage was not preserved"
assert_not_contains 'POST https://api.github.test/app/installations/2002/access_tokens' "$FAKE_CALL_LOG"

run_monitor_case post_first_request_api_fail post_first_request_api_fail "$ACTIVE_CONFIG"
[ "$(/bin/cat "$TEST_TMP/post_first_request_api_fail.status")" != 0 ] ||
  fail "post_first_request_api_fail unexpectedly exited zero"
assert_verdict post_first_request_api_fail MONITOR_UNVERIFIED
assert_not_contains 'POST https://api.github.test/app/installations/2002/access_tokens' "$FAKE_CALL_LOG"

run_monitor_case jwt_sign_fail jwt_sign_fail "$ACTIVE_CONFIG"
[ "$(/bin/cat "$TEST_TMP/jwt_sign_fail.status")" != 0 ] ||
  fail "jwt_sign_fail unexpectedly exited zero"
assert_verdict jwt_sign_fail MONITOR_UNVERIFIED
assert_not_contains 'GET https://api.github.test/app' "$FAKE_CALL_LOG"

run_monitor_case token_safe_future token_safe_future "$ACTIVE_CONFIG"
[ "$(/bin/cat "$TEST_TMP/token_safe_future.status")" = 0 ] ||
  fail "token_safe_future exited nonzero"
assert_verdict token_safe_future MATCH
/usr/bin/jq -e '.detail.revoke_result == "VERIFIED"' \
  "$TEST_TMP/token_safe_future.out" >/dev/null ||
  fail "token_safe_future did not prove revocation"
assert_contains 'DELETE https://api.github.test/installation/token' "$FAKE_CALL_LOG"
token_safe_audit=$(latest_audit_file)
assert_not_contains "$MONITOR_SAFE_FUTURE_TOKEN" \
  "$TEST_TMP/token_safe_future.out" "$TEST_TMP/token_safe_future.err" \
  "$FAKE_ARGV_CAPTURE" "$FAKE_ENV_CAPTURE" "$token_safe_audit"

run_monitor_case token_unsafe token_unsafe "$ACTIVE_CONFIG"
[ "$(/bin/cat "$TEST_TMP/token_unsafe.status")" != 0 ] ||
  fail "token_unsafe unexpectedly exited zero"
assert_verdict token_unsafe MONITOR_UNVERIFIED
/usr/bin/jq -e '
  .reason == "read installation token response omitted a header-safe revocable token" and
  .detail.detected_verdict == "MONITOR_UNVERIFIED" and
  .detail.revoke_attempted == true and
  .detail.revoke_result == "UNPROVEN"
' "$TEST_TMP/token_unsafe.out" >/dev/null ||
  fail "token_unsafe did not preserve the unproven revoke result"
assert_not_contains 'DELETE https://api.github.test/installation/token' "$FAKE_CALL_LOG"
token_unsafe_audit=$(latest_audit_file)
assert_not_contains "$MONITOR_UNSAFE_TOKEN" \
  "$TEST_TMP/token_unsafe.out" "$TEST_TMP/token_unsafe.err" \
  "$FAKE_ARGV_CAPTURE" "$FAKE_ENV_CAPTURE" "$token_unsafe_audit"

for unverified_case in \
  malformed_body \
  pagination \
  timeout \
  auth_error \
  audit_fail \
  token_missing; do
  run_monitor_case "$unverified_case" "$unverified_case" "$ACTIVE_CONFIG"
  [ "$(/bin/cat "$TEST_TMP/$unverified_case.status")" != 0 ] ||
    fail "$unverified_case unexpectedly exited zero"
  assert_verdict "$unverified_case" MONITOR_UNVERIFIED
done

run_monitor_case match_revoke_fail match_revoke_fail "$ACTIVE_CONFIG"
[ "$(/bin/cat "$TEST_TMP/match_revoke_fail.status")" != 0 ] ||
  fail "match_revoke_fail unexpectedly exited zero"
assert_verdict match_revoke_fail MONITOR_UNVERIFIED
/usr/bin/jq -e '
  .reason == "read-only drift monitor matched all sealed invariants" and
  .detail.detected_verdict == "MATCH" and
  .detail.revoke_result == "UNPROVEN"
' "$TEST_TMP/match_revoke_fail.out" >/dev/null ||
  fail "match_revoke_fail did not preserve the detected MATCH verdict"
match_revoke_audit=$(latest_audit_file)
/usr/bin/jq -e '
  .detail.detected_verdict == "MATCH" and
  .detail.revoke_result == "UNPROVEN"
' "$match_revoke_audit" >/dev/null ||
  fail "match_revoke_fail audit omitted revoke preservation"
assert_no_monitor_iat_exposure "$TEST_TMP/match_revoke_fail.out" "$TEST_TMP/match_revoke_fail.err" "$match_revoke_audit"

run_monitor_case main_ref_drift_revoke_fail main_ref_drift_revoke_fail "$ACTIVE_CONFIG"
[ "$(/bin/cat "$TEST_TMP/main_ref_drift_revoke_fail.status")" != 0 ] ||
  fail "main_ref_drift_revoke_fail unexpectedly exited zero"
assert_verdict main_ref_drift_revoke_fail DRIFT_DENY
/usr/bin/jq -e '
  .reason == "readable main tip no longer matches the accepted base" and
  .verdict == "DRIFT_DENY" and
  .detail.detected_verdict == "DRIFT_DENY" and
  .detail.detected_reason == "readable main tip no longer matches the accepted base" and
  .detail.revoke_result == "UNPROVEN"
' "$TEST_TMP/main_ref_drift_revoke_fail.out" >/dev/null ||
  fail "main_ref_drift_revoke_fail did not preserve the detected DRIFT_DENY verdict"
main_ref_revoke_audit=$(latest_audit_file)
/usr/bin/jq -e '
  .detail.detected_verdict == "DRIFT_DENY" and
  .detail.detected_reason == "readable main tip no longer matches the accepted base" and
  .detail.revoke_result == "UNPROVEN" and
  .detail.audit_result == "APPEND_REQUESTED"
' "$main_ref_revoke_audit" >/dev/null ||
  fail "main_ref_drift_revoke_fail audit omitted revoke preservation"
assert_no_monitor_iat_exposure "$TEST_TMP/main_ref_drift_revoke_fail.out" "$TEST_TMP/main_ref_drift_revoke_fail.err" "$main_ref_revoke_audit"

run_monitor_case revoke_fail revoke_fail "$ACTIVE_CONFIG"
[ "$(/bin/cat "$TEST_TMP/revoke_fail.status")" != 0 ] ||
  fail "revoke_fail unexpectedly exited zero"
assert_verdict revoke_fail MONITOR_UNVERIFIED
/usr/bin/jq -e '.detail.detected_verdict == "MATCH" and .detail.revoke_result == "UNPROVEN"' \
  "$TEST_TMP/revoke_fail.out" >/dev/null || fail "revoke_fail did not preserve detected MATCH"

run_monitor_case audit_fail audit_fail "$ACTIVE_CONFIG"
[ "$(/bin/cat "$TEST_TMP/audit_fail.status")" != 0 ] ||
  fail "audit_fail unexpectedly exited zero"
assert_verdict audit_fail MONITOR_UNVERIFIED
/usr/bin/jq -e '.detail.detected_verdict == "MATCH" and .detail.audit_result == "FAILED"' \
  "$TEST_TMP/audit_fail.out" >/dev/null || fail "audit_fail did not report audit failure"
if /bin/ls "$FAKE_AUDIT"/MON-*.jsonl >/dev/null 2>&1; then
  fail "audit_fail unexpectedly wrote an audit record"
fi

printf 'test_guard_drift_monitor: PASS\n'
