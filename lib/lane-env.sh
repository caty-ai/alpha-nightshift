#!/bin/bash
set -euo pipefail

lane_exec() {
  lane_dir=$1
  shift

  lane_home="$lane_dir/home"
  lane_tmp="$lane_dir/tmp"
  lane_work="$lane_dir/work"
  mkdir -p "$lane_home" "$lane_tmp" "$lane_work"

  # An empty helper resets any credential helper inherited from macOS's system
  # Git config while keeping the lane process environment to the allowlist below.
  {
    printf '%s\n' '[credential]'
    printf '%s\n' '	helper ='
  } > "$lane_home/.gitconfig"

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
    if [ "$link_name" = .gitconfig ]; then
      nightshift_log WARN "Ignoring LANE_HOME_LINKS entry reserved for credential isolation: $home_link"
      continue
    fi
    if [ -e "$lane_home/$link_name" ] || [ -L "$lane_home/$link_name" ]; then
      nightshift_log WARN "Ignoring duplicate lane HOME link name: $link_name"
      continue
    fi
    ln -s "$home_link" "$lane_home/$link_name"
  done
  IFS=$old_ifs

  lane_started=$(date '+%s')
  (
    cd "$lane_work"
    env -i \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin \
      HOME="$lane_home" \
      TMPDIR="$lane_tmp" \
      LANG="$LANG" \
      TERM=dumb \
      NIGHT_ID="$NIGHT_ID" \
      LANE_DIR="$lane_dir" \
      "$@"
  ) >"$lane_dir/lane.log" 2>&1 &
  lane_pid=$!
  lane_deadline_sec=$((LANE_TIMEBOX_MIN * 60))
  LANE_TIMED_OUT=false

  while kill -0 "$lane_pid" 2>/dev/null; do
    lane_now=$(date '+%s')
    if [ $((lane_now - lane_started)) -ge "$lane_deadline_sec" ]; then
      LANE_TIMED_OUT=true
      kill -TERM "$lane_pid" 2>/dev/null || true
      lane_grace_started=$(date '+%s')
      while kill -0 "$lane_pid" 2>/dev/null; do
        lane_grace_now=$(date '+%s')
        if [ $((lane_grace_now - lane_grace_started)) -ge 10 ]; then
          kill -KILL "$lane_pid" 2>/dev/null || true
          break
        fi
        sleep 0.1
      done
      break
    fi
    sleep 0.1
  done

  if wait "$lane_pid" 2>/dev/null; then
    LANE_EXIT_CODE=0
  else
    LANE_EXIT_CODE=$?
  fi
  LANE_WALLCLOCK_SEC=$(( $(date '+%s') - lane_started ))
  export LANE_TIMED_OUT LANE_EXIT_CODE LANE_WALLCLOCK_SEC
  return 0
}
