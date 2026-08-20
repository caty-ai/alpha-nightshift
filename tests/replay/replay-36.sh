#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
GROUND_TRUTH="$SCRIPT_DIR/fixtures/ground-truth-36.jsonl"
MORNING_TRIAGE="$REPO_ROOT/bin/morning-triage"
VERDICT_SYNC="$REPO_ROOT/bin/verdict-sync"
PIN_SHA=b7e1be1
DEFERRED_CANONICAL=rv-ui-ux-accessibility-codex-cd110543906e-ddec4b83
ISSUE_36_REF='issues/36"'

usage() {
  cat >&2 <<'USAGE'
Usage: tests/replay/replay-36.sh [--record|--replay] [--cache-dir <abs>] [--keep-workdir]

Environment overrides:
  REPLAY_SOURCE_LEDGER  Absolute path to the production ledger snapshot.
  REPLAY_PINNED_CLONE   Required history-preserving caty-agent-harness clone at b7e1be1.
  TRIAGE_REPLAY_ADAPTER Adapter used for cache misses in --record mode.
  TRIAGE_LLM_CACHE_DIR  Cache directory (same meaning as --cache-dir).
USAGE
}

replay_mode=record
keep_workdir=false
cache_dir=${TRIAGE_LLM_CACHE_DIR:-}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --record)
      replay_mode=record
      shift
      ;;
    --replay)
      replay_mode=replay
      shift
      ;;
    --cache-dir)
      [ "$#" -ge 2 ] || {
        usage
        exit 2
      }
      cache_dir=$2
      shift 2
      ;;
    --keep-workdir)
      keep_workdir=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

case "$cache_dir" in
  '') cache_dir="${TMPDIR:-/tmp}/alpha-nightshift-triage-llm-cache" ;;
  /*) ;;
  *)
    printf 'replay-36: cache directory must be absolute\n' >&2
    exit 2
    ;;
esac

main_worktree=$(git -C "$REPO_ROOT" worktree list --porcelain |
  awk '
    $1 == "worktree" { path = $2 }
    $1 == "branch" && $2 == "refs/heads/main" { print path; exit }
  ')
source_ledger=${REPLAY_SOURCE_LEDGER:-"$main_worktree/state/ledger/ledger.jsonl"}
pinned_clone=${REPLAY_PINNED_CLONE:-}
[ -n "$pinned_clone" ] || {
  printf 'replay-36: REPLAY_PINNED_CLONE is required\n' >&2
  exit 2
}

for replay_required in "$GROUND_TRUTH" "$source_ledger" "$MORNING_TRIAGE" "$VERDICT_SYNC"; do
  [ -f "$replay_required" ] && [ -r "$replay_required" ] || {
    printf 'replay-36: required file is unavailable: %s\n' "$replay_required" >&2
    exit 1
  }
done
[ -x "$MORNING_TRIAGE" ] || {
  printf 'replay-36: morning-triage is not executable\n' >&2
  exit 1
}
[ -x "$VERDICT_SYNC" ] || {
  printf 'replay-36: verdict-sync is not executable\n' >&2
  exit 1
}
if [ -d "$pinned_clone/.git" ] || [ -f "$pinned_clone/.git" ]; then
  pinned_head=$(git -C "$pinned_clone" rev-parse --short=7 HEAD)
  [ "$pinned_head" = "$PIN_SHA" ] || {
    printf 'replay-36: pinned clone is at %s, expected %s\n' \
      "$pinned_head" "$PIN_SHA" >&2
    exit 1
  }
  repo_pin="caty-agent-harness=$PIN_SHA@$pinned_clone"
else
  repo_pin="caty-agent-harness=$PIN_SHA"
fi

replay_root=$(mktemp -d "${TMPDIR:-/tmp}/morning-triage-replay-36.XXXXXX")
ground_truth_hash=$(shasum -a 256 "$GROUND_TRUTH" | awk '{print $1}')
cleanup() {
  replay_status=$?
  replay_hash_after=$(shasum -a 256 "$GROUND_TRUTH" | awk '{print $1}')
  if [ "$ground_truth_hash" != "$replay_hash_after" ]; then
    printf 'replay-36: immutable ground truth changed during replay\n' >&2
    replay_status=1
  fi
  if [ "$keep_workdir" = true ]; then
    printf 'replay-36: retained workdir %s\n' "$replay_root" >&2
  else
    rm -rf "$replay_root"
  fi
  exit "$replay_status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$cache_dir"
fail_adapter="$replay_root/cache-miss-adapter"
cat > "$fail_adapter" <<'ADAPTER'
#!/bin/bash
printf 'replay-36: unexpected adapter call (LLM cache miss)\n' >&2
exit 97
ADAPTER
chmod +x "$fail_adapter"

settled_adapter="$replay_root/settled-deterministic-adapter"
cat > "$settled_adapter" <<'ADAPTER'
#!/bin/bash
set -euo pipefail
[ "$#" -eq 3 ] || exit 2
prompt_file=$1
out_dir=$3
if grep -F '# 重複判定タスク' "$prompt_file" >/dev/null 2>&1; then
  [ -f "$TRIAGE_SETTLED_DEDUP_FIXTURE" ] || exit 2
  target_json="$out_dir/settled-targets.json"
  awk '
    /^## 判定対象 findings$/ { capture=1; next }
    /^## 出力契約$/ { capture=0 }
    capture { print }
  ' "$prompt_file" > "$target_json"
  jq -c --slurpfile targets "$target_json" '
    .finding_id as $id |
    select(any($targets[0][]; .id == $id))
  ' "$TRIAGE_SETTLED_DEDUP_FIXTURE"
  exit 0
fi
exec "$TRIAGE_SETTLED_FALLBACK_ADAPTER" "$@"
ADAPTER
chmod +x "$settled_adapter"

record_adapter=${TRIAGE_REPLAY_ADAPTER:-${TRIAGE_ADAPTER:-"$REPO_ROOT/lanes/review/adapters/codex.sh"}}
case "$record_adapter" in
  /*) ;;
  *) record_adapter="$REPO_ROOT/$record_adapter" ;;
esac
if [ "$replay_mode" = record ]; then
  [ -x "$record_adapter" ] || {
    printf 'replay-36: record adapter is not executable: %s\n' \
      "$record_adapter" >&2
    exit 1
  }
else
  record_adapter=$fail_adapter
fi

write_replay_config() {
  replay_config=$1
  replay_already_fixed_mode=$2
  cat > "$replay_config" <<'CONFIG'
TRIAGE_ENABLED=1
TRIAGE_MAX_VERIFY_PER_RUN=1000
TRIAGE_REVERIFY_INTERVAL_DAYS=0
TRIAGE_MAX_NEW_FOR_DEDUP=1000
TRIAGE_VERIFY_BATCH=5
TRIAGE_DEDUP_BATCH=10
TRIAGE_CONCURRENCY=3
TRIAGE_LLM_TIMEOUT_SEC=900
TRIAGE_PHASE_A_DEADLINE_SEC=7200
TRIAGE_HARD_WALL=23:59
TRIAGE_DEDUP_POOL_MAX=1000
TRIAGE_TARGET_REPOS='caty-agent-harness=shojikumaru/caty-agent-harness'
TRIAGE_REPORT_ISSUE=37
CONFIG
  printf 'TRIAGE_ALREADY_FIXED_MODE=%s\n' "$replay_already_fixed_mode" >> \
    "$replay_config"
}

project_ledger() {
  replay_state=$1
  (
    # REPO_ROOT is canonicalized at startup; ShellCheck cannot resolve it.
    # shellcheck disable=SC1091
    . "$REPO_ROOT/lib/common.sh"
    NIGHTSHIFT_CONFIG=/dev/null nightshift_init "$REPO_ROOT"
    STATE_DIR=$replay_state
    export STATE_DIR
    # REPO_ROOT is canonicalized at startup; ShellCheck cannot resolve it.
    # shellcheck disable=SC1091
    . "$REPO_ROOT/lib/ledger.sh"
    ledger_project_findings
  )
}

build_open_ledger() {
  replay_state=$1
  mkdir -p "$replay_state/ledger"
  grep -v "$ISSUE_36_REF" "$source_ledger" > \
    "$replay_state/ledger/ledger.jsonl"
}

build_settled_ledger() {
  replay_state=$1
  mkdir -p "$replay_state/ledger"
  jq -c --slurpfile truth "$GROUND_TRUTH" \
    --arg issue_ref 'https://github.com/caty-ai/alpha-nightshift/issues/36' '
      ([
        $truth[] |
        select(.human_canonical != null) |
        .human_canonical
      ] | unique) as $canonical_ids |
      select(
        .type != "verdict" or
        .source_ref != $issue_ref or
        (.finding_id as $id | $canonical_ids | index($id)) != null
      )
    ' "$source_ledger" > "$replay_state/ledger/ledger.jsonl"
}

run_triage() {
  replay_state=$1
  replay_config=$2
  replay_adapter=$3
  replay_cache=$4
  replay_settled_fixture=${5:-}
  replay_fallback_adapter=${6:-}
  env \
    NIGHTSHIFT_CONFIG="$replay_config" \
    TRIAGE_ADAPTER="$replay_adapter" \
    TRIAGE_LLM_CACHE_DIR="$replay_cache" \
    TRIAGE_SETTLED_DEDUP_FIXTURE="$replay_settled_fixture" \
    TRIAGE_SETTLED_FALLBACK_ADAPTER="$replay_fallback_adapter" \
    "$MORNING_TRIAGE" --dry-run --force --state-dir "$replay_state" \
      --repo-pin "$repo_pin"
}

build_g6_dedup_fixture() {
  replay_fixture=$1
  jq -c '
    select(.human_class == "duplicate" or .human_class == "superseded") |
    {
      finding_id,
      verdict: "DUPLICATE",
      canonical_id: .human_canonical,
      confidence: "high",
      shared_defect: "replayed from ground truth"
    }
  ' "$GROUND_TRUTH" | jq -s -c 'sort_by(.finding_id)[]' > \
    "$replay_fixture"
  jq -e -s --slurpfile truth "$GROUND_TRUTH" '
    [
      $truth[] |
      select(.human_class == "duplicate" or .human_class == "superseded") |
      .finding_id
    ] as $expected |
    length == 15 and
    ([.[].finding_id] | sort) == ($expected | sort) and
    all(.[];
      .verdict == "DUPLICATE" and
      .confidence == "high" and
      (.canonical_id | type == "string" and length > 0) and
      (.shared_defect | type == "string" and length > 0)
    )
  ' "$replay_fixture" >/dev/null
}

require_artifacts() {
  replay_state=$1
  for replay_artifact in \
    "$replay_state/triage/decisions.draft.jsonl" \
    "$replay_state/triage/report.md" \
    "$replay_state/triage/clusters.jsonl" \
    "$replay_state/triage/verify-results.jsonl"; do
    [ -f "$replay_artifact" ] && [ -r "$replay_artifact" ] || {
      printf 'replay-36: missing replay artifact: %s\n' \
        "$replay_artifact" >&2
      return 1
    }
  done
}

gate_g0() {
  replay_state=$1
  replay_projection=$2
  project_ledger "$replay_state" > "$replay_projection"
  jq -e -s --slurpfile truth "$GROUND_TRUTH" '
    ([.[] | select(.current_status == "open")] | length) == 46 and
    ([.[] | select(.current_status == "open") | .id] | sort) ==
      ([$truth[].finding_id] | sort)
  ' "$replay_projection" >/dev/null
}

gate_g1() {
  replay_decisions=$1
  jq -e -s --slurpfile truth "$GROUND_TRUTH" '
    . as $decisions |
    [$truth[] | select(.human_class == "adopted") | .finding_id] as $adopted |
    all($decisions[]; (.finding_id as $id | $adopted | index($id)) == null)
  ' "$replay_decisions" >/dev/null
}

gate_g2_g3() {
  replay_clusters=$1
  replay_verify_results=$2
  jq -e -s --slurpfile truth "$GROUND_TRUTH" \
    --slurpfile verify "$replay_verify_results" '
      def root($id):
        (first(
          $truth[] |
          select(.finding_id == $id) |
          (.human_canonical // .finding_id)
        ) // $id);
      def member_id:
        if type == "string" then .
        elif type == "object" then (.finding_id // .id // null)
        else null
        end;
      def cluster_has($clusters; $id; $wanted_root):
        any($clusters[];
          (.complete == true) and
          (root(.canonical_id) == $wanted_root) and
          any(.members[]?; member_id == $id)
        );
      def fixed_has($id):
        any($verify[];
          .finding_id == $id and .verdict == "ALREADY_FIXED"
        );
      . as $clusters |
      all(
        $truth[] |
        select(.human_canonical != null);
        . as $expected |
        (cluster_has($clusters; $expected.finding_id; root($expected.human_canonical))) or
        (($expected.hybrid // false) and fixed_has($expected.finding_id))
      ) and
      all(
        $truth[] |
        select(.human_canonical == null);
        .finding_id as $not_duplicate |
        all($clusters[];
          .canonical_id == $not_duplicate or
          all(.members[]?; member_id != $not_duplicate)
        )
      )
    ' "$replay_clusters" >/dev/null
}

gate_g5() {
  replay_decisions=$1
  replay_verify_results=$2
  jq -e -n --slurpfile truth "$GROUND_TRUTH" \
    --slurpfile decisions "$replay_decisions" \
    --slurpfile verify "$replay_verify_results" '
      [
        $truth[] |
        select(
          .human_class == "already_fixed" or
          (.hybrid // false)
        ) |
        .finding_id
      ] as $allowed |
      all($verify[];
        .verdict != "ALREADY_FIXED" or
        (.finding_id as $id | $allowed | index($id)) != null
      ) and
      all($decisions[];
        (.rejection_reason | startswith("already fixed on main") | not) or
        (.finding_id as $id | $allowed | index($id)) != null
      )
    ' >/dev/null
}

gate_g6_fixture() {
  replay_projection=$1
  jq -e -s --slurpfile truth "$GROUND_TRUTH" \
    --arg deferred "$DEFERRED_CANONICAL" '
      ([
        $truth[] |
        select(.human_canonical != null) |
        .human_canonical
      ] | unique) as $canonical_ids |
      ($canonical_ids | length) == 10 and
      ([
        .[] |
        select(.id as $id | $canonical_ids | index($id)) |
        select(.current_status == "adopted")
      ] | length) == 9 and
      (first(.[] | select(.id == $deferred)) | .current_status) == "rejected" and
      (first(.[] | select(.id == $deferred)) |
        .latest_verdict.rejection_reason | startswith("deferred"))
    ' "$replay_projection" >/dev/null
}

gate_g6_decisions() {
  replay_decisions=$1
  jq -e -s --slurpfile truth "$GROUND_TRUTH" '
    . as $decisions |
    [
      $truth[] |
      select(.human_canonical != null) |
      {finding_id, human_canonical}
    ] as $expected |
    ($expected | length) == 15 and
    ($decisions | length) == 15 and
    all($expected[];
      . as $want |
      any($decisions[];
        .finding_id == $want.finding_id and
        .status == "rejected" and
        .actor == "auto-triage" and
        .source == "manual-comment" and
        (has("source_ref") | not) and
        (.rejection_reason |
          startswith("duplicate of " + $want.human_canonical + " "))
      )
    )
  ' "$replay_decisions" >/dev/null
}

sync_g6_decisions() {
  replay_state=$1
  replay_draft=$2
  replay_decisions=$3
  replay_sync_output=$4
  replay_projection=$5
  jq -c '. + {
    source_ref: "https://github.com/caty-ai/alpha-nightshift/issues/37#replay-36"
  }' "$replay_draft" > "$replay_decisions"

  if ! NIGHTSHIFT_CONFIG=/dev/null NIGHTSHIFT_STATE_DIR="$replay_state" \
    "$VERDICT_SYNC" --input "$replay_decisions" > "$replay_sync_output" 2>&1; then
    cat "$replay_sync_output" >&2
    return 1
  fi
  case $(cat "$replay_sync_output") in
    *'observed=15 appended=15 idempotent=0'*) ;;
    *)
      cat "$replay_sync_output" >&2
      return 1
      ;;
  esac

  project_ledger "$replay_state" > "$replay_projection"
  jq -e -s --slurpfile truth "$GROUND_TRUTH" '
    [
      $truth[] |
      select(.human_canonical != null) |
      .finding_id
    ] as $expected |
    ([
      .[] |
      select(.id as $id | $expected | index($id)) |
      select(
        .current_status == "rejected" and
        .latest_verdict.actor == "auto-triage" and
        .latest_verdict.source == "manual-comment" and
        .latest_verdict.source_ref ==
          "https://github.com/caty-ai/alpha-nightshift/issues/37#replay-36"
      ) |
      .id
    ] | sort) == ($expected | sort)
  ' "$replay_projection" >/dev/null
}

print_metrics() {
  replay_verify_results=$1
  replay_started_at=$2
  replay_finished_at=$(date '+%s')
  jq -n --slurpfile truth "$GROUND_TRUTH" \
    --slurpfile verify "$replay_verify_results" \
    --argjson elapsed "$((replay_finished_at - replay_started_at))" '
      {
        already_fixed_detected: ([
          $verify[] |
          select(.verdict == "ALREADY_FIXED") |
          .finding_id
        ] | unique | length),
        already_fixed_human_total: ([
          $truth[] |
          select(.human_class == "already_fixed")
        ] | length),
        confirmed_current: ([
          $verify[] |
          select(.verdict == "CONFIRMED_CURRENT")
        ] | length),
        verify_results: ($verify | length),
        elapsed_seconds: $elapsed
      }
    '
}

run_full_pass() {
  replay_pass=$1
  replay_adapter=$2
  replay_pass_root="$replay_root/pass-$replay_pass"
  replay_open_state="$replay_pass_root/open-state"
  replay_settled_state="$replay_pass_root/settled-state"
  replay_open_config="$replay_pass_root/open.conf"
  replay_settled_config="$replay_pass_root/settled.conf"
  replay_g6_fixture="$replay_pass_root/g6-dedup-fixture.jsonl"
  replay_started_at=$(date '+%s')
  mkdir -p "$replay_pass_root"
  write_replay_config "$replay_open_config" reject
  write_replay_config "$replay_settled_config" suggest

  build_open_ledger "$replay_open_state"
  gate_g0 "$replay_open_state" "$replay_pass_root/open-projection.jsonl" || {
    printf 'replay-36 pass %s: G0 FAIL\n' "$replay_pass" >&2
    return 1
  }
  printf 'replay-36 pass %s: G0 PASS\n' "$replay_pass"

  run_triage "$replay_open_state" "$replay_open_config" "$replay_adapter" \
    "$cache_dir"
  require_artifacts "$replay_open_state"
  replay_open_triage="$replay_open_state/triage"
  gate_g1 "$replay_open_triage/decisions.draft.jsonl" || {
    printf 'replay-36 pass %s: G1 FAIL\n' "$replay_pass" >&2
    return 1
  }
  printf 'replay-36 pass %s: G1 PASS\n' "$replay_pass"
  gate_g2_g3 \
    "$replay_open_triage/clusters.jsonl" \
    "$replay_open_triage/verify-results.jsonl" || {
    printf 'replay-36 pass %s: G2/G3 FAIL\n' "$replay_pass" >&2
    return 1
  }
  printf 'replay-36 pass %s: G2 PASS\n' "$replay_pass"
  printf 'replay-36 pass %s: G3 PASS\n' "$replay_pass"
  printf 'replay-36 pass %s: G4 (integrated into G2; no separate check)\n' "$replay_pass"
  gate_g5 \
    "$replay_open_triage/decisions.draft.jsonl" \
    "$replay_open_triage/verify-results.jsonl" || {
    printf 'replay-36 pass %s: G5 FAIL\n' "$replay_pass" >&2
    return 1
  }
  printf 'replay-36 pass %s: G5 PASS\n' "$replay_pass"

  build_g6_dedup_fixture "$replay_g6_fixture" || {
    printf 'replay-36 pass %s: G6 deterministic fixture FAIL\n' \
      "$replay_pass" >&2
    return 1
  }

  build_settled_ledger "$replay_settled_state"
  project_ledger "$replay_settled_state" > \
    "$replay_pass_root/settled-before.jsonl"
  gate_g6_fixture "$replay_pass_root/settled-before.jsonl" || {
    printf 'replay-36 pass %s: G6 fixture FAIL\n' "$replay_pass" >&2
    return 1
  }
  printf 'replay-36 pass %s: G6 Stage D replays ground-truth duplicate verdicts deterministically\n' \
    "$replay_pass"
  run_triage "$replay_settled_state" "$replay_settled_config" \
    "$settled_adapter" "$replay_root/g6-deterministic-cache" \
    "$replay_g6_fixture" "$replay_adapter"
  require_artifacts "$replay_settled_state"
  replay_settled_triage="$replay_settled_state/triage"
  gate_g6_decisions "$replay_settled_triage/decisions.draft.jsonl" || {
    printf 'replay-36 pass %s: G6 decisions FAIL\n' "$replay_pass" >&2
    return 1
  }
  sync_g6_decisions \
    "$replay_settled_state" \
    "$replay_settled_triage/decisions.draft.jsonl" \
    "$replay_pass_root/decisions.jsonl" \
    "$replay_pass_root/verdict-sync.out" \
    "$replay_pass_root/settled-after.jsonl" || {
    printf 'replay-36 pass %s: G6 verdict-sync FAIL\n' "$replay_pass" >&2
    return 1
  }
  printf 'replay-36 pass %s: G6 PASS\n' "$replay_pass"
  print_metrics "$replay_open_triage/verify-results.jsonl" "$replay_started_at"
}

run_full_pass 1 "$record_adapter"
# A failing adapter makes the second pass prove that every response came from
# the prompt-sha256 cache, rather than merely repeating another live run.
run_full_pass 2 "$fail_adapter"
printf 'replay-36: cached replay determinism check (not an independence check) succeeded (%s mode)\n' \
  "$replay_mode"
