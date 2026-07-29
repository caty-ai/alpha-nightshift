#!/bin/bash
set -euo pipefail

evidence_dir_path() {
  printf '%s\n' "$LANE_DIR/evidence"
}

evidence_manifest_path() {
  printf '%s\n' "$(evidence_dir_path)/manifest.json"
}

evidence_prepare_dir() {
  local evidence_dir
  evidence_dir=$(evidence_dir_path)
  case "$evidence_dir" in
    "$LANE_DIR"/evidence) ;;
    *)
      printf '%s\n' "evidence: refusing unsafe evidence directory: $evidence_dir" >&2
      return 1
      ;;
  esac
  if [ -L "$evidence_dir" ]; then
    printf '%s\n' "evidence: refusing unsafe symlink evidence directory: $evidence_dir" >&2
    return 1
  fi
  if [ -e "$evidence_dir" ] && [ ! -d "$evidence_dir" ]; then
    printf '%s\n' "evidence: refusing non-directory evidence path: $evidence_dir" >&2
    return 1
  fi
  mkdir -p "$evidence_dir"
}

evidence_ref_is_relative() {
  local evidence_ref=$1
  case "$evidence_ref" in
    ''|/*|*:*|*[!A-Za-z0-9._/-]*|./*|../*|*/./*|*/../*|*/.|*/..) return 1 ;;
  esac
  return 0
}

evidence_ref_is_manifested() {
  local evidence_ref=$1
  local evidence_manifest=${2:-"$(evidence_manifest_path)"}
  evidence_ref_is_relative "$evidence_ref" || return 1
  [ -f "$LANE_DIR/$evidence_ref" ] || return 1
  [ ! -L "$LANE_DIR/$evidence_ref" ] || return 1
  jq -e --arg evidence_ref "$evidence_ref" \
    '.files | type == "object" and has($evidence_ref)' \
    "$evidence_manifest" >/dev/null 2>&1
}

evidence_refs_are_manifested() {
  local evidence_refs_json=$1
  local evidence_manifest=${2:-"$(evidence_manifest_path)"}
  local evidence_ref
  [ -f "$evidence_manifest" ] || return 1
  printf '%s\n' "$evidence_refs_json" |
    jq -e '
      type == "array" and
      length > 0 and
      all(.[]; type == "string" and length > 0)
    ' >/dev/null 2>&1 || return 1

  while IFS= read -r evidence_ref; do
    evidence_ref_is_manifested "$evidence_ref" "$evidence_manifest" || return 1
  done <<EOF
$(printf '%s\n' "$evidence_refs_json" | jq -r '.[]')
EOF
}

evidence_capture_file_set() {
  local evidence_dir
  local captured_path
  local paths_tmp
  local names_tmp
  evidence_dir=$(evidence_dir_path)
  [ -d "$evidence_dir" ] || return 1
  paths_tmp=$(mktemp "${TMPDIR:-/tmp}/metsuke-evidence-paths.XXXXXX")
  names_tmp=$(mktemp "${TMPDIR:-/tmp}/metsuke-evidence-names.XXXXXX")
  find "$evidence_dir" -mindepth 1 -maxdepth 1 -print > "$paths_tmp"
  : > "$names_tmp"
  while IFS= read -r captured_path; do
    if [ ! -f "$captured_path" ] || [ -L "$captured_path" ]; then
      rm -f "$paths_tmp" "$names_tmp"
      return 1
    fi
    basename "$captured_path" >> "$names_tmp"
  done < "$paths_tmp"
  LC_ALL=C sort "$names_tmp"
  rm -f "$paths_tmp" "$names_tmp"
}

evidence_freeze_capture() {
  local trust_dir=$1
  local live_manifest
  local frozen_manifest
  local digests_tmp
  local evidence_ref
  local evidence_sha
  local expected_set_tmp
  local actual_set_tmp

  live_manifest=$(evidence_manifest_path)
  frozen_manifest="$trust_dir/manifest.json"
  [ -f "$live_manifest" ] && [ ! -L "$live_manifest" ] || return 1
  jq -e '
    type == "object" and
    (.files | type == "object") and
    (.steps | type == "array")
  ' "$live_manifest" >/dev/null 2>&1 || return 1

  if [ -L "$trust_dir" ] || { [ -e "$trust_dir" ] && [ ! -d "$trust_dir" ]; }; then
    printf '%s\n' "evidence: refusing unsafe capture trust directory: $trust_dir" >&2
    return 1
  fi
  mkdir -p "$trust_dir"
  rm -f \
    "$frozen_manifest" \
    "$trust_dir/manifest.sha256" \
    "$trust_dir/digests.json" \
    "$trust_dir/file-set.txt"

  cp "$live_manifest" "$frozen_manifest"
  shasum -a 256 "$frozen_manifest" | awk '{print $1}' > "$trust_dir/manifest.sha256"
  digests_tmp="$trust_dir/.digests.$$.jsonl"
  expected_set_tmp="$trust_dir/.expected-set.$$.txt"
  actual_set_tmp="$trust_dir/.actual-set.$$.txt"
  : > "$digests_tmp"
  : > "$expected_set_tmp"
  printf '%s\n' "manifest.json" >> "$expected_set_tmp"

  while IFS= read -r evidence_ref; do
    case "$evidence_ref" in
      evidence/*/*|evidence/)
        rm -f "$digests_tmp" "$expected_set_tmp" "$actual_set_tmp"
        return 1
        ;;
      evidence/*) ;;
      *)
        rm -f "$digests_tmp" "$expected_set_tmp" "$actual_set_tmp"
        return 1
        ;;
    esac
    evidence_ref_is_manifested "$evidence_ref" "$frozen_manifest" || {
      rm -f "$digests_tmp" "$expected_set_tmp" "$actual_set_tmp"
      return 1
    }
    evidence_sha=$(shasum -a 256 "$LANE_DIR/$evidence_ref" | awk '{print $1}')
    jq -n -c \
      --arg key "$evidence_ref" \
      --arg value "$evidence_sha" \
      '{key: $key, value: $value}' >> "$digests_tmp"
    basename "$evidence_ref" >> "$expected_set_tmp"
  done <<EOF
$(jq -r '.files | keys[]' "$frozen_manifest")
EOF

  jq -s 'from_entries' "$digests_tmp" > "$trust_dir/digests.json"
  LC_ALL=C sort -u "$expected_set_tmp" > "$trust_dir/file-set.txt"
  evidence_capture_file_set > "$actual_set_tmp" || {
    rm -f "$digests_tmp" "$expected_set_tmp" "$actual_set_tmp"
    return 1
  }
  if ! cmp -s "$trust_dir/file-set.txt" "$actual_set_tmp"; then
    printf '%s\n' "evidence: capture file set does not match the manifest" >&2
    rm -f "$digests_tmp" "$expected_set_tmp" "$actual_set_tmp"
    return 1
  fi
  rm -f "$digests_tmp" "$expected_set_tmp" "$actual_set_tmp"
}

evidence_ref_digest_matches() {
  local evidence_ref=$1
  local digest_file=$2
  local expected_sha
  local actual_sha
  evidence_ref_is_relative "$evidence_ref" || return 1
  expected_sha=$(jq -e -r --arg evidence_ref "$evidence_ref" \
    '.[$evidence_ref] | select(type == "string")' "$digest_file" 2>/dev/null) ||
    return 1
  [ -f "$LANE_DIR/$evidence_ref" ] && [ ! -L "$LANE_DIR/$evidence_ref" ] ||
    return 1
  actual_sha=$(shasum -a 256 "$LANE_DIR/$evidence_ref" | awk '{print $1}')
  [ "$actual_sha" = "$expected_sha" ]
}

evidence_verify_frozen_capture() {
  local trust_dir=$1
  local frozen_manifest="$trust_dir/manifest.json"
  local expected_manifest_sha
  local actual_manifest_sha
  local evidence_ref
  local actual_set_tmp="$trust_dir/.verify-set.$$.txt"

  [ -f "$frozen_manifest" ] &&
    [ -f "$trust_dir/manifest.sha256" ] &&
    [ -f "$trust_dir/digests.json" ] &&
    [ -f "$trust_dir/file-set.txt" ] || return 1
  expected_manifest_sha=$(sed -n '1p' "$trust_dir/manifest.sha256")
  actual_manifest_sha=$(shasum -a 256 "$frozen_manifest" | awk '{print $1}')
  [ "$actual_manifest_sha" = "$expected_manifest_sha" ] || return 1
  actual_manifest_sha=$(shasum -a 256 "$(evidence_manifest_path)" | awk '{print $1}')
  [ "$actual_manifest_sha" = "$expected_manifest_sha" ] || return 1

  evidence_capture_file_set > "$actual_set_tmp" || {
    rm -f "$actual_set_tmp"
    return 1
  }
  if ! cmp -s "$trust_dir/file-set.txt" "$actual_set_tmp"; then
    rm -f "$actual_set_tmp"
    return 1
  fi
  rm -f "$actual_set_tmp"

  while IFS= read -r evidence_ref; do
    evidence_ref_digest_matches "$evidence_ref" "$trust_dir/digests.json" ||
      return 1
  done <<EOF
$(jq -r 'keys[]' "$trust_dir/digests.json")
EOF
}

evidence_target_exists() {
  local target=$1
  local frozen_manifest=$2
  local flow
  local step
  case "$target" in
    */*)
      flow=${target%%/*}
      step=${target#*/}
      ;;
    *) return 1 ;;
  esac
  [ -n "$flow" ] && [ -n "$step" ] && [ "$step" = "${step##*/}" ] || return 1
  jq -e \
    --arg flow "$flow" \
    --arg step "$step" \
    '.steps | type == "array" and any(.[]; .flow == $flow and .step == $step)' \
    "$frozen_manifest" >/dev/null 2>&1
}

evidence_refs_match_target() {
  local evidence_refs_json=$1
  local target=$2
  local frozen_manifest=$3
  local digest_file=$4
  local flow=${target%%/*}
  local step=${target#*/}
  local evidence_ref

  evidence_target_exists "$target" "$frozen_manifest" || return 1
  printf '%s\n' "$evidence_refs_json" |
    jq -e '
      type == "array" and
      length > 0 and
      all(.[]; type == "string" and length > 0)
    ' >/dev/null 2>&1 || return 1

  while IFS= read -r evidence_ref; do
    evidence_ref_digest_matches "$evidence_ref" "$digest_file" || return 1
    jq -e \
      --arg evidence_ref "$evidence_ref" \
      --arg flow "$flow" \
      --arg step "$step" '
        .files[$evidence_ref] as $mapping |
        ($mapping | type == "object") and
        (
          if $mapping.type == "console-errors" then
            $mapping.type == "console-errors" and
            ($mapping.mappings | type == "array") and
            any($mapping.mappings[]; .flow == $flow and .step == $step)
          else
            $mapping.flow == $flow and $mapping.step == $step
          end
        )
      ' "$frozen_manifest" >/dev/null 2>&1 || return 1
  done <<EOF
$(printf '%s\n' "$evidence_refs_json" | jq -r '.[]')
EOF
}
