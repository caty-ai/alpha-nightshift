#!/bin/bash
set -euo pipefail

lock_acquire() {
  lockdir=$1
  if ! mkdir "$lockdir" 2>/dev/null; then
    return 1
  fi

  if ! {
    printf 'pid=%s\n' "$$"
    printf 'started_at=%s\n' "$(nightshift_iso_now)"
  } > "$lockdir/meta"; then
    rmdir "$lockdir" 2>/dev/null || true
    return 1
  fi
}

lock_release() {
  lockdir=$1
  meta_file="$lockdir/meta"
  [ -f "$meta_file" ] || return 1

  owner_pid=$(sed -n 's/^pid=//p' "$meta_file" | sed -n '1p')
  [ "$owner_pid" = "$$" ] || return 1

  rm -f "$meta_file"
  rmdir "$lockdir"
}
