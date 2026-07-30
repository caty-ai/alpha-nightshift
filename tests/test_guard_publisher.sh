#!/bin/bash
# shellcheck disable=SC1091,SC2016
set -euo pipefail

TEST_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)
ROOT=$(CDPATH='' cd -- "$TEST_DIR/.." && pwd -P)
. "$TEST_DIR/helpers.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-publisher-test.XXXXXX")
cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT
TEST_TMP=$(CDPATH='' cd -- "$TEST_TMP" && pwd -P)
REPO=$TEST_TMP/repo
REAL_GIT=$(/usr/bin/command -v git)

"$REAL_GIT" init -q "$REPO"
"$REAL_GIT" -C "$REPO" config user.name night-bot
"$REAL_GIT" -C "$REPO" config user.email night-bot@users.noreply.github.com
/usr/bin/printf '%s\n' 'base content.' > "$REPO/content.txt"
"$REAL_GIT" -C "$REPO" add content.txt
"$REAL_GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'base content.'
BASE_SHA=$("$REAL_GIT" -C "$REPO" rev-parse HEAD)
/usr/bin/printf '%s\n' 'candidate local change.' >> "$REPO/content.txt"
"$REAL_GIT" -C "$REPO" add content.txt
"$REAL_GIT" -C "$REPO" -c core.hooksPath=/dev/null commit -qm 'candidate local change.'
CANDIDATE_SHA=$("$REAL_GIT" -C "$REPO" rev-parse HEAD)

EXAMPLE_POLICY=$ROOT/config/publisher-policy.example.json
EXAMPLE_POLICY_SHA=$(/usr/bin/jq -cS . "$EXAMPLE_POLICY" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
EXAMPLE_REQUEST=$TEST_TMP/inactive-request.json
/usr/bin/jq -n \
  --arg request_id 'REQ-20260730-0001-0123456789abcdef' \
  --arg repo_id 'shojikumaru/alpha-nightshift' \
  --arg base_sha "$BASE_SHA" \
  --arg candidate_sha "$CANDIDATE_SHA" \
  --arg policy_sha256 "$EXAMPLE_POLICY_SHA" '
  {
    schema:"alpha-nightshift/publish-request/v1",
    operation:"publish_branch",
    request_id:$request_id,
    repo_id:$repo_id,
    repository_id:123,
    base_sha:$base_sha,
    candidate_sha:$candidate_sha,
    policy_sha256:$policy_sha256
  }' > "$EXAMPLE_REQUEST"

REQUEST_DRIFT_MARKER=$TEST_TMP/request-drift-marker
if /bin/bash -p -c '
  . "$1"
  . "$2"
  drift_marker=$3
  guard_json_sha256() {
    if [ -e "$drift_marker" ]; then
      printf "%064d\n" 2
    else
      : > "$drift_marker"
      printf "%064d\n" 1
    fi
  }
  publisher_load_request "$4"
' _ \
  "$ROOT/guard/common.sh" \
  "$ROOT/guard/publisher-lib.sh" \
  "$REQUEST_DRIFT_MARKER" \
  "$EXAMPLE_REQUEST" >/dev/null 2>&1; then
  fail "publisher accepted a request that changed during field extraction"
fi

"$ROOT/guard/publisher.sh" status --policy "$EXAMPLE_POLICY" > "$TEST_TMP/status.json"
/usr/bin/jq -e '
  .schema == "alpha-nightshift/publisher-status/v1" and
  .policy_mode == "INACTIVE" and
  .write_mode == false and
  .generated_branch_prefix == "night-bot/run-" and
  .network_access == false
' "$TEST_TMP/status.json" >/dev/null ||
  fail "checked-in publisher status was not inactive"

if "$ROOT/guard/publisher.sh" publish_branch \
  --policy "$EXAMPLE_POLICY" \
  --request "$EXAMPLE_REQUEST" \
  --repo "$REPO" > "$TEST_TMP/inactive.json" 2> "$TEST_TMP/inactive.err"; then
  fail "inactive checked-in publisher policy allowed publish_branch"
fi
/usr/bin/jq -e '
  .verdict == "DENY_INACTIVE" and
  .write_mode == false and
  .detail.network_access == false and
  .detail.key_access == false and
  .destination_ref == "refs/heads/night-bot/run-20260730-0001-01234567"
' "$TEST_TMP/inactive.json" >/dev/null ||
  fail "inactive publish did not fail closed before key/network access"

/usr/bin/jq '.base_sha="0000000000000000000000000000000000000000"' \
  "$EXAMPLE_REQUEST" > "$TEST_TMP/zero-sha.json"
if "$ROOT/guard/publisher.sh" publish_branch \
  --policy "$EXAMPLE_POLICY" \
  --request "$TEST_TMP/zero-sha.json" \
  --repo "$REPO" >/dev/null 2>&1; then
  fail "all-zero object id was accepted"
fi

/usr/bin/printf '%s\n' \
  '{"schema":"alpha-nightshift/publish-request/v1","operation":"publish_branch","request_id":"REQ-20260730-0001-0123456789abcdef","repo_id":"shojikumaru/alpha-nightshift","repository_id":123,"base_sha":"'"$BASE_SHA"'","candidate_sha":"'"$CANDIDATE_SHA"'","policy_sha256":"'"$EXAMPLE_POLICY_SHA"'","destination_ref":"refs/heads/main"}' \
  > "$TEST_TMP/extra-field.json"
if "$ROOT/guard/publisher.sh" publish_branch \
  --policy "$EXAMPLE_POLICY" \
  --request "$TEST_TMP/extra-field.json" \
  --repo "$REPO" >/dev/null 2>&1; then
  fail "publisher request accepted an extra caller-controlled field"
fi

for forbidden_field in branch ref destination_ref refspec remote_url force delete tag \
  notes_ref replace_ref git_config curl_config askpass command; do
  /usr/bin/jq --arg field "$forbidden_field" \
    '. + {($field):"refs/heads/main"}' \
    "$EXAMPLE_REQUEST" > "$TEST_TMP/forbidden-$forbidden_field.json"
  if "$ROOT/guard/publisher.sh" publish_branch \
    --policy "$EXAMPLE_POLICY" \
    --request "$TEST_TMP/forbidden-$forbidden_field.json" \
    --repo "$REPO" >/dev/null 2>&1; then
    fail "publisher accepted forbidden request field: $forbidden_field"
  fi
done

for forbidden_arg in --force --delete refs/heads/main refs/tags/v1 \
  refs/notes/night refs/replace/object candidate:refs/heads/other; do
  if "$ROOT/guard/publisher.sh" publish_branch \
    --policy "$EXAMPLE_POLICY" \
    --request "$EXAMPLE_REQUEST" \
    --repo "$REPO" \
    "$forbidden_arg" >/dev/null 2>&1; then
    fail "publisher accepted forbidden argv field: $forbidden_arg"
  fi
done

/usr/bin/jq '.candidate_sha="0000000000000000000000000000000000000000000000000000000000000000"' \
  "$EXAMPLE_REQUEST" > "$TEST_TMP/zero-sha256.json"
if "$ROOT/guard/publisher.sh" publish_branch \
  --policy "$EXAMPLE_POLICY" \
  --request "$TEST_TMP/zero-sha256.json" \
  --repo "$REPO" >/dev/null 2>&1; then
  fail "all-zero sha256 object id was accepted"
fi

FAKE_GUARD=$TEST_TMP/fake-guard
mkdir -p "$FAKE_GUARD"
/bin/chmod 700 "$FAKE_GUARD"
for source_name in \
  common.sh broker.sh gateway.sh publisher-lib.sh publisher.sh publisher-askpass.sh \
  remote-preflight.sh scan.sh text-policy.sh; do
  /bin/cp "$ROOT/guard/$source_name" "$FAKE_GUARD/$source_name"
done

FAKE_KEY=$TEST_TMP/private-key.pem
/usr/bin/printf '%s\n' 'FAKE-PRIVATE-KEY' > "$FAKE_KEY"
/bin/chmod 600 "$FAKE_KEY"
FAKE_MANIFEST=$TEST_TMP/guard-activation.json
/bin/cp "$ROOT/config/guard-activation.example.json" "$FAKE_MANIFEST"
/bin/chmod 600 "$FAKE_MANIFEST"
FAKE_AUDIT=$TEST_TMP/audit
/bin/mkdir -p "$FAKE_AUDIT"
/bin/chmod 700 "$FAKE_AUDIT"
FAKE_KEY_SHA256=$(guard_test_key_sha=$(/usr/bin/shasum -a 256 "$FAKE_KEY" | /usr/bin/awk '{print $1}'); builtin printf '%s' "$guard_test_key_sha")
FAKE_AUDIT_DEVICE=$(/usr/bin/stat -f '%d' "$FAKE_AUDIT")
FAKE_AUDIT_INODE=$(/usr/bin/stat -f '%i' "$FAKE_AUDIT")
FAKE_AUDIT_IDENTITY_SHA256=$(
  builtin printf 'path=%s\ndevice=%s\ninode=%s\n' \
    "$FAKE_AUDIT" "$FAKE_AUDIT_DEVICE" "$FAKE_AUDIT_INODE" |
    /usr/bin/shasum -a 256 |
    /usr/bin/awk '{print $1}'
)
FAKE_PUSH_STATE=$TEST_TMP/fake-push-state.json
FAKE_BEHAVIOR=$TEST_TMP/fake-behavior
FAKE_CALL_LOG=$TEST_TMP/fake-call-log.txt
FAKE_REVOKE_COUNT=$TEST_TMP/fake-revoke-count
FAKE_REVOKE_LOG=$TEST_TMP/fake-revoke-log
FAKE_ARGV_CAPTURE=$TEST_TMP/fake-process-argv.txt
FAKE_PUSH_ARGV_CAPTURE=$TEST_TMP/fake-push-argv.txt
FAKE_PUSH_ENV_CAPTURE=$TEST_TMP/fake-push-env.txt
FAKE_PUSH_OUTPUT_CAPTURE=$TEST_TMP/fake-push-output.txt
FAKE_ENV_CAPTURE=$TEST_TMP/fake-process-env.txt
/usr/bin/printf '%s\n' success > "$FAKE_BEHAVIOR"

FAKE_GITLEAKS=$TEST_TMP/fake-gitleaks
/usr/bin/printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'if [ "${1-}" = version ]; then printf "%s\n" "8.30.1"; exit 0; fi' \
  'report=' \
  'for arg in "$@"; do case "$arg" in --report-path=*) report=${arg#*=} ;; esac; done' \
  '[ -n "$report" ] || exit 90' \
  'payload=$report.input' \
  '/bin/cat > "$payload"' \
  'bytes=$(/usr/bin/wc -c < "$payload" | /usr/bin/tr -d " ")' \
  'if /usr/bin/grep -F "NSCAN" "$payload" >/dev/null 2>&1; then' \
  '  /usr/bin/printf "%s\n" "[{\"RuleID\":\"nightshift-generic-api-key\"}]" > "$report"' \
  '  printf "level=debug scanned ~%s bytes (%s bytes)\n" "$bytes" "$bytes" >&2' \
  '  exit 1' \
  'fi' \
  '/usr/bin/printf "%s\n" "[]" > "$report"' \
  'printf "level=debug scanned ~%s bytes (%s bytes)\n" "$bytes" "$bytes" >&2' \
  'exit 0' > "$FAKE_GITLEAKS"
/bin/chmod 755 "$FAKE_GITLEAKS"

FAKE_OPENSSL=$TEST_TMP/fake-openssl
/usr/bin/printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'REAL_OPENSSL=/usr/bin/openssl' \
  "ARGV_CAPTURE=\"$FAKE_ARGV_CAPTURE\"" \
  "ENV_CAPTURE=\"$FAKE_ENV_CAPTURE\"" \
  'printf "openssl" >> "$ARGV_CAPTURE"; for arg in "$@"; do printf " <%s>" "$arg" >> "$ARGV_CAPTURE"; done; printf "\n" >> "$ARGV_CAPTURE"' \
  '/usr/bin/env >> "$ENV_CAPTURE"' \
  'case "${1-}" in' \
  '  base64) exec "$REAL_OPENSSL" "$@" ;;' \
  '  dgst) printf "signed-by-fake-openssl"; exit 0 ;;' \
  '  *) exec "$REAL_OPENSSL" "$@" ;;' \
  'esac' > "$FAKE_OPENSSL"
/bin/chmod 755 "$FAKE_OPENSSL"

FAKE_GIT=$TEST_TMP/fake-git
/usr/bin/printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  "REAL_GIT=\"$REAL_GIT\"" \
  "STATE_PATH=\"$FAKE_PUSH_STATE\"" \
  "BEHAVIOR_PATH=\"$FAKE_BEHAVIOR\"" \
  "ARGV_CAPTURE=\"$FAKE_ARGV_CAPTURE\"" \
  "PUSH_ARGV_CAPTURE=\"$FAKE_PUSH_ARGV_CAPTURE\"" \
  "PUSH_ENV_CAPTURE=\"$FAKE_PUSH_ENV_CAPTURE\"" \
  "PUSH_OUTPUT_CAPTURE=\"$FAKE_PUSH_OUTPUT_CAPTURE\"" \
  "ENV_CAPTURE=\"$FAKE_ENV_CAPTURE\"" \
  'printf "git" >> "$ARGV_CAPTURE"; for arg in "$@"; do printf " <%s>" "$arg" >> "$ARGV_CAPTURE"; done; printf "\n" >> "$ARGV_CAPTURE"' \
  '/usr/bin/env >> "$ENV_CAPTURE"' \
  'for arg in "$@"; do if [ "$arg" = push ]; then is_push=true; fi; if [ "$arg" = init ]; then is_init=true; fi; done' \
  'if [ "${is_push-false}" != true ]; then' \
  '  if [ "${is_init-false}" = true ] && [ "$(/bin/cat "$BEHAVIOR_PATH")" = scratch_init_fail ]; then exit 98; fi' \
  '  exec "$REAL_GIT" "$@"' \
  'fi' \
  'printf "git" >> "$PUSH_ARGV_CAPTURE"; for arg in "$@"; do printf " <%s>" "$arg" >> "$PUSH_ARGV_CAPTURE"; done; printf "\n" >> "$PUSH_ARGV_CAPTURE"' \
  '/usr/bin/env >> "$PUSH_ENV_CAPTURE"' \
  'refspec=' \
  'for arg in "$@"; do refspec=$arg; done' \
  'case "$refspec" in *:refs/heads/night-bot/run-*) ;; *) exit 94 ;; esac' \
  'candidate=${refspec%%:*}' \
  'destination=${refspec#*:}' \
  'token=$("$GIT_ASKPASS" "Password for '\''https://x-access-token@github.test'\'': ") || { printf "%s\n" askpass-failed >> "$PUSH_ARGV_CAPTURE"; exit 95; }' \
  '[ -n "$token" ] || exit 96' \
  'behavior=$(/bin/cat "$BEHAVIOR_PATH")' \
  '[ "$behavior" != push_fail ] || exit 97' \
  "/usr/bin/jq -n --arg dest \"\$destination\" --arg sha \"\$candidate\" '{destination:\$dest,sha:\$sha}' > \"\$STATE_PATH\"" \
  'printf "To https://github.test/sample/repo.git\n" > "$PUSH_OUTPUT_CAPTURE"' \
  'printf "*\t%s\t[new branch]\n" "$refspec" >> "$PUSH_OUTPUT_CAPTURE"' \
  'printf "Done\n" >> "$PUSH_OUTPUT_CAPTURE"' \
  '/bin/cat "$PUSH_OUTPUT_CAPTURE"' \
  'exit 0' > "$FAKE_GIT"
/bin/chmod 755 "$FAKE_GIT"

FAKE_CURL=$TEST_TMP/fake-curl
/usr/bin/printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  "STATE_PATH=\"$FAKE_PUSH_STATE\"" \
  "BEHAVIOR_PATH=\"$FAKE_BEHAVIOR\"" \
  "CALL_LOG=\"$FAKE_CALL_LOG\"" \
  "REVOKE_COUNT=\"$FAKE_REVOKE_COUNT\"" \
  "REVOKE_LOG=\"$FAKE_REVOKE_LOG\"" \
  "ARGV_CAPTURE=\"$FAKE_ARGV_CAPTURE\"" \
  "ENV_CAPTURE=\"$FAKE_ENV_CAPTURE\"" \
  'printf "curl" >> "$ARGV_CAPTURE"; for arg in "$@"; do printf " <%s>" "$arg" >> "$ARGV_CAPTURE"; done; printf "\n" >> "$ARGV_CAPTURE"' \
  '/usr/bin/env >> "$ENV_CAPTURE"' \
  'config=$(/bin/cat)' \
  'printf "%s\n" "$config" | /usr/bin/grep -Fx "connect-timeout = 10" >/dev/null || exit 88' \
  'printf "%s\n" "$config" | /usr/bin/grep -Fx "max-time = 20" >/dev/null || exit 89' \
  'line_value() {' \
  '  key=$1' \
  '  printf "%s\n" "$config" | /usr/bin/sed -n "s/^$key = \"\\(.*\\)\"$/\\1/p" | /usr/bin/head -1' \
  '}' \
  'url=$(line_value url)' \
  'request=$(line_value request)' \
  'output=$(line_value output)' \
  'headers=$(line_value dump-header)' \
  'data_path=$(printf "%s\n" "$config" | /usr/bin/sed -n "s/^data-binary = \"@\\(.*\\)\"$/\\1/p" | /usr/bin/head -1)' \
  'status=200' \
  'response_body=' \
  'behavior=$(/bin/cat "$BEHAVIOR_PATH")' \
  'printf "%s %s\n" "$request" "$url" >> "$CALL_LOG"' \
  'if [ "$behavior" = postpush_timeout ] && [ -f "$STATE_PATH" ] && printf "%s" "$url" | /usr/bin/grep -F "/git/ref/heads/night-bot/" >/dev/null; then exit 28; fi' \
  'if [ -n "$headers" ]; then : > "$headers"; printf "%s\n" "HTTP/1.1 200 OK" > "$headers"; fi' \
  'case "$url" in' \
  '  "https://api.github.test/app")' \
  '    response_body="{\"id\":1001,\"slug\":\"night-publisher\"}"' \
  '    ;;' \
  '  "https://api.github.test/app/installations/2002")' \
  '    response_body="{\"id\":2002,\"account\":{\"login\":\"night-publisher\"},\"repository_selection\":\"selected\",\"permissions\":{\"metadata\":\"read\",\"contents\":\"write\"},\"repositories_url\":\"https://api.github.test/installations/2002/repositories\"}"' \
  '    ;;' \
  '  "https://api.github.test/app/installations/2002/access_tokens")' \
  '    [ -z "$output" ] || exit 91' \
  '    body=$(/bin/cat "$data_path")' \
  '    if printf "%s" "$body" | /usr/bin/grep -F "\"contents\":\"read\"" >/dev/null 2>&1; then' \
  '      token="PUBLISHER_TEST_READ_TOKEN_0000000000000000"' \
  '      perm=read' \
  '    else' \
  '      token="PUBLISHER_TEST_WRITE_TOKEN_0000000000000000"' \
  '      perm=write' \
  '    fi' \
  '    printf "mint-%s\n" "$perm" >> "$REVOKE_LOG"' \
  '    expires_at=$(/bin/date -u -v+30M +%Y-%m-%dT%H:%M:%SZ)' \
  '    [ "$behavior" != long_expiry ] || expires_at=$(/bin/date -u -v+2H +%Y-%m-%dT%H:%M:%SZ)' \
  "    response_body=\$(/usr/bin/jq -cn --arg token \"\$token\" --arg perm \"\$perm\" --arg expires_at \"\$expires_at\" '{token:\$token,expires_at:\$expires_at,repository_selection:\"selected\",permissions:{metadata:\"read\",contents:\$perm},repositories:[{id:42,full_name:\"sample/repo\"}]}')" \
  '    [ "$behavior" != extra_token_key ] || response_body=$(printf "%s" "$response_body" | /usr/bin/jq -c ".extra=true")' \
  '    status=201' \
  '    ;;' \
  '  "https://api.github.test/installation/token")' \
  '    [ -z "$output" ] || exit 92' \
  '    response_body=' \
  '    revoke_count=0; [ ! -f "$REVOKE_COUNT" ] || revoke_count=$(/bin/cat "$REVOKE_COUNT")' \
  '    revoke_count=$((revoke_count + 1)); printf "%s\n" "$revoke_count" > "$REVOKE_COUNT"' \
  '    if printf "%s" "$config" | /usr/bin/grep -F "PUBLISHER_TEST_READ_TOKEN_" >/dev/null 2>&1; then printf "%s\n" revoke-read >> "$REVOKE_LOG"; fi' \
  '    if printf "%s" "$config" | /usr/bin/grep -F "PUBLISHER_TEST_WRITE_TOKEN_" >/dev/null 2>&1; then printf "%s\n" revoke-write >> "$REVOKE_LOG"; fi' \
  '    if [ "$behavior" = revoke_fail ] || { [ "$behavior" = write_revoke_fail ] && [ "$revoke_count" -ge 2 ]; }; then response_body="{\"message\":\"revoke failed\"}"; status=500; else status=204; fi' \
  '    ;;' \
  '  "https://api.github.test/repos/sample/repo")' \
  '    response_body="{\"id\":42,\"full_name\":\"sample/repo\",\"private\":true}"' \
  '    ;;' \
  '  "https://api.github.test/installation/repositories?per_page=2")' \
  '    response_body="{\"total_count\":1,\"repositories\":[{\"id\":42,\"full_name\":\"sample/repo\"}]}"' \
  '    [ "$behavior" != pagination ] || printf "%s\n" "Link: <https://api.github.test/installation/repositories?page=2>; rel=\"next\"" >> "$headers"' \
  '    ;;' \
  '  "https://api.github.test/repos/sample/repo/rulesets?includes_parents=true&per_page=100")' \
  '    response_body="[{\"id\":3003},{\"id\":3004}]"' \
  '    ;;' \
  '  "https://api.github.test/repos/sample/repo/rulesets/3003")' \
  '    response_body="{\"id\":3003,\"rules\":[{\"type\":\"creation\"}]}"' \
  '    [ "$behavior" != ruleset_detail_pagination ] || printf "%s\n" "Link: <https://api.github.test/repos/sample/repo/rulesets/3003?page=2>; rel=\"next\"" >> "$headers"' \
  '    ;;' \
  '  "https://api.github.test/repos/sample/repo/rulesets/3004")' \
  '    response_body="{\"id\":3004,\"rules\":[{\"type\":\"update\"}]}"' \
  '    ;;' \
  '  "https://api.github.test/repos/sample/repo/rules/branches/main?per_page=100")' \
  '    response_body="{\"ref\":\"main\",\"rules\":[{\"id\":3003},{\"id\":3004}]}"' \
  '    [ "$behavior" != effective_rules_pagination ] || printf "%s\n" "Link: <https://api.github.test/repos/sample/repo/rules/branches/main?page=2>; rel=\"next\"" >> "$headers"' \
  '    ;;' \
  '  "https://api.github.test/repos/sample/repo/rules/branches/night-bot%2Frun-20260730-0002-fedcba98?per_page=100")' \
  '    response_body="{\"ref\":\"night-bot/run-20260730-0002-fedcba98\",\"rules\":[{\"id\":3003},{\"id\":3004}]}"' \
  '    ;;' \
  '  "https://api.github.test/repos/sample/repo/git/ref/heads/main")' \
  "    main_sha='$BASE_SHA'" \
  '    [ "$behavior" != main_drift ] || main_sha=1111111111111111111111111111111111111111' \
  '    if [ "$behavior" = postpush_main_drift ] && [ -f "$STATE_PATH" ]; then main_sha=1111111111111111111111111111111111111111; fi' \
  "    response_body=\$(/usr/bin/jq -cn --arg sha \"\$main_sha\" '{object:{sha:\$sha}}')" \
  '    ;;' \
  '  "https://api.github.test/repos/sample/repo/git/ref/heads/night-bot/run-20260730-0002-fedcba98")' \
  '    if [ -f "$STATE_PATH" ]; then' \
  '      sha=$(/usr/bin/jq -r ".sha" "$STATE_PATH")' \
  '      [ "$behavior" != postpush_mismatch ] || sha=1111111111111111111111111111111111111111' \
  "      response_body=\$(/usr/bin/jq -cn --arg sha \"\$sha\" '{object:{sha:\$sha}}')" \
  '      status=200' \
  '    else' \
  '      response_body="{\"message\":\"Not Found\"}"' \
  '      [ -z "$headers" ] || printf "%s\n" "HTTP/1.1 404 Not Found" > "$headers"' \
  '      status=404' \
  '    fi' \
  '    ;;' \
  '  "https://api.github.test/repos/sample/repo/tags?per_page=1")' \
  '    response_body="[]"' \
  '    if [ "$behavior" = postpush_tags_drift ] && [ -f "$STATE_PATH" ]; then response_body="[{\"name\":\"v1\"}]"; fi' \
  '    ;;' \
  '  "https://api.github.test/repos/sample/repo/releases?per_page=1")' \
  '    response_body="[]"' \
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
  "$ROOT/guard/common.sh" > "$FAKE_GUARD/common.sh"
/bin/chmod 755 "$FAKE_GUARD/common.sh"
/usr/bin/sed \
  "s|/opt/homebrew/Cellar/gitleaks/8.30.1/bin/gitleaks|$FAKE_GITLEAKS|g" \
  "$ROOT/guard/scan.sh" > "$FAKE_GUARD/scan.sh"
/usr/bin/sed \
  "s|/opt/homebrew/Cellar/gitleaks/8.30.1/bin/gitleaks|$FAKE_GITLEAKS|g" \
  "$ROOT/guard/text-policy.sh" > "$FAKE_GUARD/text-policy.sh"
/bin/chmod 755 "$FAKE_GUARD/scan.sh" "$FAKE_GUARD/text-policy.sh"
for source_name in \
  broker.sh gateway.sh publisher-lib.sh publisher.sh publisher-askpass.sh remote-preflight.sh; do
  /bin/chmod 755 "$FAKE_GUARD/$source_name"
done
REMOTE_DISABLE_LINE=$(
  /usr/bin/awk '/^publisher_disable_secret_leak_paths$/ { print NR; exit }' \
    "$FAKE_GUARD/remote-preflight.sh"
)
REMOTE_TOKEN_READ_LINE=$(
  /usr/bin/awk '/^IFS= read -r preflight_token/ { print NR; exit }' \
    "$FAKE_GUARD/remote-preflight.sh"
)
case "$REMOTE_DISABLE_LINE:$REMOTE_TOKEN_READ_LINE" in
  *[!0-9:]* | :* | *:) fail "remote preflight hardening order is not inspectable" ;;
esac
[ "$REMOTE_DISABLE_LINE" -lt "$REMOTE_TOKEN_READ_LINE" ] ||
  fail "remote preflight reads its token before disabling leak paths"
if /usr/bin/grep -F '$preflight_token' "$FAKE_GUARD/remote-preflight.sh" |
  /usr/bin/grep -F '/usr/bin/printf' >/dev/null 2>&1; then
  fail "remote preflight exposes its token through external printf argv"
fi
assert_contains "builtin printf '%s\\n' \"\$preflight_token\"" \
  "$FAKE_GUARD/remote-preflight.sh"
/usr/bin/sed \
  -e 's|https://api.github.com|https://api.github.test|g' \
  -e 's|https://github.com|https://github.test|g' \
  "$FAKE_GUARD/publisher-lib.sh" > "$FAKE_GUARD/publisher-lib.sh.rewritten"
/bin/mv "$FAKE_GUARD/publisher-lib.sh.rewritten" "$FAKE_GUARD/publisher-lib.sh"
/bin/chmod 755 "$FAKE_GUARD/publisher-lib.sh"

runtime_spec() {
  runtime_path=$1
  /usr/bin/jq -cn \
    --arg sha256 "$(guard_test_sha=$(/usr/bin/shasum -a 256 "$runtime_path" | /usr/bin/awk '{print $1}'); builtin printf '%s' "$guard_test_sha")" \
    --argjson uid "$(/usr/bin/stat -f '%u' "$runtime_path")" \
    --arg mode "$(/usr/bin/stat -f '%Lp' "$runtime_path")" \
    '{sha256:$sha256,uid:$uid,mode:$mode}'
}
RUNTIME_JSON=$(
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
    '{"ref":"night-bot/run-20260730-0002-fedcba98","rules":[{"id":3003},{"id":3004}]}' |
    /usr/bin/jq -cS . |
    /usr/bin/shasum -a 256 |
    /usr/bin/awk '{print $1}'
)

ACTIVE_POLICY=$TEST_TMP/active-policy.json
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
  --argjson runtime "$RUNTIME_JSON" '
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
ACTIVE_REQUEST=$TEST_TMP/active-request.json
/usr/bin/jq -n \
  --arg base_sha "$BASE_SHA" \
  --arg candidate_sha "$CANDIDATE_SHA" \
  --arg policy_sha256 "$ACTIVE_POLICY_SHA" '
  {
    schema:"alpha-nightshift/publish-request/v1",
    operation:"publish_branch",
    request_id:"REQ-20260730-0002-fedcba9876543210",
    repo_id:"sample/repo",
    repository_id:42,
    base_sha:$base_sha,
    candidate_sha:$candidate_sha,
    policy_sha256:$policy_sha256
  }' > "$ACTIVE_REQUEST"
ACTIVE_REQUEST_DIGEST=$(
  /usr/bin/jq -cS . "$ACTIVE_REQUEST" |
    /usr/bin/shasum -a 256 |
    /usr/bin/awk '{print $1}'
)

# A credential-bearing push must not consult source-repository config. Exercise
# the same scratch-dir/object-dir shape against local bare repositories, with
# hostile redirect/proxy/TLS/credential settings planted in the source config.
REAL_PUSH_TARGET=$TEST_TMP/real-push-target.git
REAL_PUSH_REDIRECT=$TEST_TMP/real-push-redirect.git
REAL_PUSH_SCRATCH=$TEST_TMP/real-push-scratch.git
REAL_PUSH_OUTPUT=$TEST_TMP/real-push-porcelain.txt
"$REAL_GIT" init --bare -q "$REAL_PUSH_TARGET"
"$REAL_GIT" init --bare -q "$REAL_PUSH_REDIRECT"
"$REAL_GIT" init --bare -q "$REAL_PUSH_SCRATCH"
"$REAL_GIT" -C "$REPO" config \
  "url.file://$REAL_PUSH_REDIRECT.pushInsteadOf" "file://$REAL_PUSH_TARGET"
"$REAL_GIT" -C "$REPO" config http.proxy \
  'http://PUBLISHER_REPO_CONFIG_CANARY.invalid'
"$REAL_GIT" -C "$REPO" config http.sslVerify false
"$REAL_GIT" -C "$REPO" config credential.helper \
  '!printf PUBLISHER_REPO_CONFIG_CANARY'
REAL_SOURCE_OBJECTS=$(
  "$REAL_GIT" -C "$REPO" rev-parse --path-format=absolute --git-path objects
)
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
  GIT_OBJECT_DIRECTORY="$REAL_SOURCE_OBJECTS" \
  "$REAL_GIT" \
    --no-pager \
    --git-dir="$REAL_PUSH_SCRATCH" \
    -c core.hooksPath=/dev/null \
    -c core.fsmonitor=false \
    -c credential.helper= \
    -c protocol.file.allow=always \
    push --porcelain \
    "file://$REAL_PUSH_TARGET" \
    "$CANDIDATE_SHA:refs/heads/night-bot/run-20260730-0002-fedcba98" \
    > "$REAL_PUSH_OUTPUT"
(
  . "$ROOT/guard/common.sh"
  . "$ROOT/guard/publisher-lib.sh"
  PUBLISH_CANDIDATE_SHA=$CANDIDATE_SHA
  PUBLISH_DESTINATION_REF=refs/heads/night-bot/run-20260730-0002-fedcba98
  publisher_verify_push_output "$REAL_PUSH_OUTPUT"
)
ADVERSARIAL_PUSH_OUTPUT=$TEST_TMP/adversarial-push-porcelain.txt
/bin/cp "$REAL_PUSH_OUTPUT" "$ADVERSARIAL_PUSH_OUTPUT"
/usr/bin/printf '*\t%s:refs/heads/night-bot/run-extra\t[new branch]\n' \
  "$CANDIDATE_SHA" >> "$ADVERSARIAL_PUSH_OUTPUT"
if (
  . "$ROOT/guard/common.sh"
  . "$ROOT/guard/publisher-lib.sh"
  PUBLISH_CANDIDATE_SHA=$CANDIDATE_SHA
  PUBLISH_DESTINATION_REF=refs/heads/night-bot/run-20260730-0002-fedcba98
  publisher_verify_push_output "$ADVERSARIAL_PUSH_OUTPUT"
) >/dev/null 2>&1; then
  fail "porcelain parser accepted an additional ref status"
fi
[ "$("$REAL_GIT" --git-dir="$REAL_PUSH_TARGET" rev-parse refs/heads/night-bot/run-20260730-0002-fedcba98)" = "$CANDIDATE_SHA" ] ||
  fail "scratch raw-SHA push did not reach the intended bare repository"
if "$REAL_GIT" --git-dir="$REAL_PUSH_REDIRECT" \
  rev-parse refs/heads/night-bot/run-20260730-0002-fedcba98 >/dev/null 2>&1; then
  fail "source repository pushInsteadOf redirected the scratch push"
fi
assert_not_contains PUBLISHER_REPO_CONFIG_CANARY "$REAL_PUSH_OUTPUT"
"$REAL_GIT" -C "$REPO" config --unset-all \
  "url.file://$REAL_PUSH_REDIRECT.pushInsteadOf"
"$REAL_GIT" -C "$REPO" config --unset-all http.proxy
"$REAL_GIT" -C "$REPO" config --unset-all http.sslVerify
"$REAL_GIT" -C "$REPO" config --unset-all credential.helper

/usr/bin/printf '%s\n' '#!/bin/bash' \
  ': > "'"$TEST_TMP"'/bash-env-was-sourced"' > "$TEST_TMP/bash-env-attack"
/usr/bin/env \
  BASH_ENV="$TEST_TMP/bash-env-attack" \
  ENV="$TEST_TMP/bash-env-attack" \
  HTTPS_PROXY='PUBLISHER_ENV_CANARY_SHOULD_NOT_ESCAPE' \
  OPENSSL_CONF='PUBLISHER_ENV_CANARY_SHOULD_NOT_ESCAPE' \
  GIT_CONFIG_COUNT=1 \
  SHELLOPTS=xtrace \
  PUBLISHER_ENV_CANARY='PUBLISHER_ENV_CANARY_SHOULD_NOT_ESCAPE' \
  "$FAKE_GUARD/gateway.sh" publish_branch \
  --policy "$ACTIVE_POLICY" \
  --request "$ACTIVE_REQUEST" \
  --repo "$REPO" \
  > "$TEST_TMP/active-success.json" \
  2> "$TEST_TMP/active-success.err"
[ ! -e "$TEST_TMP/bash-env-was-sourced" ] ||
  fail "documented gateway path sourced BASH_ENV or ENV"
assert_not_contains 'PUBLISHER_TEST_READ_TOKEN_' "$TEST_TMP/active-success.err"
assert_not_contains 'PUBLISHER_TEST_WRITE_TOKEN_' "$TEST_TMP/active-success.err"
assert_not_contains 'PUBLISHER_ENV_CANARY_SHOULD_NOT_ESCAPE' "$TEST_TMP/active-success.err"
/usr/bin/jq -e '
  .verdict == "SUCCESS" and
  .write_mode == true and
  .destination_ref == "refs/heads/night-bot/run-20260730-0002-fedcba98" and
  .detail.actor == "app/night-publisher#installation/2002" and
  .detail.rule_suite_result == "UNPROVEN_NO_ADMIN_READ" and
  .detail.before_sha == "0000000000000000000000000000000000000000" and
  .detail.after_sha == .candidate_sha
' "$TEST_TMP/active-success.json" >/dev/null ||
  fail "mock active publish did not return the expected success evidence"

AUDIT_FILE=$FAKE_AUDIT/REQ-20260730-0002-fedcba9876543210.jsonl
assert_file_exists "$AUDIT_FILE"
[ "$(/usr/bin/wc -l < "$AUDIT_FILE" | /usr/bin/tr -d ' ')" -eq 2 ] ||
  fail "mock publish did not write a two-phase audit record"
assert_not_contains 'PUBLISHER_TEST_READ_TOKEN_' "$AUDIT_FILE"
assert_not_contains 'PUBLISHER_TEST_WRITE_TOKEN_' "$AUDIT_FILE"
assert_not_contains 'signed-by-fake-openssl' "$AUDIT_FILE"
PAIR_READ=$TEST_TMP/pair-read.json
PAIR_PREPUSH=$TEST_TMP/pair-prepush.json
PAIR_POSTPUSH=$TEST_TMP/pair-postpush.json
/usr/bin/sed -n '1p' "$AUDIT_FILE" |
  /usr/bin/jq -c '.detail.read_preflight' > "$PAIR_READ"
/usr/bin/sed -n '2p' "$AUDIT_FILE" |
  /usr/bin/jq -c '.detail.prepush' > "$PAIR_PREPUSH"
/usr/bin/sed -n '2p' "$AUDIT_FILE" |
  /usr/bin/jq -c '.detail.postpush' > "$PAIR_POSTPUSH"
MALFORMED_PAIR=$TEST_TMP/malformed-preflight-pair.json
/usr/bin/jq '.main_tip_sha="" | .destination_state=null' \
  "$PAIR_PREPUSH" > "$MALFORMED_PAIR"
if (
  . "$ROOT/guard/common.sh"
  . "$ROOT/guard/publisher-lib.sh"
  publisher_verify_read_prepush_pair "$PAIR_READ" "$MALFORMED_PAIR"
) >/dev/null 2>&1; then
  fail "read/prepush pair accepted empty SHA or null destination state"
fi
/usr/bin/jq '.destination_sha=""' "$PAIR_POSTPUSH" > "$MALFORMED_PAIR"
if (
  . "$ROOT/guard/common.sh"
  . "$ROOT/guard/publisher-lib.sh"
  PUBLISH_CANDIDATE_SHA=$CANDIDATE_SHA
  publisher_verify_postpush_pair "$PAIR_PREPUSH" "$MALFORMED_PAIR"
) >/dev/null 2>&1; then
  fail "postpush pair accepted an empty destination SHA"
fi
EMPTY_PAIR_DOCUMENT=$TEST_TMP/empty-preflight-document.json
: > "$EMPTY_PAIR_DOCUMENT"
if (
  . "$ROOT/guard/common.sh"
  . "$ROOT/guard/publisher-lib.sh"
  publisher_verify_read_prepush_pair "$PAIR_READ" "$EMPTY_PAIR_DOCUMENT"
) >/dev/null 2>&1; then
  fail "read/prepush pair accepted fewer than two documents"
fi
/usr/bin/jq '.ruleset_result.main_effective_sha256=null' \
  "$PAIR_PREPUSH" > "$MALFORMED_PAIR"
if (
  . "$ROOT/guard/common.sh"
  . "$ROOT/guard/publisher-lib.sh"
  publisher_verify_read_prepush_pair "$PAIR_READ" "$MALFORMED_PAIR"
) >/dev/null 2>&1; then
  fail "read/prepush pair accepted a null ruleset digest"
fi
/usr/bin/jq '.rule_suite_result=null' "$PAIR_POSTPUSH" > "$MALFORMED_PAIR"
if (
  . "$ROOT/guard/common.sh"
  . "$ROOT/guard/publisher-lib.sh"
  PUBLISH_CANDIDATE_SHA=$CANDIDATE_SHA
  publisher_verify_postpush_pair "$PAIR_PREPUSH" "$MALFORMED_PAIR"
) >/dev/null 2>&1; then
  fail "postpush pair accepted a null rule-suite result"
fi
assert_not_contains 'PUBLISHER_TEST_READ_TOKEN_' "$FAKE_ARGV_CAPTURE"
assert_not_contains 'PUBLISHER_TEST_WRITE_TOKEN_' "$FAKE_ARGV_CAPTURE"
assert_not_contains 'PUBLISHER_TEST_READ_TOKEN_' "$FAKE_ENV_CAPTURE"
assert_not_contains 'PUBLISHER_TEST_WRITE_TOKEN_' "$FAKE_ENV_CAPTURE"
assert_not_contains 'signed-by-fake-openssl' "$FAKE_ARGV_CAPTURE"
assert_not_contains 'signed-by-fake-openssl' "$FAKE_ENV_CAPTURE"
assert_not_contains 'PUBLISHER_ENV_CANARY_SHOULD_NOT_ESCAPE' "$FAKE_ENV_CAPTURE"
[ "$(/bin/cat "$FAKE_REVOKE_COUNT")" -eq 2 ] ||
  fail "successful publication did not revoke exactly two installation tokens"
[ "$(/usr/bin/tr '\n' ' ' < "$FAKE_REVOKE_LOG")" = \
  "mint-read revoke-read mint-write revoke-write " ] ||
  fail "successful publication did not keep read-before-write mint/revoke order"
JWT_SIGN_COUNT=$(
  LC_ALL=C /usr/bin/grep -c '^openssl.*<dgst>' "$FAKE_ARGV_CAPTURE" || :
)
[ "$JWT_SIGN_COUNT" -eq 2 ] ||
  fail "successful publication JWT sign count was $JWT_SIGN_COUNT instead of 2"
if /usr/bin/grep -F -- "--git-dir=$REPO/.git" "$FAKE_PUSH_ARGV_CAPTURE" >/dev/null 2>&1; then
  fail "credential-bearing Git push read the lane repository Git directory"
fi
LC_ALL=C /usr/bin/grep -E \
  '<--git-dir=/private/tmp/nightshift-publisher\.[A-Za-z0-9]+/git>' \
  "$FAKE_PUSH_ARGV_CAPTURE" >/dev/null ||
  fail "credential-bearing Git push did not use its scratch bare Git directory"
assert_contains '<protocol.file.allow=never>' "$FAKE_PUSH_ARGV_CAPTURE"
assert_contains "GIT_OBJECT_DIRECTORY=$REAL_SOURCE_OBJECTS" "$FAKE_PUSH_ENV_CAPTURE"
assert_not_contains 'PUBLISHER_TEST_READ_TOKEN_' "$FAKE_PUSH_OUTPUT_CAPTURE"
assert_not_contains 'PUBLISHER_TEST_WRITE_TOKEN_' "$FAKE_PUSH_OUTPUT_CAPTURE"
assert_not_contains 'PUBLISHER_REPO_CONFIG_CANARY' "$FAKE_PUSH_OUTPUT_CAPTURE"

/bin/rm -f "$FAKE_CALL_LOG"
if builtin printf '%s\n' 'PUBLISHER_TEST_READ_TOKEN_0000000000000000' |
  /usr/bin/env -i \
    HOME=/var/empty \
    LANG=C \
    LC_ALL=C \
    PATH=/usr/bin:/bin \
    /bin/bash -p "$FAKE_GUARD/remote-preflight.sh" \
      --phase read \
      --policy "$ACTIVE_POLICY" \
      --request "$ACTIVE_REQUEST" \
      --request-sha256 0000000000000000000000000000000000000000000000000000000000000000 \
      --repo "$REPO" >/dev/null 2>&1; then
  fail "remote preflight accepted a changed request digest"
fi
[ ! -e "$FAKE_CALL_LOG" ] ||
  fail "request digest mismatch reached a network-capable program"

/bin/rm -f "$FAKE_CALL_LOG"
if builtin printf '%s\n' invalid-token |
  /usr/bin/env -i \
    HOME=/var/empty \
    LANG=C \
    LC_ALL=C \
    PATH=/usr/bin:/bin \
    /bin/bash -p "$FAKE_GUARD/remote-preflight.sh" \
      --phase read \
      --policy "$ACTIVE_POLICY" \
      --request "$ACTIVE_REQUEST" \
      --request-sha256 "$ACTIVE_REQUEST_DIGEST" \
      --repo "$REPO" >/dev/null 2>&1; then
  fail "remote preflight accepted a malformed installation token"
fi
[ ! -e "$FAKE_CALL_LOG" ] ||
  fail "malformed remote-preflight token reached a network-capable program"

for ruleset_digest_field in \
  definitions_sha256 main_effective_sha256 generated_effective_sha256; do
  /bin/rm -f \
    "$FAKE_PUSH_STATE" "$FAKE_REVOKE_COUNT" "$FAKE_REVOKE_LOG" \
    "$FAKE_CALL_LOG" "$AUDIT_FILE"
  MISMATCH_POLICY=$TEST_TMP/mismatch-policy-$ruleset_digest_field.json
  MISMATCH_REQUEST=$TEST_TMP/mismatch-request-$ruleset_digest_field.json
  /usr/bin/jq --arg field "$ruleset_digest_field" \
    '.rulesets.expected[$field] = "0000000000000000000000000000000000000000000000000000000000000000"' \
    "$ACTIVE_POLICY" > "$MISMATCH_POLICY"
  /bin/chmod 600 "$MISMATCH_POLICY"
  MISMATCH_POLICY_SHA=$(
    /usr/bin/jq -cS . "$MISMATCH_POLICY" |
      /usr/bin/shasum -a 256 |
      /usr/bin/awk '{print $1}'
  )
  /usr/bin/jq --arg policy_sha256 "$MISMATCH_POLICY_SHA" \
    '.policy_sha256=$policy_sha256' "$ACTIVE_REQUEST" > "$MISMATCH_REQUEST"
  if "$FAKE_GUARD/publisher.sh" publish_branch \
    --policy "$MISMATCH_POLICY" \
    --request "$MISMATCH_REQUEST" \
    --repo "$REPO" \
    > "$TEST_TMP/mismatch-$ruleset_digest_field.out" \
    2> "$TEST_TMP/mismatch-$ruleset_digest_field.err"; then
    fail "publisher accepted ruleset baseline mismatch: $ruleset_digest_field"
  fi
  [ ! -e "$FAKE_PUSH_STATE" ] ||
    fail "ruleset baseline mismatch reached the push boundary: $ruleset_digest_field"
  [ ! -e "$AUDIT_FILE" ] ||
    fail "ruleset baseline mismatch wrote a publish attempt: $ruleset_digest_field"
done

run_active_failure() {
  failure_mode=$1
  expected_audit=$2
  /bin/rm -f \
    "$FAKE_PUSH_STATE" "$FAKE_REVOKE_COUNT" "$FAKE_REVOKE_LOG" \
    "$FAKE_CALL_LOG" "$AUDIT_FILE"
  /usr/bin/printf '%s\n' "$failure_mode" > "$FAKE_BEHAVIOR"
  if "$FAKE_GUARD/publisher.sh" publish_branch \
    --policy "$ACTIVE_POLICY" \
    --request "$ACTIVE_REQUEST" \
    --repo "$REPO" \
    > "$TEST_TMP/failure-$failure_mode.out" \
    2> "$TEST_TMP/failure-$failure_mode.err"; then
    fail "active mock unexpectedly succeeded in failure mode: $failure_mode"
  fi
  assert_not_contains 'PUBLISHER_TEST_READ_TOKEN_' "$TEST_TMP/failure-$failure_mode.out"
  assert_not_contains 'PUBLISHER_TEST_WRITE_TOKEN_' "$TEST_TMP/failure-$failure_mode.out"
  assert_not_contains 'PUBLISHER_TEST_READ_TOKEN_' "$TEST_TMP/failure-$failure_mode.err"
  assert_not_contains 'PUBLISHER_TEST_WRITE_TOKEN_' "$TEST_TMP/failure-$failure_mode.err"
  case "$expected_audit" in
    incident)
      assert_file_exists "$AUDIT_FILE"
      [ "$(/usr/bin/wc -l < "$AUDIT_FILE" | /usr/bin/tr -d ' ')" -eq 2 ] ||
        fail "$failure_mode did not leave attempt plus incident records"
      /usr/bin/jq -s -e '
        .[0].type == "publish_attempt" and
        .[1].type == "publish_result" and
        .[1].verdict == "PUBLISH_UNVERIFIED_INCIDENT"
      ' "$AUDIT_FILE" >/dev/null ||
        fail "$failure_mode audit did not classify the result as incident"
      ;;
    pre_attempt_incident)
      assert_file_exists "$AUDIT_FILE"
      [ "$(/usr/bin/wc -l < "$AUDIT_FILE" | /usr/bin/tr -d ' ')" -eq 1 ] ||
        fail "$failure_mode did not leave exactly one pre-attempt incident"
      /usr/bin/jq -e '
        .type == "publish_result" and
        .verdict == "PUBLISH_UNVERIFIED_INCIDENT" and
        .detail.phase == "read_token_revoke" and
        .detail.network_write_attempted == false
      ' "$AUDIT_FILE" >/dev/null ||
        fail "$failure_mode did not record a redacted read-revoke incident"
      ;;
    no_audit | no_token_no_audit)
      [ ! -e "$AUDIT_FILE" ] ||
        fail "$failure_mode wrote an audit before the push boundary"
      ;;
    *) fail "unknown expected audit mode: $expected_audit" ;;
  esac
  if [ "$expected_audit" = no_token_no_audit ]; then
    [ ! -e "$FAKE_REVOKE_COUNT" ] ||
      fail "$failure_mode unexpectedly reached token revocation"
  else
    [ -f "$FAKE_REVOKE_COUNT" ] ||
      fail "$failure_mode did not attempt token revocation"
  fi
}

PUBLISHER_TMP_COUNT_BEFORE=$(
  /usr/bin/find /tmp -maxdepth 1 -type d -name 'nightshift-publisher.*' |
    /usr/bin/wc -l |
    /usr/bin/tr -d ' '
)
run_active_failure scratch_init_fail no_token_no_audit
PUBLISHER_TMP_COUNT_AFTER=$(
  /usr/bin/find /tmp -maxdepth 1 -type d -name 'nightshift-publisher.*' |
    /usr/bin/wc -l |
    /usr/bin/tr -d ' '
)
[ "$PUBLISHER_TMP_COUNT_AFTER" -eq "$PUBLISHER_TMP_COUNT_BEFORE" ] ||
  fail "scratch Git initialization failure left a publisher temporary directory"

run_active_failure long_expiry no_audit
run_active_failure extra_token_key no_audit
run_active_failure pagination no_audit
run_active_failure effective_rules_pagination no_audit
run_active_failure ruleset_detail_pagination no_audit
run_active_failure main_drift no_audit
run_active_failure revoke_fail pre_attempt_incident
run_active_failure push_fail incident
run_active_failure postpush_timeout incident
run_active_failure postpush_mismatch incident
run_active_failure postpush_main_drift incident
run_active_failure postpush_tags_drift incident
run_active_failure write_revoke_fail incident

/usr/bin/printf '%s\n' success > "$FAKE_BEHAVIOR"

# Real-Git contract probe: Git receives no credential on stdin, argv, or env.
# Git 2.48.1 preserves inherited FD 3 for the askpass child after loopback HTTP
# 401 challenges; the higher FD 9 is not a supported part of this contract.
PROBE_GIT=/opt/homebrew/Cellar/git/2.48.1/bin/git
[ -x "$PROBE_GIT" ] || fail "fixed Git path is unavailable for the askpass FD probe"
PROBE_GIT_VERSION=$("$PROBE_GIT" --version)
FD_PROBE_CREDENTIAL=PUBLISHER_TEST_FD_TOKEN_0000000000000000
FD_PROBE_AUTH_DIGEST=$(
  builtin printf '%s' "$FD_PROBE_CREDENTIAL" |
    /usr/bin/shasum -a 256 |
    /usr/bin/awk '{print $1}'
)
FD_PROBE_SERVER=$TEST_TMP/fd-probe-server.py
FD_PROBE_PORT=$TEST_TMP/fd-probe-port
FD_PROBE_MARKER=$TEST_TMP/fd-probe-auth-ok
FD_PROBE_OBSERVED_DIGEST=$TEST_TMP/fd-probe-observed-digest
/usr/bin/printf '%s\n' \
  'import hashlib' \
  'import hmac' \
  'import base64' \
  'import sys' \
  'from http.server import BaseHTTPRequestHandler, HTTPServer' \
  '' \
  'expected_digest, marker_path, port_path, observed_digest_path = sys.argv[1:5]' \
  '' \
  'class Handler(BaseHTTPRequestHandler):' \
  '    protocol_version = "HTTP/1.1"' \
  '    accepted = False' \
  '' \
  '    def log_message(self, _format, *_args):' \
  '        pass' \
  '' \
  '    def do_GET(self):' \
  '        authorization = self.headers.get("Authorization", "")' \
  '        if not authorization:' \
  '            self.send_response(401)' \
  '            self.send_header("WWW-Authenticate", "Basic realm=\"publisher-fd-probe\"")' \
  '            self.send_header("Content-Length", "0")' \
  '            self.end_headers()' \
  '            return' \
  '        scheme, encoded = authorization.split(" ", 1)' \
  '        username, password = base64.b64decode(encoded).decode("ascii").split(":", 1)' \
  '        actual_digest = hashlib.sha256(password.encode("ascii")).hexdigest()' \
  '        with open(observed_digest_path, "w", encoding="ascii") as observed:' \
  '            observed.write(actual_digest)' \
  '        if scheme == "Basic" and username == "x-access-token" and hmac.compare_digest(actual_digest, expected_digest):' \
  '            with open(marker_path, "w", encoding="ascii") as marker:' \
  '                marker.write("AUTH_OK\n")' \
  '            Handler.accepted = True' \
  '            body = b"001e# service=git-upload-pack\n00000000"' \
  '            self.send_response(200)' \
  '            self.send_header("Content-Type", "application/x-git-upload-pack-advertisement")' \
  '            self.send_header("Content-Length", str(len(body)))' \
  '            self.end_headers()' \
  '            self.wfile.write(body)' \
  '            return' \
  '        self.send_response(401)' \
  '        self.send_header("WWW-Authenticate", "Basic realm=\"publisher-fd-probe\"")' \
  '        self.send_header("Content-Length", "0")' \
  '        self.end_headers()' \
  '' \
  'server = HTTPServer(("127.0.0.1", 0), Handler)' \
  'server.timeout = 5' \
  'with open(port_path, "w", encoding="ascii") as port_file:' \
  '    port_file.write(str(server.server_port))' \
  'for _attempt in range(4):' \
  '    server.handle_request()' \
  '    if Handler.accepted:' \
  '        break' \
  'server.server_close()' > "$FD_PROBE_SERVER"
/usr/bin/python3 "$FD_PROBE_SERVER" \
  "$FD_PROBE_AUTH_DIGEST" "$FD_PROBE_MARKER" "$FD_PROBE_PORT" \
  "$FD_PROBE_OBSERVED_DIGEST" \
  > "$TEST_TMP/fd-probe-server.out" \
  2> "$TEST_TMP/fd-probe-server.err" &
FD_PROBE_SERVER_PID=$!
fd_probe_wait=0
while [ ! -s "$FD_PROBE_PORT" ] && [ "$fd_probe_wait" -lt 50 ]; do
  /bin/sleep 0.1
  fd_probe_wait=$((fd_probe_wait + 1))
done
[ -s "$FD_PROBE_PORT" ] || fail "loopback askpass FD probe did not start"
FD_PROBE_HTTP_PORT=$(/bin/cat "$FD_PROBE_PORT")
FD_PROBE_ASKPASS=$TEST_TMP/fd-probe-askpass.sh
FD_PROBE_ASKPASS_INNER=$TEST_TMP/fd-probe-askpass-inner.sh
FD_PROBE_PROMPT=$TEST_TMP/fd-probe-prompt.txt
/usr/bin/sed \
  's|https://x-access-token@|http://x-access-token@|g' \
  "$FAKE_GUARD/publisher-askpass.sh" > "$FD_PROBE_ASKPASS_INNER"
/usr/bin/printf '%s\n' \
  '#!/bin/bash -p' \
  "builtin printf '%s' \"\${1-}\" > \"$FD_PROBE_PROMPT\"" \
  "exec \"$FD_PROBE_ASKPASS_INNER\" \"\$@\"" > "$FD_PROBE_ASKPASS"
/bin/chmod 755 "$FD_PROBE_ASKPASS" "$FD_PROBE_ASKPASS_INNER"
set +e
{
  builtin printf '%s\n%s\n' \
    "Password for 'http://x-access-token@127.0.0.1:$FD_PROBE_HTTP_PORT': " \
    "$FD_PROBE_CREDENTIAL"
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
      GIT_ASKPASS="$FD_PROBE_ASKPASS" \
      SSH_ASKPASS=/usr/bin/false \
      GIT_NO_REPLACE_OBJECTS=1 \
      "$PROBE_GIT" \
        --no-pager \
        -c credential.helper= \
        -c protocol.file.allow=never \
        ls-remote \
        "http://x-access-token@127.0.0.1:$FD_PROBE_HTTP_PORT/repo.git"
  ) > "$TEST_TMP/fd-probe-git.out" 2> "$TEST_TMP/fd-probe-git.err"
FD_PROBE_GIT_RC=$?
set -e
wait "$FD_PROBE_SERVER_PID" || fail "loopback askpass FD probe server failed"
assert_not_contains "$FD_PROBE_CREDENTIAL" "$TEST_TMP/fd-probe-git.out"
assert_not_contains "$FD_PROBE_CREDENTIAL" "$TEST_TMP/fd-probe-git.err"
assert_not_contains "$FD_PROBE_CREDENTIAL" "$TEST_TMP/fd-probe-server.out"
assert_not_contains "$FD_PROBE_CREDENTIAL" "$TEST_TMP/fd-probe-server.err"
if [ ! -f "$FD_PROBE_MARKER" ]; then
  /bin/cat "$TEST_TMP/fd-probe-git.err" >&2
  /bin/cat "$TEST_TMP/fd-probe-server.err" >&2
  builtin printf 'expected auth digest: %s\n' "$FD_PROBE_AUTH_DIGEST" >&2
  if [ -f "$FD_PROBE_OBSERVED_DIGEST" ]; then
    builtin printf 'observed auth digest: %s\n' "$(/bin/cat "$FD_PROBE_OBSERVED_DIGEST")" >&2
  fi
  if [ -f "$FD_PROBE_PROMPT" ]; then
    builtin printf 'observed askpass prompt: <%s>\n' "$(/bin/cat "$FD_PROBE_PROMPT")" >&2
  fi
  fail "real Git askpass FD probe did not authenticate"
fi
assert_contains AUTH_OK "$FD_PROBE_MARKER"
builtin printf 'askpass FD3 probe Git: %s\n' "$PROBE_GIT_VERSION"
LC_ALL=C /usr/bin/printf '%s\n' "$PROBE_GIT_VERSION" |
  /usr/bin/grep -E '^git version [0-9]+(\.[0-9]+){1,3}([. -].*)?$' >/dev/null ||
  fail "real Git askpass FD probe did not report a valid Git version"
[ "$FD_PROBE_GIT_RC" -eq 0 ] ||
  fail "real Git askpass FD probe did not complete successfully"
unset FD_PROBE_CREDENTIAL

if {
  builtin printf '%s\n%s\n' \
    "Password for 'https://x-access-token@github.test/sample/repo.git':" \
    'PUBLISHER_TEST_WRITE_TOKEN_0000000000000000'
} | (
  exec 3<&0
  exec </dev/null
  "$FAKE_GUARD/publisher-askpass.sh" \
    "Username for 'https://github.test/sample/repo.git':"
) > "$TEST_TMP/askpass-unexpected.out" \
  2> "$TEST_TMP/askpass-unexpected.err"; then
  fail "askpass accepted a username or unexpected prompt"
fi
assert_not_contains 'PUBLISHER_TEST_WRITE_TOKEN_' "$TEST_TMP/askpass-unexpected.out"
assert_not_contains 'PUBLISHER_TEST_WRITE_TOKEN_' "$TEST_TMP/askpass-unexpected.err"

/bin/rm -f \
  "$FAKE_CALL_LOG" "$FAKE_REVOKE_COUNT" "$FAKE_REVOKE_LOG" \
  "$FAKE_PUSH_STATE" "$AUDIT_FILE"
/usr/bin/printf '%s\n' 'FAKE-PRIVATE-KEY-DRIFT' > "$FAKE_KEY"
if "$FAKE_GUARD/publisher.sh" publish_branch \
  --policy "$ACTIVE_POLICY" \
  --request "$ACTIVE_REQUEST" \
  --repo "$REPO" >/dev/null 2>&1; then
  fail "publisher accepted private-key content digest drift"
fi
[ ! -e "$FAKE_CALL_LOG" ] ||
  fail "private-key content digest drift reached a network-capable program"
/usr/bin/printf '%s\n' 'FAKE-PRIVATE-KEY' > "$FAKE_KEY"

FAKE_AUDIT_ORIGINAL=$TEST_TMP/audit-original
/bin/mv "$FAKE_AUDIT" "$FAKE_AUDIT_ORIGINAL"
/bin/mkdir "$FAKE_AUDIT"
/bin/chmod 700 "$FAKE_AUDIT"
if "$FAKE_GUARD/publisher.sh" publish_branch \
  --policy "$ACTIVE_POLICY" \
  --request "$ACTIVE_REQUEST" \
  --repo "$REPO" >/dev/null 2>&1; then
  fail "publisher accepted audit-directory identity drift"
fi
[ ! -e "$FAKE_CALL_LOG" ] ||
  fail "audit-directory identity drift reached a network-capable program"
/bin/rmdir "$FAKE_AUDIT"
/bin/mv "$FAKE_AUDIT_ORIGINAL" "$FAKE_AUDIT"

/bin/chmod 755 "$FAKE_GUARD"
if "$FAKE_GUARD/publisher.sh" publish_branch \
  --policy "$ACTIVE_POLICY" \
  --request "$ACTIVE_REQUEST" \
  --repo "$REPO" >/dev/null 2>&1; then
  fail "publisher accepted a non-private publisher program directory"
fi
[ ! -e "$FAKE_CALL_LOG" ] ||
  fail "publisher program directory mode mismatch reached a network-capable program"
/bin/chmod 700 "$FAKE_GUARD"

/bin/chmod 644 "$FAKE_MANIFEST"
if "$FAKE_GUARD/publisher.sh" publish_branch \
  --policy "$ACTIVE_POLICY" \
  --request "$ACTIVE_REQUEST" \
  --repo "$REPO" >/dev/null 2>&1; then
  fail "publisher accepted a scanner manifest with non-private mode"
fi
[ ! -e "$FAKE_CALL_LOG" ] ||
  fail "scanner manifest mode mismatch reached key or network-capable programs"
/bin/chmod 600 "$FAKE_MANIFEST"

/usr/bin/printf '\n' >> "$FAKE_GUARD/publisher-askpass.sh"
if "$FAKE_GUARD/publisher.sh" publish_branch \
  --policy "$ACTIVE_POLICY" \
  --request "$ACTIVE_REQUEST" \
  --repo "$REPO" >/dev/null 2>&1; then
  fail "publisher accepted a runtime program after its owner seal drifted"
fi
[ ! -e "$FAKE_CALL_LOG" ] ||
  fail "runtime seal drift reached key or network-capable programs"

if /usr/bin/grep -R -E \
  'nightshift-jwt|read-token\.json|write-token\.json' \
  "$ROOT/guard" >/dev/null 2>&1; then
  fail "production publisher still names a JWT or token-response temporary file"
fi
if /usr/bin/find /tmp -maxdepth 1 \
  \( -name 'nightshift-jwt.*' -o -name 'nightshift-publish-body.*' -o -name 'nightshift-revoke-*' \) \
  -print | /usr/bin/grep . >/dev/null 2>&1; then
  fail "publisher left a credential-adjacent temporary file"
fi

printf 'test_guard_publisher: PASS\n'
