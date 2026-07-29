#!/bin/bash
set -euo pipefail

GUARD_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
# shellcheck source=guard/common.sh
. "$GUARD_DIR/common.sh"

broker_main() {
  [ "$#" -ge 1 ] || { guard_fail "missing broker operation"; return 1; }
  broker_operation=$1
  shift
  case "$broker_operation" in
    status|inspect)
      [ "$#" -eq 0 ] || { guard_fail "$broker_operation accepts no fields"; return 1; }
      guard_mode_json
      ;;
    preflight)
      exec "$GUARD_DIR/preflight.sh" "$@"
      ;;
    scan)
      exec "$GUARD_DIR/scan.sh" "$@"
      ;;
    publish|publish_branch|create_draft_pr|create_issue|merge|comment|label|api|graphql)
      guard_fail "broker publication is deliberately hard-disabled"
      ;;
    *)
      guard_fail "broker operation is not in the local grammar"
      ;;
  esac
}

broker_main "$@"
