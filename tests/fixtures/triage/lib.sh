#!/bin/bash
set -euo pipefail

triage_fixture_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

triage_fixture_sha256() {
  printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
}

triage_fake_gh_seed_get() {
  triage_gh_dir=$1
  triage_endpoint=$2
  triage_body=$3
  triage_sha=$(triage_fixture_sha256 "$triage_endpoint")
  mkdir -p "$triage_gh_dir/get"
  printf '%s\n' "$triage_body" > "$triage_gh_dir/get/$triage_sha.json"
}

triage_fake_gh_seed_fail() {
  triage_gh_dir=$1
  triage_method=$2
  triage_endpoint=$3
  triage_status=$4
  triage_body=${5:-}
  triage_sha=$(triage_fixture_sha256 "$triage_endpoint")
  mkdir -p "$triage_gh_dir/fail"
  printf '%s\n' "$triage_status" > \
    "$triage_gh_dir/fail/${triage_method,,}-$triage_sha.status"
  if [ -n "$triage_body" ]; then
    printf '%s\n' "$triage_body" > \
      "$triage_gh_dir/fail/${triage_method,,}-$triage_sha.body"
  fi
}

triage_seed_report_issue() {
  triage_gh_dir=$1
  triage_repo=$2
  triage_issue=$3
  triage_fake_gh_seed_get \
    "$triage_gh_dir" \
    "repos/$triage_repo/issues/$triage_issue" \
    "$(jq -n \
      --argjson number "$triage_issue" \
      --arg repo "$triage_repo" '
        {
          id: ($number + 1000),
          number: $number,
          state: "open",
          title: "auto-triage report sink",
          html_url: ("https://github.test/" + $repo + "/issues/" +
            ($number | tostring)),
          user: {login: "triage-owner"},
          labels: []
        }
      ')"
}

triage_write_config() {
  triage_config=$1
  triage_state=$2
  triage_gh_bin=$3
  triage_extra=${4:-}
  cat > "$triage_config" <<EOF
NIGHTSHIFT_STATE_DIR='$triage_state'
LANE_CMD_1=':'
LANE_HOME_LINKS=''
NIGHT_BOT_LOGIN='night-bot'
VERDICT_GH_BIN='$triage_gh_bin'
TRIAGE_GH_BIN='$triage_gh_bin'
TRIAGE_ENABLED='1'
TRIAGE_ADAPTER='$(triage_fixture_dir)/stub-adapter.sh'
TRIAGE_REPORT_ISSUE='201'
TRIAGE_TARGET_REPOS='demo=demo/repo'
TRIAGE_ALREADY_FIXED_MODE='reject'
TRIAGE_VERIFY_BATCH='1'
TRIAGE_DEDUP_BATCH='1'
TRIAGE_CONCURRENCY='1'
TRIAGE_MAX_VERIFY_PER_RUN='50'
TRIAGE_MAX_NEW_FOR_DEDUP='50'
TRIAGE_DEDUP_POOL_MAX='150'
TRIAGE_REVERIFY_INTERVAL_DAYS='7'
TRIAGE_PHASE_A_DEADLINE_SEC='900'
TRIAGE_HARD_WALL='23:59'
TRIAGE_SYNC_RETRY_SEC='1'
EOF
  if [ -n "$triage_extra" ]; then
    cat "$triage_extra" >> "$triage_config"
  fi
}

triage_seed_finding() {
  triage_state=$1
  triage_id=$2
  triage_repo=$3
  triage_target=$4
  triage_symptom=$5
  triage_kind=$6
  triage_date=$7
  triage_extra=${8:-'{}'}
  mkdir -p "$triage_state/ledger"
  jq -n -c \
    --arg id "$triage_id" \
    --arg repo "$triage_repo" \
    --arg target "$triage_target" \
    --arg symptom "$triage_symptom" \
    --arg kind "$triage_kind" \
    --arg date "$triage_date" \
    --argjson extra "$triage_extra" '
      {
        ts: "2026-08-16T22:30:00Z",
        night_id: "2026-08-16",
        type: "finding",
        id: $id,
        repo: $repo,
        target: $target,
        symptom: $symptom,
        kind: $kind,
        status: "open",
        confirm_cost: "1分",
        date: $date
      } + $extra
    ' >> "$triage_state/ledger/ledger.jsonl"
}

triage_seed_verdict() {
  triage_state=$1
  triage_finding_id=$2
  triage_status=$3
  triage_observed_at=$4
  triage_actor=${5:-human}
  triage_source_ref=${6:-comment:seed}
  triage_rejection_reason=${7:-}
  triage_extra=${8:-'{}'}
  triage_verdict_id="seed-$(triage_fixture_sha256 \
    "$triage_finding_id:$triage_status:$triage_observed_at:$triage_actor:$triage_source_ref")"
  if [ -n "$triage_rejection_reason" ]; then
    triage_reason_json=$(jq -n --arg reason "$triage_rejection_reason" \
      '{rejection_reason:$reason}')
  else
    triage_reason_json='{}'
  fi
  jq -n -c \
    --arg verdict_id "$triage_verdict_id" \
    --arg finding_id "$triage_finding_id" \
    --arg status "$triage_status" \
    --arg actor "$triage_actor" \
    --arg source_ref "$triage_source_ref" \
    --arg observed_at "$triage_observed_at" \
    --argjson reason "$triage_reason_json" \
    --argjson extra "$triage_extra" '
      {
        type: "verdict",
        verdict_id: $verdict_id,
        ts: $observed_at,
        finding_id: $finding_id,
        status: $status,
        actor: $actor,
        source: "manual-comment",
        source_ref: $source_ref,
        observed_at: $observed_at
      } + $reason + $extra
    ' >> "$triage_state/ledger/ledger.jsonl"
}

triage_copy_repo_fixture() {
  triage_dest=$1
  mkdir -p "$triage_dest"
  cp -R "$(triage_fixture_dir)/repo/base/." "$triage_dest/"
}

triage_init_git_repo() {
  triage_repo_dir=$1
  git -C "$triage_repo_dir" init -b main >/dev/null
  git -C "$triage_repo_dir" config user.name 'Triage Test'
  git -C "$triage_repo_dir" config user.email 'triage-tests@example.com'
}

triage_git_commit_all() {
  triage_repo_dir=$1
  triage_when=$2
  triage_message=$3
  git -C "$triage_repo_dir" add -A
  GIT_AUTHOR_DATE="$triage_when" GIT_COMMITTER_DATE="$triage_when" \
    git -C "$triage_repo_dir" commit -m "$triage_message" >/dev/null
}

triage_publish_mirror() {
  triage_repo_dir=$1
  triage_mirror_root=$2
  triage_repo_full_name=$3
  mkdir -p "$triage_mirror_root/$(dirname "$triage_repo_full_name")"
  git -C "$triage_repo_dir" clone --bare . \
    "$triage_mirror_root/$triage_repo_full_name" >/dev/null
  ln -s "$triage_mirror_root/$triage_repo_full_name" \
    "$triage_mirror_root/$triage_repo_full_name.git"
}

triage_write_git_rewrite() {
  triage_gitconfig=$1
  triage_mirror_root=$2
  git config --file "$triage_gitconfig" \
    url."file://$triage_mirror_root/".insteadOf "https://github.com/"
  git config --file "$triage_gitconfig" \
    url."file://$triage_mirror_root/".insteadOf "git@github.com:"
  git config --file "$triage_gitconfig" \
    url."file://$triage_mirror_root/".insteadOf "ssh://git@github.com/"
}

triage_decisions_validate_with_dummy_source() {
  triage_draft=$1
  triage_root=$2
  # shellcheck source=/dev/null
  . "$triage_root/lib/verdict.sh"
  while IFS= read -r triage_line || [ -n "$triage_line" ]; do
    [ -n "$triage_line" ] || return 1
    if ! printf '%s\n' "$triage_line" |
      jq -c '. + {source_ref:"https://github.test/comments/draft"}' |
      verdict_validate_decision >/dev/null; then
      return 1
    fi
  done < "$triage_draft"
}
