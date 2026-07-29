#!/bin/bash
set -euo pipefail

GUARD_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
# shellcheck source=guard/common.sh
. "$GUARD_DIR/common.sh"

manifest=
if [ "$#" -eq 2 ] && [ "$1" = "--manifest" ]; then
  manifest=$2
else
  guard_fail "preflight accepts only --manifest ABSOLUTE_PATH"
  exit 1
fi

guard_json_no_duplicate_paths "$manifest"
guard_json_exact_keys "$manifest" \
  '["schema","mode","expected_manifest_sha256","tools","programs","policy","night_bot","identities","mounts","matrix","fixture","remote"]'
/usr/bin/jq -e '
  .schema == "alpha-nightshift/guard-activation/v1" and
  .mode == "LOCAL_ONLY_REMOTE_UNPROVEN" and
  (.tools | type == "object") and
  (.programs | type == "object") and
  (.policy | type == "object") and
  (.identities | type == "array") and
  (.mounts | type == "array") and
  (.matrix | type == "array") and
  (.fixture | type == "object") and
  (.remote | type == "object")
' "$manifest" >/dev/null ||
  { guard_fail "activation manifest schema is invalid"; exit 1; }

preflight_tmp=$(mktemp -d "${TMPDIR:-/tmp}/nightshift-preflight.XXXXXX")
preflight_tmp=$(CDPATH= cd -- "$preflight_tmp" && pwd -P)
cleanup() {
  rm -rf "$preflight_tmp"
}
trap cleanup EXIT
cells=$preflight_tmp/cells.jsonl
: > "$cells"

emit_cell() {
  cell_category=$1
  cell_name=$2
  cell_status=$3
  cell_reason=$4
  /usr/bin/jq -cn \
    --arg category "$cell_category" \
    --arg name "$cell_name" \
    --arg status "$cell_status" \
    --arg reason "$cell_reason" \
    '{category:$category,name:$name,status:$status,reason:$reason}' >> "$cells"
}

expected_tool_names='["file","git","gitleaks","jq","sandbox_exec","shell"]'
if ! /usr/bin/jq -e --argjson names "$expected_tool_names" \
  '(.tools | keys | sort) == ($names | sort)' "$manifest" >/dev/null; then
  emit_cell tools tool_set UNPROVEN "tool set is missing or contains unknown entries"
fi

gitleaks_tool_proven=false
sandbox_exec_tool_proven=false
for tool_name in file git gitleaks jq sandbox_exec shell; do
  tool_path=$(/usr/bin/jq -r --arg name "$tool_name" '.tools[$name].path // ""' "$manifest")
  tool_digest=$(/usr/bin/jq -r --arg name "$tool_name" '.tools[$name].sha256 // ""' "$manifest")
  tool_uid=$(/usr/bin/jq -r --arg name "$tool_name" '.tools[$name].uid // ""' "$manifest")
  tool_mode=$(/usr/bin/jq -r --arg name "$tool_name" '.tools[$name].mode // ""' "$manifest")
  if ! guard_validate_absolute_path "$tool_path" executable >/dev/null 2>&1; then
    emit_cell tools "$tool_name" UNPROVEN "absolute executable path is unavailable or aliased"
    continue
  fi
  actual_digest=$(guard_sha256 "$tool_path")
  actual_uid=$(/usr/bin/stat -f '%u' "$tool_path" 2>/dev/null || :)
  actual_mode=$(/usr/bin/stat -f '%Lp' "$tool_path" 2>/dev/null || :)
  case "$tool_name" in
    file) policy_tool_path=/usr/bin/file ;;
    git) policy_tool_path=/opt/homebrew/Cellar/git/2.48.1/bin/git ;;
    gitleaks) policy_tool_path=/opt/homebrew/Cellar/gitleaks/8.30.1/bin/gitleaks ;;
    jq) policy_tool_path=/usr/bin/jq ;;
    sandbox_exec) policy_tool_path=/usr/bin/sandbox-exec ;;
    shell) policy_tool_path=/bin/bash ;;
    *) policy_tool_path= ;;
  esac
  if [ -z "$tool_digest" ] || [ -z "$tool_uid" ] || [ -z "$tool_mode" ]; then
    emit_cell tools "$tool_name" UNPROVEN "digest, owner, or mode expectation is absent"
  elif [ -z "$policy_tool_path" ] || [ "$tool_path" != "$policy_tool_path" ]; then
    emit_cell tools "$tool_name" UNPROVEN "manifest path does not equal the policy-owned executable"
  elif [ "$actual_digest" != "$tool_digest" ] ||
    [ "$actual_uid" != "$tool_uid" ] ||
    [ "$actual_mode" != "$tool_mode" ]; then
    emit_cell tools "$tool_name" UNPROVEN "digest, owner, or mode mismatch"
  else
    emit_cell tools "$tool_name" PROVEN "absolute path, digest, owner, and mode match"
    case "$tool_name" in
      gitleaks) gitleaks_tool_proven=true ;;
      sandbox_exec) sandbox_exec_tool_proven=true ;;
    esac
  fi
done

if [ "$gitleaks_tool_proven" = true ] &&
  [ "$(/usr/bin/env -i \
    HOME=/var/empty \
    LANG=C \
    LC_ALL=C \
    PATH=/usr/bin:/bin \
    /opt/homebrew/Cellar/gitleaks/8.30.1/bin/gitleaks version 2>/dev/null)" = "8.30.1" ]; then
  emit_cell scanner gitleaks_version PROVEN "exact version 8.30.1"
else
  emit_cell scanner gitleaks_version UNPROVEN \
    "policy-owned gitleaks provenance or exact version 8.30.1 is unproven"
fi

expected_program_names='["broker","gateway","preflight","renderer","scanner"]'
if ! /usr/bin/jq -e --argjson names "$expected_program_names" \
  '(.programs | keys | sort) == ($names | sort)' "$manifest" >/dev/null; then
  emit_cell programs program_set UNPROVEN "guard program set is incomplete"
fi
renderer_program_proven=false
scanner_program_proven=false
for program_name in broker gateway preflight renderer scanner; do
  program_path=$(/usr/bin/jq -r --arg name "$program_name" '.programs[$name].path // ""' "$manifest")
  program_digest=$(/usr/bin/jq -r --arg name "$program_name" '.programs[$name].sha256 // ""' "$manifest")
  program_uid=$(/usr/bin/jq -r --arg name "$program_name" '.programs[$name].uid // ""' "$manifest")
  program_mode=$(/usr/bin/jq -r --arg name "$program_name" '.programs[$name].mode // ""' "$manifest")
  if ! guard_validate_absolute_path "$program_path" executable >/dev/null 2>&1; then
    emit_cell programs "$program_name" UNPROVEN "guard program path is unavailable or aliased"
    continue
  fi
  actual_digest=$(guard_sha256 "$program_path")
  actual_uid=$(/usr/bin/stat -f '%u' "$program_path" 2>/dev/null || :)
  actual_mode=$(/usr/bin/stat -f '%Lp' "$program_path" 2>/dev/null || :)
  case "$program_name" in
    broker) policy_program_path=$GUARD_DIR/broker.sh ;;
    gateway) policy_program_path=$GUARD_DIR/gateway.sh ;;
    preflight) policy_program_path=$GUARD_DIR/preflight.sh ;;
    renderer) policy_program_path=$GUARD_DIR/render-sandbox.sh ;;
    scanner) policy_program_path=$GUARD_DIR/scan.sh ;;
    *) policy_program_path= ;;
  esac
  if [ -z "$policy_program_path" ] ||
    [ "$program_path" != "$policy_program_path" ]; then
    emit_cell programs "$program_name" UNPROVEN \
      "manifest path does not equal the policy-owned guard program"
  elif [ -n "$program_digest" ] && [ -n "$program_uid" ] && [ -n "$program_mode" ] &&
    [ "$actual_digest" = "$program_digest" ] &&
    [ "$actual_uid" = "$program_uid" ] &&
    [ "$actual_mode" = "$program_mode" ]; then
    emit_cell programs "$program_name" PROVEN "digest, owner, and mode match"
    case "$program_name" in
      renderer) renderer_program_proven=true ;;
      scanner) scanner_program_proven=true ;;
    esac
  else
    emit_cell programs "$program_name" UNPROVEN "digest, owner, or mode is absent or mismatched"
  fi
done

sandbox_runtime_status=UNPROVEN
sandbox_runtime_reason="policy-owned sandbox-exec or renderer provenance is unproven"
if [ "$sandbox_exec_tool_proven" = true ] &&
  [ "$renderer_program_proven" = true ]; then
  sandbox_probe_workspace=$preflight_tmp/sandbox-workspace
  sandbox_probe_state=$preflight_tmp/sandbox-state
  sandbox_probe_profile=$preflight_tmp/sandbox-profile.sb
  if /bin/mkdir -p "$sandbox_probe_workspace" "$sandbox_probe_state" &&
    /usr/bin/env -i \
      HOME=/var/empty \
      LANG=C \
      LC_ALL=C \
      PATH=/usr/bin:/bin \
      /bin/bash "$GUARD_DIR/render-sandbox.sh" \
        --workspace "$sandbox_probe_workspace" \
        --state "$sandbox_probe_state" \
        > "$sandbox_probe_profile" 2>/dev/null &&
    /usr/bin/env -i \
      HOME=/var/empty \
      LANG=C \
      LC_ALL=C \
      PATH=/usr/bin:/bin \
      /usr/bin/sandbox-exec \
        -f "$sandbox_probe_profile" \
        /usr/bin/true >/dev/null 2>&1; then
    sandbox_runtime_status=PROVEN
    sandbox_runtime_reason="proven fixed Phase 1a profile rendered and executed locally"
  else
    sandbox_runtime_status=UNSUPPORTED
    sandbox_runtime_reason="proven fixed Phase 1a profile cannot render or execute in this runtime"
  fi
fi
emit_cell sandbox sandbox_runtime_capability \
  "$sandbox_runtime_status" "$sandbox_runtime_reason"

manifest_digest=$(guard_sha256 "$manifest")
manifest_seal_digest=$(
  /usr/bin/jq -cS 'del(.expected_manifest_sha256)' "$manifest" |
    /usr/bin/shasum -a 256 |
    /usr/bin/awk '{print $1}'
)
expected_manifest_digest=$(/usr/bin/jq -r '.expected_manifest_sha256 // ""' "$manifest")
if [ -n "$expected_manifest_digest" ] &&
  [ "$manifest_seal_digest" = "$expected_manifest_digest" ]; then
  emit_cell policy activation_manifest_digest PROVEN "canonical manifest payload matches owner seal"
else
  emit_cell policy activation_manifest_digest UNPROVEN "owner-sealed manifest digest is absent or mismatched"
fi

sandbox_digest=$(guard_sha256 "$GUARD_DIR/sandbox.sb")
expected_sandbox_digest=$(/usr/bin/jq -r '.policy.sandbox_template_sha256 // ""' "$manifest")
if [ -n "$expected_sandbox_digest" ] &&
  [ "$expected_sandbox_digest" = "$sandbox_digest" ]; then
  emit_cell policy sandbox_template_digest PROVEN "sandbox template digest matches"
else
  emit_cell policy sandbox_template_digest UNPROVEN "sandbox template digest is absent or mismatched"
fi
scanner_policy_digest=
if [ "$scanner_program_proven" = true ]; then
  scanner_policy_digest=$(
    /usr/bin/env -i \
      HOME=/var/empty \
      LANG=C \
      LC_ALL=C \
      PATH=/usr/bin:/bin \
      /bin/bash "$GUARD_DIR/scan.sh" --policy-digest 2>/dev/null ||
      :
  )
fi
expected_scanner_digest=$(/usr/bin/jq -r '.policy.scanner_config_sha256 // ""' "$manifest")
if [ -n "$scanner_policy_digest" ] &&
  [ -n "$expected_scanner_digest" ] &&
  [ "$expected_scanner_digest" = "$scanner_policy_digest" ]; then
  emit_cell policy scanner_config_digest PROVEN "expanded path-independent scanner policy matches"
else
  emit_cell policy scanner_config_digest UNPROVEN "scanner policy digest is absent or mismatched"
fi
test_contract_digest=$(/usr/bin/jq -r '.policy.test_contract_sha256 // ""' "$manifest")
if [ -n "$test_contract_digest" ]; then
  emit_cell policy test_contract_digest UNPROVEN "Phase 1a has no owner-sealed external test contract"
else
  emit_cell policy test_contract_digest UNPROVEN "test contract digest is absent"
fi

required_identities='night-broker night-lane night-verify night-import night-attest night-publish'
seen_uids=
for identity_name in $required_identities; do
  declared_uid=$(/usr/bin/jq -r --arg name "$identity_name" \
    '.identities[]? | select(.name == $name) | .uid // empty' "$manifest" | /usr/bin/head -1)
  actual_uid=$(/usr/bin/id -u "$identity_name" 2>/dev/null || :)
  identity_count=$(/usr/bin/jq -r --arg name "$identity_name" \
    '[.identities[]? | select(.name == $name)] | length' "$manifest")
  if [ "$identity_count" -ne 1 ] || [ -z "$declared_uid" ] || [ -z "$actual_uid" ] ||
    [ "$declared_uid" != "$actual_uid" ]; then
    emit_cell identities "$identity_name" UNPROVEN "distinct declared system UID is absent or mismatched"
  else
    case " $seen_uids " in
      *" $actual_uid "*) emit_cell identities "$identity_name" UNPROVEN "UID is not distinct" ;;
      *)
        emit_cell identities "$identity_name" PROVEN "declared UID exists and is distinct"
        seen_uids="$seen_uids $actual_uid"
        ;;
    esac
  fi
done

mount_count=$(/usr/bin/jq '.mounts | length' "$manifest")
if [ "$mount_count" -eq 0 ]; then
  emit_cell filesystem per_mount_semantics UNPROVEN "no per-mount case, Unicode, link, and alias measurements"
else
  /usr/bin/jq -c '.mounts[]' "$manifest" |
    while IFS= read -r mount_cell; do
      mount_name=$(/usr/bin/printf '%s' "$mount_cell" | /usr/bin/jq -r '.name // "invalid"')
      mount_status=$(/usr/bin/printf '%s' "$mount_cell" | /usr/bin/jq -r '.status // "UNPROVEN"')
      case "$mount_status" in
        PROVEN) emit_cell filesystem "$mount_name" UNPROVEN "declared measurement lacks a Phase 1a active probe" ;;
        UNSUPPORTED) emit_cell filesystem "$mount_name" UNPROVEN "declared unsupported state lacks a Phase 1a active probe" ;;
        *) emit_cell filesystem "$mount_name" UNPROVEN "filesystem semantics unproven" ;;
      esac
    done
fi

matrix_count=$(/usr/bin/jq '.matrix | length' "$manifest")
if [ "$matrix_count" -eq 0 ]; then
  emit_cell isolation complete_matrix UNPROVEN "identity/path/process/Mach/sysctl/keychain/descriptor matrix is absent"
else
  /usr/bin/jq -c '.matrix[]' "$manifest" |
    while IFS= read -r matrix_cell; do
      matrix_name=$(/usr/bin/printf '%s' "$matrix_cell" |
        /usr/bin/jq -r '[.subject // "?",.target // "?",.operation // "?"] | join(":")')
      matrix_status=$(/usr/bin/printf '%s' "$matrix_cell" | /usr/bin/jq -r '.status // "UNPROVEN"')
      case "$matrix_status" in
        UNSUPPORTED) emit_cell isolation "$matrix_name" UNPROVEN "declared unsupported state lacks a Phase 1a active probe" ;;
        *) emit_cell isolation "$matrix_name" UNPROVEN "Phase 1a does not accept declaration as an active proof" ;;
      esac
    done
fi

for fixture_cell in exact_port_proof second_port_denial direct_network_denial; do
  if [ "$sandbox_runtime_status" = UNSUPPORTED ]; then
    emit_cell sandbox "$fixture_cell" UNSUPPORTED "sandbox runtime cannot execute the fixture probe"
  else
    emit_cell sandbox "$fixture_cell" UNPROVEN \
      "declared fixture status is not a measured local proof"
  fi
done
emit_cell sandbox process_mach_sysctl_keychain_descriptor UNSUPPORTED \
  "sandbox-exec alone cannot prove the complete required isolation matrix"

for remote_cell in private_repository supporting_plan_or_host night_bot_account fine_grained_pat owner_authorized_phase1b_proofs protection_readback negative_write_proofs; do
  emit_cell remote "$remote_cell" UNPROVEN "Phase 1b remote prerequisite is unavailable"
done

/usr/bin/jq -s \
  --arg mode "$GUARD_MODE" \
  --arg manifest_sha256 "$manifest_digest" \
  --arg scanner_policy_sha256 "$scanner_policy_digest" \
  --arg sandbox_template_sha256 "$sandbox_digest" '
  sort_by(.category,.name) as $cells |
  {
    schema:"alpha-nightshift/guard-preflight/v1",
    mode:$mode,
    write_mode:false,
    verdict:"DENY",
    manifest_sha256:$manifest_sha256,
    scanner_policy_sha256:$scanner_policy_sha256,
    sandbox_template_sha256:$sandbox_template_sha256,
    cells:$cells,
    counts:{
      proven:([$cells[] | select(.status == "PROVEN")] | length),
      unproven:([$cells[] | select(.status == "UNPROVEN")] | length),
      unsupported:([$cells[] | select(.status == "UNSUPPORTED")] | length)
    }
  }' "$cells"
