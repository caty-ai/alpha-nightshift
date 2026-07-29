#!/bin/bash
set -euo pipefail

evidence_dir_path() {
  printf '%s\n' "$LANE_DIR/evidence"
}

evidence_manifest_path() {
  printf '%s\n' "$(evidence_dir_path)/manifest.json"
}

evidence_prepare_dir() {
  evidence_dir=$(evidence_dir_path)
  case "$evidence_dir" in
    "$LANE_DIR"/evidence) ;;
    *) return 1 ;;
  esac
  [ ! -L "$evidence_dir" ] || return 1
  if [ -e "$evidence_dir" ] && [ ! -d "$evidence_dir" ]; then
    return 1
  fi
  mkdir -p "$evidence_dir"
}

evidence_ref_is_relative() {
  evidence_ref=$1
  case "$evidence_ref" in
    ''|/*|*:*|./*|../*|*/./*|*/../*|*/.|*/..) return 1 ;;
  esac
  return 0
}

evidence_ref_is_manifested() {
  evidence_ref=$1
  evidence_manifest=${2:-"$(evidence_manifest_path)"}
  evidence_ref_is_relative "$evidence_ref" || return 1
  [ -f "$LANE_DIR/$evidence_ref" ] || return 1
  [ ! -L "$LANE_DIR/$evidence_ref" ] || return 1
  jq -e --arg evidence_ref "$evidence_ref" \
    '.files | type == "object" and has($evidence_ref)' \
    "$evidence_manifest" >/dev/null 2>&1
}

evidence_refs_are_manifested() {
  evidence_refs_json=$1
  evidence_manifest=${2:-"$(evidence_manifest_path)"}
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
