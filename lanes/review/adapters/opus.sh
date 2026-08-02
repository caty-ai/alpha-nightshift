#!/bin/bash
set -euo pipefail

[ "$#" -eq 3 ] || exit 2
[ "${REVIEW_OPUS_ENABLED:-0}" = 1 ] || exit 2
prompt_file=$1
workdir=$2
out_dir=$3
response_file="$out_dir/response.txt"
candidate_file="$out_dir/candidates.jsonl"
claude_bin=${REVIEW_CLAUDE_BIN:-"$HOME/.claude/local/claude"}
claude_config_dir=${REVIEW_CLAUDE_CONFIG_DIR:-"$HOME/.claude"}
write_enabled=${REVIEW_OPUS_WRITE_ENABLED:-0}
rc=0

case "$write_enabled" in 0|1) ;; *) exit 2 ;; esac

[ -d "$out_dir" ] && [ ! -L "$out_dir" ] || exit 2
for adapter_path in "$response_file" "$candidate_file"; do
  [ ! -L "$adapter_path" ] || exit 2
  if [ -e "$adapter_path" ] && [ ! -f "$adapter_path" ]; then exit 2; fi
done

set +e
(
  cd "$workdir"
  if [ "$write_enabled" = 1 ]; then
    CLAUDE_CONFIG_DIR="$claude_config_dir" \
      "$claude_bin" -p "$(cat "$prompt_file")" \
        --permission-mode dontAsk \
        --allowedTools Read,Glob,Grep,Write \
        --no-session-persistence
  else
    CLAUDE_CONFIG_DIR="$claude_config_dir" \
      "$claude_bin" -p "$(cat "$prompt_file")" \
        --permission-mode dontAsk \
        --allowedTools Read,Glob,Grep \
        --no-session-persistence
  fi
) | tee "$response_file"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  [ ! -L "$candidate_file" ] || exit 2
  if [ -e "$candidate_file" ]; then
    [ -f "$candidate_file" ] && [ ! -L "$candidate_file" ] || exit 2
  else
    cp "$response_file" "$candidate_file"
  fi
fi
exit "$rc"
