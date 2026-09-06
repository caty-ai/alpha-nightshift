#!/bin/bash
set -euo pipefail

error() {
  reason=$1
  shift
  [[ "$reason" =~ ^[a-z0-9-]+$ ]] || reason=unexpected-error
  printf 'health: %s\n' "$*" >&2
  exit 1
}

[ -n "${LANE_DIR:-}" ] || error lane-dir-required 'LANE_DIR is required'
night_id=${NIGHT_ID:-}
started=$(date +%s)
repo=
source=
commit=
selection=explicit
refresh=
runner=
result=error
reason=unexpected-error
suites=0
failures=0
commands='[]'
active_pid=
active_known=

# Keep evidence available for all exits after the lane directory is known.
# shellcheck disable=SC2317,SC2329 # Invoked by the EXIT trap (SC2317 on older shellcheck).
finish() {
  finish_rc=$?
  trap - EXIT
  if [ -n "$active_pid" ]; then
    stop_remaining_tree "$active_pid" "$active_known"
    wait "$active_pid" 2>/dev/null || true
  fi
  manifest='{}'
  for log_file in "$LANE_DIR"/evidence/*.log; do
    [ -f "$log_file" ] || continue
    ref="evidence/$(basename "$log_file")"
    sha=$(shasum -a 256 "$log_file" | awk '{print $1}') || exit 1
    bytes=$(wc -c < "$log_file" | tr -d '[:space:]')
    manifest=$(printf '%s\n' "$manifest" | jq -c --arg ref "$ref" \
      --arg sha "$sha" --argjson bytes "$bytes" \
      '. + {($ref):{sha256:$sha,bytes:$bytes}}') || exit 1
  done
  if ! printf '%s\n' "$manifest" | jq '{files:.}' > "$LANE_DIR/evidence/manifest.json"; then
    if [ "$finish_rc" -eq 0 ] || [ "$finish_rc" -eq 3 ]; then
      result=error
      reason=evidence-unwritable
      printf 'health: cannot write evidence manifest\n' >&2
    fi
    finish_rc=1
  fi
  jq -n --arg night_id "$night_id" --arg repo "$repo" --arg source "$source" \
    --arg commit "$commit" --arg selection "$selection" --arg runner "$runner" \
    --arg result "$result" --arg reason "$reason" --arg refresh "$refresh" --argjson suites "$suites" \
    --argjson failures "$failures" --argjson elapsed "$(($(date +%s) - started))" \
    --argjson commands "$commands" \
    '{night_id:$night_id,repo:$repo,source:$source,commit:$commit,selection:$selection,
      runner:(if $runner == "" then null else $runner end),result:$result,
      reason:(if $reason == "" then null else $reason end),
      refresh:(if $refresh == "" then null else $refresh end),suites:$suites,
      failures:$failures,elapsed_sec:$elapsed,commands:$commands}' > "$LANE_DIR/health.json" || exit 1
  exit "$finish_rc"
}

# Snapshot descendants before signalling, including children previously observed
# whose parents have since exited. Job control gives each run its own group.
collect_descendants() {
  tree_root=$1
  tree_known=$2
  COLLECTED_DESCENDANTS=$tree_known
  tree_snapshot=$(ps -axo pid=,ppid= 2>/dev/null) || return 1
  tree_frontier="$tree_root $tree_known"
  tree_all=$tree_known
  while [ -n "$tree_frontier" ]; do
    tree_next=
    for tree_parent in $tree_frontier; do
      tree_children=$(printf '%s\n' "$tree_snapshot" |
        awk -v parent="$tree_parent" '$2 == parent {print $1}')
      for tree_child in $tree_children; do
        case " $tree_all " in *" $tree_child "*) ;; *)
          tree_all="$tree_all $tree_child"
          tree_next="$tree_next $tree_child"
          ;;
        esac
      done
    done
    tree_frontier=$tree_next
  done
  COLLECTED_DESCENDANTS=$tree_all
}

stop_seat_tree() {
  stop_root=$1
  stop_known=$2
  collect_descendants "$stop_root" "$stop_known" || true
  stop_known=$COLLECTED_DESCENDANTS
  /bin/kill -TERM "-$stop_root" 2>/dev/null || true
  for stop_pid in $stop_known $stop_root; do
    kill -TERM "$stop_pid" 2>/dev/null || true
  done
  sleep 0.5
  collect_descendants "$stop_root" "$stop_known" || true
  stop_known=$COLLECTED_DESCENDANTS
  /bin/kill -KILL "-$stop_root" 2>/dev/null || true
  for stop_pid in $stop_known $stop_root; do
    kill -KILL "$stop_pid" 2>/dev/null || true
  done
}

# Avoid signalling a reaped group (whose pid could be reused) when no members
# remain. If process inspection is unavailable, retain the full fail-closed stop.
stop_remaining_tree() {
  local remaining_root=$1 remaining_known=$2 members alive='' pid group_rc=0
  if ! command -v pgrep >/dev/null 2>&1 ||
      ! collect_descendants "$remaining_root" "$remaining_known"; then
    stop_seat_tree "$remaining_root" "$remaining_known"
    return
  fi
  remaining_known=$COLLECTED_DESCENDANTS
  members=$(pgrep -g "$remaining_root" 2>/dev/null) || group_rc=$?
  if [ "$group_rc" -gt 1 ]; then
    stop_seat_tree "$remaining_root" "$remaining_known"
    return
  fi
  for pid in $remaining_known $members; do
    if kill -0 "$pid" 2>/dev/null; then alive="$alive $pid"; fi
  done
  [ -n "$alive" ] || return 0
  /bin/kill -TERM "-$remaining_root" 2>/dev/null || true
  for pid in $alive; do kill -TERM "$pid" 2>/dev/null || true; done
  sleep 0.5
  collect_descendants "$remaining_root" "$alive" || true
  alive="$alive $COLLECTED_DESCENDANTS"
  /bin/kill -KILL "-$remaining_root" 2>/dev/null || true
  for pid in $alive; do kill -KILL "$pid" 2>/dev/null || true; done
}

# Selection validation stays with the caller; it may supply its validated
# rotation snapshot so the chosen path and metadata come from the same read.
candidate_source() {
  if [ -n "${HEALTH_TARGET_SOURCE:-}" ]; then
    printf '%s\n' "$HEALTH_TARGET_SOURCE"
  elif [[ "${HEALTH_ROTATION_LANE:-}" =~ ^lane_[0-9]+$ ]]; then
    if [ "$#" -gt 0 ]; then
      printf '%s\n' "$1"
    else
      cat "$(dirname "$LANE_DIR")/$HEALTH_ROTATION_LANE/rotation.json" 2>/dev/null || true
    fi | jq -r --arg night "$night_id" \
      'select(.night_id == $night) | .path // empty' 2>/dev/null || true
  fi
}

no_input() {
  result=no-input
  reason=$1
  printf 'health: NO-INPUT reason=%s\n' "$reason"
  exit 3
}

# A lane inside the source cannot safely receive even error artifacts. Check
# its existing ancestor before mkdir/truncation, including rotation selections.
preflight_source=$(candidate_source)
if [ -n "$preflight_source" ] && [ -d "$preflight_source" ] &&
    preflight_root=$(git -C "$preflight_source" rev-parse --show-toplevel 2>/dev/null); then
  preflight_root=$(cd "$preflight_root" && pwd -P)
  lane_ancestor=$LANE_DIR
  while [ ! -d "$lane_ancestor" ]; do lane_ancestor=$(dirname "$lane_ancestor"); done
  lane_ancestor=$(cd "$lane_ancestor" && pwd -P)
  case "$lane_ancestor/" in "$preflight_root/"*)
    error lane-inside-source 'invalid source: LANE_DIR is inside source checkout; cannot safely write lane artifacts'
    ;;
  esac
fi

mkdir -p "$LANE_DIR/evidence" "$LANE_DIR/work"
LANE_DIR=$(cd "$LANE_DIR" && pwd -P)
export LANE_DIR GIT_TERMINAL_PROMPT=0
trap finish EXIT
trap 'error interrupted interrupted' INT TERM
: > "$LANE_DIR/findings.jsonl"
[ -n "$night_id" ] || error night-id-required 'NIGHT_ID is required'

if [ -n "${HEALTH_TEST_CMD:-}" ] && [ -n "${HEALTH_SUITE_GLOB:-}" ]; then
  error exclusive-runners 'HEALTH_TEST_CMD and HEALTH_SUITE_GLOB are mutually exclusive'
fi
timebox=${HEALTH_TIMEBOX_SEC-1800}
[[ "$timebox" =~ ^[0-9]+$ ]] && [[ "$timebox" =~ [1-9] ]] ||
  error invalid-timebox 'HEALTH_TIMEBOX_SEC must be a positive integer'

if [ -n "${HEALTH_TARGET_SOURCE:-}" ]; then
  source=$(candidate_source)
elif [ -n "${HEALTH_ROTATION_LANE:-}" ]; then
  selection=rotation
  [[ "$HEALTH_ROTATION_LANE" =~ ^lane_[0-9]+$ ]] || error invalid-rotation-lane 'invalid HEALTH_ROTATION_LANE'
  rotation_file="$(dirname "$LANE_DIR")/$HEALTH_ROTATION_LANE/rotation.json"
  if ! rotation=$(jq -e -s --arg night "$night_id" '
      select(length == 1) | .[0] | select(type == "object" and .night_id == $night and
      (.selected | type == "string" and length > 0) and
      (.path | type == "string" and startswith("/")) and
      (.refresh | type == "string"))' "$rotation_file" 2>/dev/null); then
    no_input rotation-evidence-missing
  fi
  source=$(candidate_source "$rotation")
  repo=$(basename "$source")
  selected=$(printf '%s\n' "$rotation" | jq -r '.selected')
  # rotate.sh writes refresh=skipped both for a missing mirror and for
  # REVIEW_ROTATION_REFRESH=0, so the value is recorded but never used to
  # decide anything; missing-mirror is detected from state and the path.
  refresh=$(printf '%s\n' "$rotation" | jq -r '.refresh')
  if [ -n "${HEALTH_ROTATION_STATE:-}" ]; then
    case "$HEALTH_ROTATION_STATE" in /*) ;; *) error invalid-rotation-state 'HEALTH_ROTATION_STATE must be absolute' ;; esac
    jq -e -s --arg selected "$selected" --arg night "$night_id" '
      length == 1 and (.[0] | .schema_version == 1 and
        .targets[$selected].last_attempt == $night)' "$HEALTH_ROTATION_STATE" >/dev/null 2>&1 ||
      no_input rotation-state-mismatch
    if jq -e -s --arg selected "$selected" '.[0].targets[$selected].last_result == "missing-mirror"' \
        "$HEALTH_ROTATION_STATE" >/dev/null 2>&1; then
      no_input rotation-missing-mirror
    fi
  fi
else
  error source-required 'HEALTH_TARGET_SOURCE or HEALTH_ROTATION_LANE is required'
fi

case "$source" in /*) ;; *) error invalid-source "invalid source $source (must be absolute)" ;; esac
repo=$(basename "$source")
if [ ! -d "$source" ] || ! git -C "$source" rev-parse --git-dir >/dev/null 2>&1 ||
    [ "$(git -C "$source" rev-parse --is-bare-repository 2>/dev/null || true)" != false ]; then
  # Under rotation this is the mirror rotate.sh already reported as missing:
  # NO-INPUT, not an infrastructure error. An explicit source stays exit 1.
  [ "$selection" != rotation ] || no_input rotation-missing-mirror
  error invalid-source "invalid source $source"
fi
source_root=$(git -C "$source" rev-parse --show-toplevel)
source_root=$(cd "$source_root" && pwd -P)
case "$LANE_DIR/" in "$source_root/"*) error lane-inside-source 'invalid source: lane directory is inside source checkout' ;; esac
clone_dir="$LANE_DIR/work/health-checkout"
# Resolve an existing work directory before checking the disposable subtree.
clone_parent=$(cd "$LANE_DIR/work" && pwd -P)
case "$source_root/" in "$clone_parent/health-checkout/"*)
  error invalid-source 'invalid source: source checkout is inside disposable health-checkout'
  ;;
esac
rm -rf "$clone_dir"
if ! git clone --quiet --no-hardlinks "$source" "$clone_dir" > "$LANE_DIR/evidence/clone.log" 2>&1; then
  error clone-failed 'clone failed (see evidence/clone.log)'
fi
commit=$(git -C "$clone_dir" rev-parse --short HEAD) || error head-unreadable 'cannot read cloned HEAD'
printf 'health: target=%s source=%s commit=%s selection=%s\n' "$repo" "$source" "$commit" "$selection"

run_command() {
  target=$1
  shift
  slug=$(printf '%s' "$target" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-')
  # Keep the evidence filename well under the 255-byte component limit; a
  # long HEALTH_TEST_CMD would otherwise fail the log redirection and the
  # command would never start. Pre-create the log so that any unwritable
  # path is an error (exit 1, no finding) rather than a fabricated failure.
  if [ "${#slug}" -gt 120 ]; then
    slug="${slug:0:120}-$(printf '%s' "$target" | shasum -a 256 | cut -c1-12)"
  fi
  log_ref="evidence/health-$slug.log"
  : > "$LANE_DIR/$log_ref" || error evidence-log-unwritable "cannot open evidence log for $target"
  command_started=$(date +%s)
  timed_out=false
  active_known=
  set -m
  (cd "$clone_dir" && exec "$@") > "$LANE_DIR/$log_ref" 2>&1 &
  active_pid=$!
  set +m
  while kill -0 "$active_pid" 2>/dev/null; do
    collect_descendants "$active_pid" "$active_known" || error process-inspection-failed 'cannot inspect process tree'
    active_known=$COLLECTED_DESCENDANTS
    if [ "$(($(date +%s) - command_started))" -ge "$timebox" ]; then
      kill -0 "$active_pid" 2>/dev/null || break
      timed_out=true
      stop_seat_tree "$active_pid" "$active_known"
      break
    fi
    sleep 0.1
  done
  if wait "$active_pid" 2>/dev/null; then rc=0; else rc=$?; fi
  # Also clean up background children after a normally completed command.
  stop_remaining_tree "$active_pid" "$active_known"
  active_pid=
  elapsed=$(($(date +%s) - command_started))
  suites=$((suites + 1))
  commands=$(printf '%s\n' "$commands" | jq -c --arg target "$target" \
    --argjson rc "$rc" --argjson elapsed "$elapsed" --arg log "$log_ref" \
    '. + [{target:$target,exit_code:$rc,elapsed_sec:$elapsed,log:$log}]')
  printf 'health: suite=%s exit=%s elapsed=%ss\n' "$target" "$rc" "$elapsed"
  if [ "$timed_out" = true ]; then
    printf 'health: timed out after %ss\n' "$timebox" >> "$LANE_DIR/$log_ref"
    result=timeout
    reason=timebox
    printf 'health: TIMEBOX suite=%s after %ss\n' "$target" "$timebox"
    exit 1
  fi
  if [ "$rc" -ne 0 ]; then
    failures=$((failures + 1))
    repo_slug=$(printf '%s' "$repo" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-')
    jq -nc --arg id "health-$repo_slug-$slug-$commit" --arg repo "$repo" --arg target "$target" \
      --arg symptom "Test command '$target' exited $rc in ${elapsed}s at commit $commit under the credential-free lane environment" \
      --arg date "$night_id" --arg evidence "$log_ref" \
      '{id:$id,repo:$repo,target:$target,symptom:$symptom,kind:"test-failure",
        confirm_cost:"3分",date:$date,evidence:[$evidence]}' >> "$LANE_DIR/findings.jsonl"
  fi
}

cmd=${HEALTH_TEST_CMD:-}
if [ -n "$cmd" ]; then
  runner=explicit-cmd
elif [ -n "${HEALTH_SUITE_GLOB:-}" ]; then
  runner="suite-glob"
elif [ -f "$clone_dir/Makefile" ] && grep -Eq '^test:([^=]|$)' "$clone_dir/Makefile"; then
  runner=make-test
  command -v make >/dev/null 2>&1 || error runner-unavailable 'make is unavailable'
  cmd='make test'
elif [ -f "$clone_dir/tests/run.sh" ]; then
  runner=tests-run
  cmd='/bin/bash tests/run.sh'
elif [ -f "$clone_dir/tests/run_tests.sh" ]; then
  runner=tests-run_tests
  cmd='/bin/bash tests/run_tests.sh'
else
  no_input no-test-runner
fi
if [ "$runner" = suite-glob ]; then
  case "$HEALTH_SUITE_GLOB" in /*|../*|*/../*|*/..) error invalid-suite-glob 'HEALTH_SUITE_GLOB must stay relative to clone root' ;; esac
  printf 'health: runner=%s cmd=%s\n' "$runner" "$HEALTH_SUITE_GLOB"
  cd "$clone_dir"
  # Expand only pathname patterns, never evaluate shell code or split spaces.
  old_ifs=$IFS
  old_nullglob=false
  shopt -q nullglob && old_nullglob=true
  IFS=
  shopt -s nullglob
  # shellcheck disable=SC2206
  suite_files=($HEALTH_SUITE_GLOB)
  IFS=$old_ifs
  [ "$old_nullglob" = true ] || shopt -u nullglob
  for suite in ${suite_files[@]+"${suite_files[@]}"}; do
    [ -f "$suite" ] || continue
    run_command "$suite" /bin/bash "./$suite"
  done
  [ "$suites" -gt 0 ] || no_input no-suites-matched
else
  printf 'health: runner=%s cmd=%s\n' "$runner" "$cmd"
  run_command "$cmd" /bin/bash -c "$cmd"
fi
result=ran
reason=
printf 'health: %s/%s suites failed at commit %s\n' "$failures" "$suites" "$commit"
exit 0
