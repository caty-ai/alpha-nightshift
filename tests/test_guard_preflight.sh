#!/bin/bash
set -euo pipefail

TEST_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
ROOT=$(CDPATH= cd -- "$TEST_DIR/.." && pwd -P)
. "$TEST_DIR/helpers.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-preflight-test.XXXXXX")
cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT
TEST_TMP=$(CDPATH= cd -- "$TEST_TMP" && pwd -P)

"$ROOT/guard/preflight.sh" \
  --manifest "$ROOT/config/guard-activation.example.json" > "$TEST_TMP/report.json"
/usr/bin/jq -e '
  .mode == "LOCAL_ONLY_REMOTE_UNPROVEN" and
  .write_mode == false and
  .verdict == "DENY" and
  .counts.unproven > 0 and
  .counts.unsupported > 0 and
  ([.cells[] | select(.category == "remote" and .status == "UNPROVEN")] | length) == 7 and
  any(.cells[]; .name == "complete_matrix" and .status == "UNPROVEN") and
  any(.cells[]; .name == "test_contract_digest" and .status == "UNPROVEN") and
  any(.cells[]; .name == "process_mach_sysctl_keychain_descriptor" and .status == "UNSUPPORTED")
' "$TEST_TMP/report.json" >/dev/null ||
  fail "preflight did not report mandatory hard-disable cells"

for identity in night-broker night-lane night-verify night-import night-attest night-publish; do
  /usr/bin/jq -e --arg identity "$identity" \
    'any(.cells[]; .category == "identities" and .name == $identity and .status != "PROVEN")' \
    "$TEST_TMP/report.json" >/dev/null ||
    fail "missing identity was not fail-closed: $identity"
done

/usr/bin/jq '.tools.gitleaks.sha256="bad"' \
  "$ROOT/config/guard-activation.example.json" > "$TEST_TMP/mismatch.json"
"$ROOT/guard/preflight.sh" --manifest "$TEST_TMP/mismatch.json" > "$TEST_TMP/mismatch-report.json"
/usr/bin/jq -e '
  .write_mode == false and
  any(.cells[]; .name == "gitleaks" and .status == "UNPROVEN")
' "$TEST_TMP/mismatch-report.json" >/dev/null ||
  fail "scanner digest mismatch was downgraded"

false_digest=$(/usr/bin/shasum -a 256 /usr/bin/false | /usr/bin/awk '{print $1}')
false_uid=$(/usr/bin/stat -f '%u' /usr/bin/false)
false_mode=$(/usr/bin/stat -f '%Lp' /usr/bin/false)
/usr/bin/jq \
  --arg digest "$false_digest" \
  --arg uid "$false_uid" \
  --arg mode "$false_mode" '
  .tools.gitleaks={
    path:"/usr/bin/false",
    sha256:$digest,
    uid:($uid|tonumber),
    mode:$mode
  }
' "$ROOT/config/guard-activation.example.json" > "$TEST_TMP/version.json"
"$ROOT/guard/preflight.sh" --manifest "$TEST_TMP/version.json" > "$TEST_TMP/version-report.json"
/usr/bin/jq -e '
  .write_mode == false and
  any(.cells[]; .name == "gitleaks_version" and .status == "UNPROVEN")
' "$TEST_TMP/version-report.json" >/dev/null ||
  fail "gitleaks version mismatch was not fail-closed"

# Round 3: every tool and guard program has a total policy-owned path mapping.
for policy_category in tools programs; do
  case "$policy_category" in
    tools) policy_names='file git gitleaks jq sandbox_exec shell' ;;
    programs) policy_names='broker gateway preflight renderer scanner' ;;
  esac
  for policy_name in $policy_names; do
    evil_marker=$TEST_TMP/marker-"$policy_category"-"$policy_name"
    evil_binary=$TEST_TMP/evil-"$policy_category"-"$policy_name"
    /usr/bin/printf '%s\n' \
      '#!/bin/bash' \
      "/usr/bin/touch \"$evil_marker\"" \
      '/usr/bin/printf "%s\n" 8.30.1' > "$evil_binary"
    chmod 755 "$evil_binary"
    evil_digest=$(/usr/bin/shasum -a 256 "$evil_binary" | /usr/bin/awk '{print $1}')
    evil_uid=$(/usr/bin/stat -f '%u' "$evil_binary")
    evil_mode=$(/usr/bin/stat -f '%Lp' "$evil_binary")
    /usr/bin/jq \
      --arg category "$policy_category" \
      --arg name "$policy_name" \
      --arg path "$evil_binary" \
      --arg digest "$evil_digest" \
      --arg uid "$evil_uid" \
      --arg mode "$evil_mode" '
      .[$category][$name]={
        path:$path,
        sha256:$digest,
        uid:($uid|tonumber),
        mode:$mode
      }
    ' "$ROOT/config/guard-activation.example.json" \
      > "$TEST_TMP/evil-$policy_category-$policy_name.json"
    "$ROOT/guard/preflight.sh" \
      --manifest "$TEST_TMP/evil-$policy_category-$policy_name.json" \
      > "$TEST_TMP/evil-$policy_category-$policy_name-report.json"
    [ ! -e "$evil_marker" ] ||
      fail "preflight executed manifest-selected $policy_category.$policy_name"
    /usr/bin/jq -e \
      --arg category "$policy_category" \
      --arg name "$policy_name" '
      .write_mode == false and
      ([.cells[] | select(.category == $category and .name == $name)] | length) == 1 and
      any(.cells[]; .category == $category and .name == $name and .status == "UNPROVEN")
    ' "$TEST_TMP/evil-$policy_category-$policy_name-report.json" >/dev/null ||
      fail "substituted $policy_category.$policy_name path became proven"
  done
done

fixed_digest=$(/usr/bin/shasum -a 256 /opt/homebrew/Cellar/gitleaks/8.30.1/bin/gitleaks | /usr/bin/awk '{print $1}')
fixed_uid=$(/usr/bin/stat -f '%u' /opt/homebrew/Cellar/gitleaks/8.30.1/bin/gitleaks)
fixed_mode=$(/usr/bin/stat -f '%Lp' /opt/homebrew/Cellar/gitleaks/8.30.1/bin/gitleaks)
/usr/bin/jq \
  --arg digest "$fixed_digest" \
  --arg uid "$fixed_uid" \
  --arg mode "$fixed_mode" '
  .tools.gitleaks.sha256=$digest |
  .tools.gitleaks.uid=($uid|tonumber) |
  .tools.gitleaks.mode=$mode
' "$ROOT/config/guard-activation.example.json" > "$TEST_TMP/fixed-gitleaks.json"
"$ROOT/guard/preflight.sh" \
  --manifest "$TEST_TMP/fixed-gitleaks.json" > "$TEST_TMP/fixed-gitleaks-report.json"
/usr/bin/jq -e '
  .write_mode == false and
  any(.cells[]; .category == "tools" and .name == "gitleaks" and .status == "PROVEN") and
  any(.cells[]; .category == "scanner" and .name == "gitleaks_version" and .status == "PROVEN")
' "$TEST_TMP/fixed-gitleaks-report.json" >/dev/null ||
  fail "fixed provenance-checked gitleaks probe was not reported accurately"

/usr/bin/jq '
  .mounts=[
    {"name":"seal","status":"PROVEN"},
    {"name":"declared-unsupported","status":"UNSUPPORTED"}
  ] |
  .matrix=[
    {"subject":"night-attest","target":"seal","operation":"write","status":"PROVEN"},
    {"subject":"night-lane","target":"mach","operation":"lookup","status":"UNSUPPORTED"}
  ] |
  .fixture.exact_port_proof="UNSUPPORTED" |
  .fixture.second_port_denial="UNSUPPORTED" |
  .fixture.direct_network_denial="UNSUPPORTED"
' "$ROOT/config/guard-activation.example.json" > "$TEST_TMP/declaration-only.json"
"$ROOT/guard/preflight.sh" \
  --manifest "$TEST_TMP/declaration-only.json" > "$TEST_TMP/declaration-report.json"
/usr/bin/jq -e '
  .write_mode == false and
  any(.cells[]; .category == "filesystem" and .name == "seal" and .status == "UNPROVEN") and
  any(.cells[]; .category == "filesystem" and .name == "declared-unsupported" and .status == "UNPROVEN") and
  any(.cells[]; .category == "isolation" and .name == "night-attest:seal:write" and .status == "UNPROVEN") and
  any(.cells[]; .category == "isolation" and .name == "night-lane:mach:lookup" and .status == "UNPROVEN") and
  ([.cells[] | select(.category == "sandbox" and
    (.name == "exact_port_proof" or .name == "second_port_denial" or .name == "direct_network_denial"))] |
    length == 3 and all(.status == "UNPROVEN"))
' "$TEST_TMP/declaration-report.json" >/dev/null ||
  fail "declaration-only proof or unsupported state was accepted as measured"

/usr/bin/printf '%s\n' \
  '{"schema":"alpha-nightshift/guard-activation/v1","schema":"duplicate"}' \
  > "$TEST_TMP/duplicate.json"
if "$ROOT/guard/preflight.sh" --manifest "$TEST_TMP/duplicate.json" >/dev/null 2>&1; then
  fail "duplicate activation JSON was accepted"
fi

printf 'test_guard_preflight: PASS\n'
