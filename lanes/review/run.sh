#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ADAPTER_ROOT="$SCRIPT_DIR/adapters"
EVIDENCE_LOG=
EVIDENCE_FD_OPEN=false
FINDINGS_BUFFER=
SEEN_FINDING_IDS='|'

log() {
  printf '%s\n' "review: $*" >&2
  if [ "$EVIDENCE_FD_OPEN" = true ]; then
    printf '%s\n' "review: $*" >&4
  fi
}

announce() {
  printf '%s\n' "review: $*"
  if [ "$EVIDENCE_FD_OPEN" = true ]; then
    printf '%s\n' "review: $*" >&4
  fi
}

lens_record() {
  case "$1" in
    0) printf '%s\t%s\t%s\n' 'Bug' 'bug' 'Find concrete correctness defects and failure modes.' ;;
    1) printf '%s\t%s\t%s\n' 'External Issue Triage(受け口のみ)' 'external-issue-triage' 'Assess repository evidence relevant to external issue intake; do not perform external triage.' ;;
    2) printf '%s\t%s\t%s\n' 'Refactor' 'refactor' 'Find behavior-preserving simplification or modularity problems.' ;;
    3) printf '%s\t%s\t%s\n' 'Feature Improvement' 'feature-improvement' 'Find concrete improvements to existing features, not speculative new products.' ;;
    4) printf '%s\t%s\t%s\n' 'Security' 'security' 'Inspect trust boundaries, secret handling, unsafe inputs, and privilege assumptions.' ;;
    5) printf '%s\t%s\t%s\n' 'Performance' 'performance' 'Find evidenced latency, resource, or algorithmic risks.' ;;
    6) printf '%s\t%s\t%s\n' 'Dependency' 'dependency' 'Inspect dependency pinning, compatibility, provenance, and maintenance risk.' ;;
    7) printf '%s\t%s\t%s\n' 'UI・UX・Accessibility' 'ui-ux-accessibility' 'Inspect user experience, interface consistency, and accessibility evidence.' ;;
    8) printf '%s\t%s\t%s\n' 'Demo Device・UT' 'demo-device-ut' 'Inspect demo, device, and user-testing readiness and observability.' ;;
    9) printf '%s\t%s\t%s\n' 'Documentation Drift' 'documentation-drift' 'Find concrete divergence between documentation and repository behavior.' ;;
    *) return 1 ;;
  esac
}

validate_roster() {
  roster=$1
  opus_enabled=$2
  roster_tmp=$3
  case "$opus_enabled" in 0|1) ;; *) return 1 ;; esac
  [ -n "$roster" ] || return 1
  printf '%s\n' "$roster" | tr ',' '\n' > "$roster_tmp.unsorted"
  [ -s "$roster_tmp.unsorted" ] || return 1
  while IFS= read -r roster_seat || [ -n "$roster_seat" ]; do
    case "$roster_seat" in
      codex|kimi|glm|grok) ;;
      opus) [ "$opus_enabled" = 1 ] || return 1 ;;
      *) return 1 ;;
    esac
  done < "$roster_tmp.unsorted"
  LC_ALL=C sort "$roster_tmp.unsorted" > "$roster_tmp"
  if [ "$(wc -l < "$roster_tmp" | tr -d '[:space:]')" -ne \
    "$(LC_ALL=C sort -u "$roster_tmp" | wc -l | tr -d '[:space:]')" ]; then
    return 1
  fi
  rm -f "$roster_tmp.unsorted"
}

enumerate_combinations() {
  roster_file=$1
  seats_per_night=$2
  output_file=$3
  awk -v choose="$seats_per_night" '
    function combinations(start, depth, prefix, combo_index, next_prefix) {
      if (depth > choose) {
        print prefix
        return
      }
      for (combo_index = start; combo_index <= count - choose + depth; combo_index++) {
        next_prefix = prefix
        if (length(next_prefix) > 0) {
          next_prefix = next_prefix " " seats[combo_index]
        } else {
          next_prefix = seats[combo_index]
        }
        combinations(combo_index + 1, depth + 1, next_prefix)
      }
    }
    { seats[++count] = $0 }
    END {
      if (choose < 1 || choose > count) exit 1
      combinations(1, 1, "")
    }
  ' "$roster_file" > "$output_file"
}

select_assignment() {
  selection_night=$1
  selection_roster=$2
  selection_count=$3
  selection_opus=$4
  selection_dir=$5
  roster_file="$selection_dir/roster.txt"
  combos_file="$selection_dir/combinations.txt"
  case "$selection_count" in ''|*[!0-9]*) return 1 ;; esac
  validate_roster "$selection_roster" "$selection_opus" "$roster_file" || return 1
  roster_count=$(wc -l < "$roster_file" | tr -d '[:space:]')
  [ "$roster_count" -gt 0 ] || return 1
  [ "$selection_count" -ge 1 ] || return 1
  if [ "$selection_count" -gt "$roster_count" ]; then
    log "WARN REVIEW_SEATS_PER_NIGHT=$selection_count exceeds roster size=$roster_count; clamping"
    selection_count=$roster_count
  fi
  enumerate_combinations "$roster_file" "$selection_count" "$combos_file"
  combo_count=$(wc -l < "$combos_file" | tr -d '[:space:]')
  [ "$combo_count" -gt 0 ] || return 1
  lens_hash=$(printf '%s|lens' "$selection_night" | cksum | awk '{print $1}')
  seats_hash=$(printf '%s|seats' "$selection_night" | cksum | awk '{print $1}')
  lens_index=$((lens_hash % 10))
  combo_index=$((seats_hash % combo_count))
  SELECTED_LENS_RECORD=$(lens_record "$lens_index")
  SELECTED_SEATS=$(sed -n "$((combo_index + 1))p" "$combos_file")
  SELECTED_HASH=$lens_hash
  SELECTED_SEATS_HASH=$seats_hash
  SELECTED_COMBO_COUNT=$combo_count
}

render_prompt() {
  lens_name=$1
  lens_guidance=$2
  commit=$3
  candidate_output=$4
  digest_file=$5
  while IFS= read -r prompt_line || [ -n "$prompt_line" ]; do
    case "$prompt_line" in
      '{{LENS_NAME}}') printf '%s\n' "$lens_name" ;;
      '{{LENS_GUIDANCE}}') printf '%s\n' "$lens_guidance" ;;
      '{{COMMIT}}') printf '%s\n' "$commit" ;;
      '{{CANDIDATE_OUTPUT}}') printf '%s\n' "$candidate_output" ;;
      '{{REPO_DIGEST}}')
        if [ -n "$digest_file" ]; then
          printf '%s\n' 'Bounded repository digest (context only; verify against the checkout):'
          cat "$digest_file"
        fi
        ;;
      *) printf '%s\n' "$prompt_line" ;;
    esac
  done < "$SCRIPT_DIR/prompt.tmpl.md"
}

make_repo_digest() {
  digest_workdir=$1
  digest_lens=$2
  digest_output=$3
  digest_tmp="$digest_output.tmp"
  files_tmp="$digest_output.files"
  tree_tmp="$digest_output.tree"
  case "$digest_lens" in
    Security) digest_pattern='auth|secret|token|security|permission|guard|credential' ;;
    Performance) digest_pattern='perf|bench|cache|queue|worker|async|timeout' ;;
    Dependency) digest_pattern='lock|package|requirements|gemfile|cargo|go\.mod|depend' ;;
    'UI・UX・Accessibility') digest_pattern='ui|ux|view|component|html|css|access|aria' ;;
    'Demo Device・UT') digest_pattern='demo|device|test|spec|fixture|scenario' ;;
    'Documentation Drift') digest_pattern='readme|docs|design|spec|changelog' ;;
    *) digest_pattern='test|src|lib|bin|config|readme|design' ;;
  esac
  if ! (cd "$digest_workdir" && git ls-files | LC_ALL=C sort) > "$tree_tmp"; then
    rm -f "$tree_tmp"
    return 1
  fi
  {
    printf 'lens: %s\n\ntracked tree:\n' "$digest_lens"
    sed -n '1,800p' "$tree_tmp"
    printf '\nlens-matched file heads:\n'
  } > "$digest_tmp"
  digest_files_rc=0
  (grep -E -i "$digest_pattern" "$tree_tmp" | sed -n '1,40p') \
    > "$files_tmp" || digest_files_rc=$?
  case "$digest_files_rc" in
    0|1) ;;
    *) rm -f "$digest_tmp" "$files_tmp" "$tree_tmp"; return 1 ;;
  esac
  while IFS= read -r digest_path || [ -n "$digest_path" ]; do
    [ -n "$digest_path" ] || continue
    case "$digest_path" in *$'\n'*) continue ;; esac
    if [ -f "$digest_workdir/$digest_path" ] && grep -Iq . "$digest_workdir/$digest_path" 2>/dev/null; then
      printf '\n--- %s ---\n' "$digest_path" >> "$digest_tmp"
      sed -n '1,60p' "$digest_workdir/$digest_path" >> "$digest_tmp"
    fi
  done < "$files_tmp"
  head -c 60000 "$digest_tmp" > "$digest_output"
  rm -f "$digest_tmp" "$files_tmp" "$tree_tmp"
}

candidate_normalize() {
  candidate_line=$1
  candidate_seat=$2
  candidate_lens_slug=$3
  candidate_commit=$4
  candidate_repo=$5
  candidate_night=$6
  candidate_validated=$(printf '%s\n' "$candidate_line" | jq -e -c \
    --arg repo "$candidate_repo" \
    --arg date "$candidate_night" \
    --arg persona "seat:$candidate_seat" \
    --arg evidence "evidence/seat-$candidate_seat.log" '
      def required_text:
        type == "string" and length > 0 and
        (explode | all(. >= 32 and . != 127));
      def optional_text:
        type == "string" and (explode | all(. >= 32 and . != 127));
      def safe_evidence:
        type == "string" and length > 0 and
        (explode | all(. >= 32 and . != 127)) and
        (startswith("/") | not) and
        (startswith("//") | not) and
        (test("^[A-Za-z][A-Za-z0-9+.-]*:") | not) and
        (test("(^|/)\\.\\.?(?:/|$)") | not);
      select(
        type == "object" and
        ((keys - ["id","repo","target","symptom","kind","confirm_cost","date","interpretation","persona","evidence"]) | length == 0) and
        (.id | required_text) and
        (.repo | required_text) and
        (.target | required_text) and
        (.symptom | required_text) and
        (.kind | required_text) and
        (.confirm_cost | required_text and (. == "即断" or . == "1分" or . == "3分")) and
        (.date | required_text) and
        ((has("interpretation") | not) or (.interpretation | optional_text)) and
        ((has("persona") | not) or (.persona | optional_text)) and
        ((has("evidence") | not) or
          (.evidence | type == "array" and all(.[]; safe_evidence)))
      )
      | {
          repo: $repo,
          target: .target,
          symptom: .symptom,
          kind: .kind,
          confirm_cost: .confirm_cost,
          date: $date
        }
        + (if has("interpretation") then {interpretation:.interpretation} else {} end)
        + {persona:$persona,evidence:[$evidence]}
    ' 2>/dev/null) || return 1
  candidate_target=$(printf '%s\n' "$candidate_validated" | jq -r '.target') || return 1
  candidate_symptom=$(printf '%s\n' "$candidate_validated" | jq -r '.symptom') || return 1
  candidate_digest=$(printf '%s\n%s' "$candidate_target" "$candidate_symptom" |
    /usr/bin/shasum -a 256 | awk '{print substr($1, 1, 8)}') || return 1
  [ "${#candidate_digest}" -eq 8 ] || return 1
  candidate_id=$(printf 'rv-%s-%s-%s-%s' \
    "$candidate_lens_slug" "$candidate_seat" "$candidate_commit" "$candidate_digest")
  printf '%s\n' "$candidate_validated" | jq -e -c --arg id "$candidate_id" \
    '{id:$id} + .' 2>/dev/null
}

checkout_tree_fingerprint() {
  fingerprint_checkout=$1
  (
    cd "$fingerprint_checkout"
    COPYFILE_DISABLE=1 /usr/bin/tar -cf - .
  ) | /usr/bin/shasum -a 256 | awk '{print $1}'
}

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
  stop_tick=0
  while [ "$stop_tick" -lt 10 ]; do
    sleep 0.05
    stop_tick=$((stop_tick + 1))
  done
  /bin/kill -KILL "-$stop_root" 2>/dev/null || true
  for stop_pid in $stop_known $stop_root; do
    kill -KILL "$stop_pid" 2>/dev/null || true
  done
  STOPPED_DESCENDANTS=$stop_known
}

run_with_watchdog() {
  watchdog_timeout=$1
  watchdog_log=$2
  shift 2
  watchdog_known=
  watchdog_timed_out=false
  watchdog_started=$(date '+%s')
  set -m
  "$@" > "$watchdog_log" 2>&1 &
  watchdog_pid=$!
  set +m
  watchdog_launch_ticks=10
  while [ "$watchdog_launch_ticks" -gt 0 ]; do
    collect_descendants "$watchdog_pid" "$watchdog_known" || true
    watchdog_known=$COLLECTED_DESCENDANTS
    sleep 0.01
    watchdog_launch_ticks=$((watchdog_launch_ticks - 1))
  done
  while kill -0 "$watchdog_pid" 2>/dev/null; do
    collect_descendants "$watchdog_pid" "$watchdog_known" || true
    watchdog_known=$COLLECTED_DESCENDANTS
    watchdog_now=$(date '+%s')
    if [ $((watchdog_now - watchdog_started)) -ge "$watchdog_timeout" ]; then
      # kill -0 also succeeds for an exited but unreaped child. The preceding
      # date command substitution forks, letting bash reap the job first; keep
      # this re-check after that read and do not replace it with a fork-free clock.
      kill -0 "$watchdog_pid" 2>/dev/null || break
      watchdog_timed_out=true
      stop_seat_tree "$watchdog_pid" "$watchdog_known"
      watchdog_known=$STOPPED_DESCENDANTS
      break
    fi
    sleep 0.1
  done
  if wait "$watchdog_pid" 2>/dev/null; then
    watchdog_rc=0
  else
    watchdog_rc=$?
  fi
  collect_descendants "$watchdog_pid" "$watchdog_known" || true
  watchdog_known=$COLLECTED_DESCENDANTS
  watchdog_survivor=false
  if /bin/kill -0 "-$watchdog_pid" 2>/dev/null; then
    watchdog_survivor=true
  fi
  for watchdog_child in $watchdog_known; do
    if kill -0 "$watchdog_child" 2>/dev/null; then
      watchdog_survivor=true
      break
    fi
  done
  if [ -n "$watchdog_known" ] || [ "$watchdog_survivor" = true ]; then
    stop_seat_tree "$watchdog_pid" "$watchdog_known"
  fi
  if [ "$watchdog_timed_out" = true ]; then
    printf '%s\n' "review: seat timed out after ${watchdog_timeout}s" >> "$watchdog_log"
    return 124
  fi
  if [ "$watchdog_survivor" = true ]; then
    printf '%s\n' 'review: seat left a descendant after adapter exit' >> "$watchdog_log"
    return 125
  fi
  return "$watchdog_rc"
}

generate_manifest() {
  manifest_lane=$1
  manifest_evidence="$manifest_lane/evidence"
  manifest_target="$manifest_evidence/manifest.json"
  [ -d "$manifest_evidence" ] && [ ! -L "$manifest_evidence" ] || return 1
  if [ -L "$manifest_target" ] ||
    { [ -e "$manifest_target" ] && [ ! -f "$manifest_target" ]; }; then
    return 1
  fi
  manifest_tmp_dir=$(mktemp -d "$manifest_lane/.review-manifest.XXXXXX") || return 1
  [ -d "$manifest_tmp_dir" ] && [ ! -L "$manifest_tmp_dir" ] || return 1
  manifest_paths="$manifest_tmp_dir/paths"
  manifest_entries="$manifest_tmp_dir/entries.jsonl"
  manifest_tmp="$manifest_tmp_dir/manifest.json"
  manifest_symlinks="$manifest_tmp_dir/symlinks"
  if ! find "$manifest_evidence" -type l -print > "$manifest_symlinks" ||
    [ -s "$manifest_symlinks" ]; then
    rm -f "$manifest_symlinks"
    rmdir "$manifest_tmp_dir" 2>/dev/null || true
    return 1
  fi
  if ! find "$manifest_evidence" -type f \
    ! -path "$manifest_target" -print |
    LC_ALL=C sort > "$manifest_paths"; then
    rm -f "$manifest_symlinks" "$manifest_paths"
    rmdir "$manifest_tmp_dir" 2>/dev/null || true
    return 1
  fi
  : > "$manifest_entries"
  manifest_failed=false
  while IFS= read -r manifest_file || [ -n "$manifest_file" ]; do
    if [ ! -f "$manifest_file" ] || [ -L "$manifest_file" ]; then
      manifest_failed=true
      break
    fi
    manifest_ref=${manifest_file#"$manifest_lane/"}
    manifest_sha=$(shasum -a 256 "$manifest_file" | awk '{print $1}') || {
      manifest_failed=true
      break
    }
    manifest_bytes=$(wc -c < "$manifest_file" | tr -d '[:space:]') || {
      manifest_failed=true
      break
    }
    if ! jq -n -c \
      --arg ref "$manifest_ref" \
      --arg sha256 "$manifest_sha" \
      --argjson bytes "$manifest_bytes" \
      '{ref:$ref,sha256:$sha256,bytes:$bytes}' >> "$manifest_entries"; then
      manifest_failed=true
      break
    fi
  done < "$manifest_paths"
  if [ "$manifest_failed" = true ] ||
    ! jq -s '{files:(map({key:.ref,value:{sha256:.sha256,bytes:.bytes}})|from_entries)}' \
      "$manifest_entries" > "$manifest_tmp" ||
    ! mv "$manifest_tmp" "$manifest_target"; then
    rm -f "$manifest_symlinks" "$manifest_paths" "$manifest_entries" "$manifest_tmp"
    rmdir "$manifest_tmp_dir" 2>/dev/null || true
    return 1
  fi
  rm -f "$manifest_symlinks" "$manifest_paths" "$manifest_entries"
  rmdir "$manifest_tmp_dir" 2>/dev/null || return 1
}

publish_findings() {
  findings_target="$LANE_DIR/findings.jsonl"
  if [ -L "$findings_target" ] ||
    { [ -e "$findings_target" ] && [ ! -f "$findings_target" ]; }; then
    log 'unsafe findings publication target refused'
    return 1
  fi
  findings_tmp_dir=$(mktemp -d "$LANE_DIR/.review-findings.XXXXXX") || return 1
  findings_tmp="$findings_tmp_dir/findings.jsonl"
  if [ -n "$FINDINGS_BUFFER" ]; then
    if ! printf '%s\n' "$FINDINGS_BUFFER" > "$findings_tmp"; then
      rm -f "$findings_tmp"
      rmdir "$findings_tmp_dir" 2>/dev/null || true
      return 1
    fi
  else
    if ! : > "$findings_tmp"; then
      rm -f "$findings_tmp"
      rmdir "$findings_tmp_dir" 2>/dev/null || true
      return 1
    fi
  fi
  if ! mv "$findings_tmp" "$findings_target"; then
    rm -f "$findings_tmp"
    rmdir "$findings_tmp_dir" 2>/dev/null || true
    return 1
  fi
  rmdir "$findings_tmp_dir" 2>/dev/null || return 1
}

lane_runtime_paths_are_safe() {
  for runtime_path in \
    "$LANE_DIR/home" \
    "$LANE_DIR/tmp" \
    "$LANE_DIR/work" \
    "$LANE_DIR/work/review-seats" \
    "$LANE_DIR/work/review-homes" \
    "$LANE_DIR/evidence" \
    "$LANE_DIR/work/review-checkout"; do
    [ -d "$runtime_path" ] && [ ! -L "$runtime_path" ] || return 1
  done
}

validate_run_config() {
  case "$LANE_DIR" in /*) ;; *) log 'LANE_DIR must be absolute'; return 1 ;; esac
  [ -d "$LANE_DIR" ] && [ ! -L "$LANE_DIR" ] || {
    log 'LANE_DIR must be an existing non-symlink directory'
    return 1
  }
  lane_canonical=$(cd -P "$LANE_DIR" && pwd -P)
  [ "$lane_canonical" = "$LANE_DIR" ] || {
    log 'LANE_DIR must be canonical'
    return 1
  }
  [ -n "$NIGHT_ID" ] || { log 'NIGHT_ID is required'; return 1; }
  case "$target_source_path" in /*) ;; *) log 'REVIEW_TARGET_SOURCE must be absolute'; return 1 ;; esac
  [ -d "$target_source_path" ] || { log 'REVIEW_TARGET_SOURCE is not a directory'; return 1; }
  git -C "$target_source_path" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    log 'REVIEW_TARGET_SOURCE is not a git checkout'
    return 1
  }
  case "$REVIEW_SEAT_TIMEOUT_SEC" in ''|*[!0-9]*) log 'REVIEW_SEAT_TIMEOUT_SEC must be a positive integer'; return 1 ;; esac
  [ "$REVIEW_SEAT_TIMEOUT_SEC" -gt 0 ] || { log 'REVIEW_SEAT_TIMEOUT_SEC must be positive'; return 1; }
  case "$REVIEW_SEATS_PER_NIGHT" in ''|*[!0-9]*) log 'REVIEW_SEATS_PER_NIGHT must be an integer'; return 1 ;; esac
  [ "$REVIEW_SEATS_PER_NIGHT" -gt 0 ] || { log 'REVIEW_SEATS_PER_NIGHT must be positive'; return 1; }
  [ -n "$REVIEW_SEAT_ROSTER" ] || { log 'REVIEW_SEAT_ROSTER is required'; return 1; }
}

prepare_run_dirs() {
  for run_parent in \
    "$LANE_DIR/work" \
    "$LANE_DIR/evidence" \
    "$LANE_DIR/tmp" \
    "$LANE_DIR/home"; do
    if [ -L "$run_parent" ] || { [ -e "$run_parent" ] && [ ! -d "$run_parent" ]; }; then
      log "unsafe lane output parent refused: $run_parent"
      return 1
    fi
  done
  checkout_path="$LANE_DIR/work/review-checkout"
  if [ -d "$checkout_path" ] && [ ! -L "$checkout_path" ]; then
    chmod -R u+w "$checkout_path" 2>/dev/null || true
  fi
  rm -rf "$checkout_path" "$LANE_DIR/work/review-seats" \
    "$LANE_DIR/work/review-homes" "$LANE_DIR/evidence"
  rm -f "$LANE_DIR/findings.jsonl"
  mkdir -p \
    "$LANE_DIR/work/review-seats" \
    "$LANE_DIR/work/review-homes" \
    "$LANE_DIR/evidence" \
    "$LANE_DIR/tmp" \
    "$LANE_DIR/home"
  EVIDENCE_LOG="$LANE_DIR/evidence/run.log"
  exec 4> "$EVIDENCE_LOG"
  EVIDENCE_FD_OPEN=true
  FINDINGS_BUFFER=
  SEEN_FINDING_IDS='|'
}

prepare_seat_home() {
  seat_home_seat=$1
  seat_home_root="$LANE_DIR/work/review-homes"
  seat_home="$seat_home_root/$seat_home_seat"
  [ -d "$seat_home_root" ] && [ ! -L "$seat_home_root" ] || return 1
  [ ! -e "$seat_home" ] && [ ! -L "$seat_home" ] || return 1
  mkdir "$seat_home" || return 1
  case "$seat_home_seat" in
    codex) seat_auth_name=.codex ;;
    kimi) seat_auth_name=.kimi-code ;;
    grok) seat_auth_name=.grok ;;
    opus) seat_auth_name=.claude ;;
    glm) seat_auth_name= ;;
    *) return 1 ;;
  esac
  if [ -n "$seat_auth_name" ] && [ -L "$LANE_DIR/home/$seat_auth_name" ]; then
    seat_auth_target=$(readlink "$LANE_DIR/home/$seat_auth_name") || return 1
    [ -n "$seat_auth_target" ] || return 1
    case "$seat_auth_target" in
      /*) ;;
      *) seat_auth_target="$LANE_DIR/home/$seat_auth_target" ;;
    esac
    ln -s "$seat_auth_target" "$seat_home/$seat_auth_name" || return 1
  fi
  SEAT_HOME=$seat_home
}

run_lane() {
  LANE_DIR=${LANE_DIR:?LANE_DIR is required}
  NIGHT_ID=${NIGHT_ID:?NIGHT_ID is required}
  target_source_path=${REVIEW_TARGET_SOURCE:?REVIEW_TARGET_SOURCE is required}
  unset REVIEW_TARGET_SOURCE
  REVIEW_SEAT_ROSTER=${REVIEW_SEAT_ROSTER-}
  REVIEW_SEATS_PER_NIGHT=${REVIEW_SEATS_PER_NIGHT:-3}
  REVIEW_SEAT_TIMEOUT_SEC=${REVIEW_SEAT_TIMEOUT_SEC:-900}
  REVIEW_OPUS_ENABLED=${REVIEW_OPUS_ENABLED:-0}
  REVIEW_CODEX_BIN=${REVIEW_CODEX_BIN:-codex}
  REVIEW_KIMI_BIN=${REVIEW_KIMI_BIN:-"$HOME/.kimi-code/bin/kimi"}
  REVIEW_GROK_BIN=${REVIEW_GROK_BIN:-"$HOME/.grok/bin/grok"}
  REVIEW_CURL_BIN=${REVIEW_CURL_BIN:-/usr/bin/curl}
  claude_bin_path=${REVIEW_CLAUDE_BIN:-"$HOME/.claude/local/claude"}
  claude_config_path=${REVIEW_CLAUDE_CONFIG_DIR:-"$HOME/.claude"}
  unset REVIEW_CLAUDE_BIN REVIEW_CLAUDE_CONFIG_DIR
  glm_key_file_path=${GLM_KEY_FILE:-}
  unset GLM_KEY_FILE
  REVIEW_GLM_MAX_TOKENS=${REVIEW_GLM_MAX_TOKENS:-4096}

  validate_run_config || return 1
  prepare_run_dirs || return 1
  selection_dir="$LANE_DIR/work/review-seats"
  select_assignment "$NIGHT_ID" "$REVIEW_SEAT_ROSTER" "$REVIEW_SEATS_PER_NIGHT" \
    "$REVIEW_OPUS_ENABLED" "$selection_dir" || {
    log 'invalid REVIEW_SEAT_ROSTER or selection configuration'
    generate_manifest "$LANE_DIR" || true
    return 1
  }

  checkout="$LANE_DIR/work/review-checkout"
  if ! git clone --no-hardlinks "$target_source_path" "$checkout" >&4 2>&1; then
    log 'git clone failed'
    generate_manifest "$LANE_DIR" || true
    return 1
  fi
  if ! commit=$(git -C "$checkout" rev-parse HEAD); then
    log 'cloned checkout has no readable commit'
    generate_manifest "$LANE_DIR" || true
    return 1
  fi
  if ! commit_short=$(git -C "$checkout" rev-parse --short=12 HEAD); then
    log 'cloned checkout commit could not be abbreviated'
    generate_manifest "$LANE_DIR" || true
    return 1
  fi
  if ! git -C "$checkout" remote remove origin 2>/dev/null; then
    log 'cloned checkout origin could not be removed'
    generate_manifest "$LANE_DIR" || true
    return 1
  fi
  if ! git -C "$checkout" config core.logAllRefUpdates false; then
    log 'cloned checkout reflog updates could not be disabled'
    generate_manifest "$LANE_DIR" || true
    return 1
  fi
  rm -rf "$checkout/.git/logs"
  if [ -n "$(git -C "$checkout" remote)" ] ||
    [ -e "$checkout/.git/objects/info/alternates" ] ||
    [ -L "$checkout/.git/objects/info/alternates" ]; then
    log 'cloned checkout retained a remote or object alternate'
    generate_manifest "$LANE_DIR" || true
    return 1
  fi
  source_path_scan_rc=0
  grep -R -F -- "$target_source_path" "$checkout/.git" >/dev/null 2>&1 ||
    source_path_scan_rc=$?
  case "$source_path_scan_rc" in
    0)
      log 'cloned checkout retained the source checkout path'
      generate_manifest "$LANE_DIR" || true
      return 1
      ;;
    1) ;;
    *)
      log 'cloned checkout source-path scan failed'
      generate_manifest "$LANE_DIR" || true
      return 1
      ;;
  esac
  repo_name=$(basename "$target_source_path")
  chmod -R a-w "$checkout"
  if ! checkout_fingerprint=$(checkout_tree_fingerprint "$checkout"); then
    log 'cloned checkout could not be fingerprinted'
    generate_manifest "$LANE_DIR" || true
    return 1
  fi

  old_ifs=$IFS
  IFS=$'\t'
  read -r lens_name lens_slug lens_guidance <<EOF
$SELECTED_LENS_RECORD
EOF
  IFS=$old_ifs
  log "commit=$commit"
  announce "lens=$lens_name lens_slug=$lens_slug hash=$SELECTED_HASH"
  announce "seats=$SELECTED_SEATS combinations=$SELECTED_COMBO_COUNT hash=$SELECTED_SEATS_HASH"

  successful_adapters=0
  infrastructure_failed=false
  for seat in $SELECTED_SEATS; do
    seat_dir="$LANE_DIR/work/review-seats/$seat"
    if ! lane_runtime_paths_are_safe || [ -e "$seat_dir" ] || [ -L "$seat_dir" ]; then
      log "seat=$seat unsafe runtime path before adapter launch"
      infrastructure_failed=true
      break
    fi
    if ! mkdir "$seat_dir"; then
      log "seat=$seat output directory could not be created"
      infrastructure_failed=true
      break
    fi
    if ! prepare_seat_home "$seat"; then
      log "seat=$seat isolated HOME could not be prepared"
      infrastructure_failed=true
      break
    fi
    candidate_path="$seat_dir/candidates.jsonl"
    prompt_path="$seat_dir/prompt.md"
    seat_log="$LANE_DIR/evidence/seat-$seat.log"
    adapter="$ADAPTER_ROOT/$seat.sh"
    if [ -L "$seat_log" ] || { [ -e "$seat_log" ] && [ ! -f "$seat_log" ]; }; then
      log "seat=$seat unsafe transcript path before adapter launch"
      infrastructure_failed=true
      break
    fi
    digest_path=
    if [ "$seat" = glm ]; then
      digest_path="$seat_dir/repo-digest.txt"
      if ! make_repo_digest "$checkout" "$lens_name" "$digest_path"; then
        log "seat=$seat repository digest failed"
        infrastructure_failed=true
        break
      fi
    fi
    if ! render_prompt "$lens_name" "$lens_guidance" "$commit" \
      "$candidate_path" "$digest_path" > "$prompt_path"; then
      log "seat=$seat prompt rendering failed"
      infrastructure_failed=true
      break
    fi
    seat_rc=0
    case "$seat" in
      codex)
        run_with_watchdog "$REVIEW_SEAT_TIMEOUT_SEC" "$seat_log" \
          /usr/bin/env -i PATH="$PATH" HOME="$SEAT_HOME" \
            TMPDIR="$LANE_DIR/tmp" LANG="${LANG:-C}" TERM=dumb \
            REVIEW_CODEX_BIN="$REVIEW_CODEX_BIN" \
            /bin/bash "$adapter" "$prompt_path" "$checkout" "$seat_dir" || seat_rc=$?
        ;;
      kimi)
        run_with_watchdog "$REVIEW_SEAT_TIMEOUT_SEC" "$seat_log" \
          /usr/bin/env -i PATH="$PATH" HOME="$SEAT_HOME" \
            TMPDIR="$LANE_DIR/tmp" LANG="${LANG:-C}" TERM=dumb \
            REVIEW_KIMI_BIN="$REVIEW_KIMI_BIN" \
            /bin/bash "$adapter" "$prompt_path" "$checkout" "$seat_dir" || seat_rc=$?
        ;;
      glm)
        run_with_watchdog "$REVIEW_SEAT_TIMEOUT_SEC" "$seat_log" \
          /usr/bin/env -i PATH="$PATH" HOME="$SEAT_HOME" \
            TMPDIR="$LANE_DIR/tmp" LANG="${LANG:-C}" TERM=dumb \
            GLM_KEY_FILE="$glm_key_file_path" \
            REVIEW_GLM_MAX_TOKENS="$REVIEW_GLM_MAX_TOKENS" \
            REVIEW_CURL_BIN="$REVIEW_CURL_BIN" \
            /bin/bash "$adapter" "$prompt_path" "$checkout" "$seat_dir" || seat_rc=$?
        ;;
      grok)
        run_with_watchdog "$REVIEW_SEAT_TIMEOUT_SEC" "$seat_log" \
          /usr/bin/env -i PATH="$PATH" HOME="$SEAT_HOME" \
            TMPDIR="$LANE_DIR/tmp" LANG="${LANG:-C}" TERM=dumb \
            REVIEW_GROK_BIN="$REVIEW_GROK_BIN" \
            /bin/bash "$adapter" "$prompt_path" "$checkout" "$seat_dir" || seat_rc=$?
        ;;
      opus)
        run_with_watchdog "$REVIEW_SEAT_TIMEOUT_SEC" "$seat_log" \
          /usr/bin/env -i PATH="$PATH" HOME="$SEAT_HOME" \
            TMPDIR="$LANE_DIR/tmp" LANG="${LANG:-C}" TERM=dumb \
            REVIEW_CLAUDE_BIN="$claude_bin_path" \
            REVIEW_OPUS_ENABLED="$REVIEW_OPUS_ENABLED" \
            REVIEW_CLAUDE_CONFIG_DIR="$claude_config_path" \
            /bin/bash "$adapter" "$prompt_path" "$checkout" "$seat_dir" || seat_rc=$?
        ;;
      *) seat_rc=2 ;;
    esac
    if ! lane_runtime_paths_are_safe ||
      [ ! -d "$seat_dir" ] || [ -L "$seat_dir" ] ||
      [ ! -f "$seat_log" ] || [ -L "$seat_log" ]; then
      log "seat=$seat unsafe runtime path after adapter exit"
      infrastructure_failed=true
      break
    fi
    if ! current_fingerprint=$(checkout_tree_fingerprint "$checkout"); then
      current_fingerprint=inspection-failed
    fi
    if ! checkout_status=$(git -c core.fsmonitor=false -C "$checkout" \
      status --porcelain --untracked-files=all 2>/dev/null); then
      checkout_status=inspection-failed
    fi
    current_head=$(git -C "$checkout" rev-parse HEAD 2>/dev/null) || current_head=
    if [ "$current_fingerprint" != "$checkout_fingerprint" ] ||
      [ "$current_head" != "$commit" ] ||
      ! git -C "$checkout" diff --no-ext-diff --no-textconv --quiet "$commit" -- ||
      ! git -C "$checkout" diff --no-ext-diff --no-textconv --quiet ||
      ! git -C "$checkout" diff --no-ext-diff --no-textconv --cached --quiet ||
      [ -n "$checkout_status" ]; then
      log "seat=$seat modified the read-only checkout; failing closed"
      infrastructure_failed=true
      break
    fi
    if [ "$seat_rc" -ne 0 ]; then
      log "seat=$seat status=failed exit=$seat_rc"
      continue
    fi
    successful_adapters=$((successful_adapters + 1))

    if [ ! -e "$candidate_path" ]; then
      : > "$candidate_path"
    fi
    if [ ! -f "$candidate_path" ] || [ -L "$candidate_path" ]; then
      log "seat=$seat candidate output is not a regular file"
      continue
    fi
    if ! candidate_probe_bytes=$(head -c 65537 "$candidate_path" |
      wc -c | tr -d '[:space:]'); then
      log "seat=$seat rejected unreadable candidate output"
      continue
    fi
    if [ "$candidate_probe_bytes" -gt 65536 ]; then
      log "seat=$seat rejected candidate output larger than 65536 bytes"
      continue
    fi
    candidate_count=0
    accepted_sequence=1
    accepted_count=0
    while IFS= read -r candidate_line || [ -n "$candidate_line" ]; do
      [ -n "$candidate_line" ] || {
        log "seat=$seat rejected blank JSONL line"
        continue
      }
      candidate_count=$((candidate_count + 1))
      if [ "$candidate_count" -gt 5 ]; then
        log "seat=$seat rejected candidate beyond five-line maximum"
        break
      fi
      if normalized=$(candidate_normalize "$candidate_line" "$seat" "$lens_slug" \
        "$commit_short" "$repo_name" "$NIGHT_ID" "$accepted_sequence"); then
        normalized_id=$(printf '%s\n' "$normalized" | jq -r '.id')
        case "$SEEN_FINDING_IDS" in
          *"|$normalized_id|"*)
            log "seat=$seat skipped duplicate finding id=$normalized_id"
            ;;
          *)
            SEEN_FINDING_IDS="$SEEN_FINDING_IDS$normalized_id|"
            if [ -n "$FINDINGS_BUFFER" ]; then
              FINDINGS_BUFFER="$FINDINGS_BUFFER
$normalized"
            else
              FINDINGS_BUFFER=$normalized
            fi
            accepted_count=$((accepted_count + 1))
            ;;
        esac
        accepted_sequence=$((accepted_sequence + 1))
      else
        log "seat=$seat rejected malformed or unsafe candidate line=$candidate_count"
      fi
    done < "$candidate_path"
    log "seat=$seat status=ok candidates=$accepted_count"
  done

  final_rc=0
  if [ "$infrastructure_failed" = true ] || [ "$successful_adapters" -eq 0 ]; then
    final_rc=1
  fi
  publish_findings || final_rc=1
  exec 4>&-
  EVIDENCE_FD_OPEN=false
  generate_manifest "$LANE_DIR" || return 1
  return "$final_rc"
}

case "${1:-run}" in
  run) run_lane ;;
  select)
    [ "$#" -eq 5 ] || exit 2
    LANE_DIR=${LANE_DIR:?LANE_DIR is required for select}
    case "$LANE_DIR" in /*) ;; *) exit 2 ;; esac
    [ -d "$LANE_DIR" ] && [ ! -L "$LANE_DIR" ] || exit 2
    [ "$(cd -P "$LANE_DIR" && pwd -P)" = "$LANE_DIR" ] || exit 2
    selection_tmp=$(mktemp -d "$LANE_DIR/.review-select.XXXXXX")
    trap 'rm -rf "$selection_tmp"' EXIT
    select_assignment "$2" "$3" "$4" "$5" "$selection_tmp"
    old_ifs=$IFS
    IFS=$'\t'
    read -r selected_lens selected_lens_slug _ <<EOF
$SELECTED_LENS_RECORD
EOF
    IFS=$old_ifs
    jq -n --arg lens "$selected_lens" --arg lens_slug "$selected_lens_slug" --arg seats "$SELECTED_SEATS" \
      --argjson hash "$SELECTED_HASH" --argjson seat_hash "$SELECTED_SEATS_HASH" \
      '{lens:$lens,lens_slug:$lens_slug,seats:($seats|split(" ")),hash:$hash,seat_hash:$seat_hash}'
    ;;
  validate-candidate)
    [ "$#" -eq 7 ] || exit 2
    validation_line=$(sed -n '1p')
    candidate_normalize "$validation_line" "$2" "$3" "$4" "$5" "$6" "$7"
    ;;
  *)
    printf '%s\n' "Usage: $0 {run|select NIGHT_ID ROSTER COUNT OPUS_ENABLED|validate-candidate SEAT LENS_SLUG COMMIT REPO NIGHT_ID SEQ}" >&2
    exit 2
    ;;
esac
