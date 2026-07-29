#!/bin/bash
set -euo pipefail

lane_exec() {
  lane_dir=$1
  shift

  LANE_TIMED_OUT=false
  LANE_EXIT_CODE=1
  LANE_WALLCLOCK_SEC=0
  LANE_SURVIVORS_JSON='[]'
  LANE_SETUP_FAILED=true
  NIGHTSHIFT_ACTIVE_LANE_PID=
  NIGHTSHIFT_ACTIVE_LANE_DESCENDANTS=
  NIGHTSHIFT_PROCESS_INSPECTION_FAILED=false

  lane_home="$lane_dir/home"
  lane_tmp="$lane_dir/tmp"
  lane_work="$lane_dir/work"
  if ! mkdir -p "$lane_home" "$lane_tmp" "$lane_work"; then
    nightshift_log ERROR "Failed to create lane environment under $lane_dir"
    export LANE_TIMED_OUT LANE_EXIT_CODE LANE_WALLCLOCK_SEC
    export LANE_SURVIVORS_JSON LANE_SETUP_FAILED
    return 1
  fi

  # An empty helper resets any credential helper inherited from macOS's system
  # Git config while keeping the lane process environment to the allowlist below.
  if {
    printf '%s\n' '[credential]'
    printf '%s\n' '	helper ='
  } > "$lane_home/.gitconfig"; then
    :
  else
    nightshift_log ERROR "Failed to write isolated lane Git config: $lane_home/.gitconfig"
    export LANE_TIMED_OUT LANE_EXIT_CODE LANE_WALLCLOCK_SEC
    export LANE_SURVIVORS_JSON LANE_SETUP_FAILED
    return 1
  fi

  old_ifs=$IFS
  IFS=:
  for home_link in $LANE_HOME_LINKS; do
    [ -n "$home_link" ] || continue
    case "$home_link" in
      /*) ;;
      *) nightshift_log WARN "Ignoring non-absolute LANE_HOME_LINKS entry: $home_link"; continue ;;
    esac
    if [ ! -e "$home_link" ] && [ ! -L "$home_link" ]; then
      nightshift_log WARN "Ignoring missing LANE_HOME_LINKS entry: $home_link"
      continue
    fi
    link_name=$(basename "$home_link")
    case "$link_name:$home_link" in
      .gitconfig:*|.ssh:*|.config:*|.git-credentials:*|.netrc:*|.aws:*|.gnupg:*|gh:*/.config/gh)
        nightshift_log WARN "Refusing sensitive LANE_HOME_LINKS entry: $home_link"
        continue
        ;;
    esac
    if [ -e "$lane_home/$link_name" ] || [ -L "$lane_home/$link_name" ]; then
      nightshift_log WARN "Ignoring duplicate lane HOME link name: $link_name"
      continue
    fi
    if ! ln -s "$home_link" "$lane_home/$link_name"; then
      IFS=$old_ifs
      nightshift_log ERROR "Failed to link lane HOME entry: $home_link"
      export LANE_TIMED_OUT LANE_EXIT_CODE LANE_WALLCLOCK_SEC
      export LANE_SURVIVORS_JSON LANE_SETUP_FAILED
      return 1
    fi
  done
  IFS=$old_ifs

  lane_started=$(date '+%s')
  LANE_SETUP_FAILED=false
  set -m
  (
    if ! cd "$lane_work"; then
      exit 125
    fi
    exec env -i \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin \
      HOME="$lane_home" \
      TMPDIR="$lane_tmp" \
      LANG="$LANG" \
      TERM=dumb \
      NIGHT_ID="$NIGHT_ID" \
      LANE_DIR="$lane_dir" \
      GIT_CEILING_DIRECTORIES="$lane_dir" \
      "$@"
  ) </dev/null >"$lane_dir/lane.log" 2>&1 &
  lane_pid=$!
  NIGHTSHIFT_ACTIVE_LANE_PID=$lane_pid
  set +m
  lane_deadline_sec=$((LANE_TIMEBOX_MIN * 60))
  # Sample descendants during the launch window so a child is recorded before
  # it can detach with setsid(). The zero-minute test deadline gets a bounded
  # half-second window; production deadlines get the original scheduler tick.
  if [ "$lane_deadline_sec" -eq 0 ]; then
    lane_launch_ticks=50
  else
    lane_launch_ticks=10
  fi
  while [ "$lane_launch_ticks" -gt 0 ]; do
    nightshift_refresh_process_tree "$lane_pid" "$NIGHTSHIFT_ACTIVE_LANE_DESCENDANTS"
    NIGHTSHIFT_ACTIVE_LANE_DESCENDANTS=$NIGHTSHIFT_PROCESS_PIDS
    sleep 0.01
    lane_launch_ticks=$((lane_launch_ticks - 1))
  done

  while nightshift_process_tree_alive "$lane_pid" "$NIGHTSHIFT_ACTIVE_LANE_DESCENDANTS"; do
    NIGHTSHIFT_ACTIVE_LANE_DESCENDANTS=$NIGHTSHIFT_PROCESS_KNOWN
    lane_now=$(date '+%s')
    if [ $((lane_now - lane_started)) -ge "$lane_deadline_sec" ]; then
      LANE_TIMED_OUT=true
      nightshift_stop_process_tree "$lane_pid" "$NIGHTSHIFT_ACTIVE_LANE_DESCENDANTS"
      NIGHTSHIFT_ACTIVE_LANE_DESCENDANTS=$NIGHTSHIFT_PROCESS_KNOWN
      break
    fi
    sleep 0.1
  done

  if wait "$lane_pid" 2>/dev/null; then
    LANE_EXIT_CODE=0
  else
    LANE_EXIT_CODE=$?
  fi

  # Always sweep after the leader is reaped. This catches same-group children
  # whose leader exited first as well as descendants that escaped with setsid().
  nightshift_stop_process_tree "$lane_pid" "$NIGHTSHIFT_ACTIVE_LANE_DESCENDANTS"
  lane_survivors=$NIGHTSHIFT_PROCESS_SURVIVORS
  NIGHTSHIFT_ACTIVE_LANE_PID=
  NIGHTSHIFT_ACTIVE_LANE_DESCENDANTS=
  if [ -n "$(printf '%s' "$lane_survivors" | tr -d '[:space:]')" ]; then
    nightshift_log ERROR "Lane $lane_pid still has survivors after descendant sweep: $lane_survivors"
    if [ "$LANE_EXIT_CODE" -eq 0 ]; then
      LANE_EXIT_CODE=125
    fi
  fi
  if ! LANE_SURVIVORS_JSON=$(printf '%s\n' "$lane_survivors" |
    jq -Rsc '[splits("[[:space:]]+") | select(length > 0) | tonumber]'); then
    LANE_SURVIVORS_JSON='[]'
    LANE_EXIT_CODE=125
  fi
  if [ "$LANE_TIMED_OUT" = true ] &&
    [ "$NIGHTSHIFT_PROCESS_INSPECTION_FAILED" = true ]; then
    nightshift_log ERROR "Lane descendant inspection was unavailable after timeout"
    if ! LANE_SURVIVORS_JSON=$(printf '%s\n' "$LANE_SURVIVORS_JSON" |
      jq -c '. + ["process_inspection_unavailable"]'); then
      LANE_SURVIVORS_JSON='["process_inspection_unavailable"]'
    fi
    if [ "$LANE_EXIT_CODE" -eq 0 ]; then
      LANE_EXIT_CODE=125
    fi
  fi
  LANE_WALLCLOCK_SEC=$(( $(date '+%s') - lane_started ))
  export LANE_TIMED_OUT LANE_EXIT_CODE LANE_WALLCLOCK_SEC
  export LANE_SURVIVORS_JSON LANE_SETUP_FAILED
  return 0
}
