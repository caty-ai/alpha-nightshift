#!/bin/bash
set -euo pipefail

[ "$#" -eq 3 ] || exit 2
prompt_file=$1
workdir=$2
out_dir=$3
response_file="$out_dir/response.txt"
candidate_file="$out_dir/candidates.jsonl"
grok_bin=${REVIEW_GROK_BIN:-"$HOME/.grok/bin/grok"}
rc=0

[ -d "$out_dir" ] && [ ! -L "$out_dir" ] || exit 2
for adapter_path in "$response_file" "$candidate_file"; do
  [ ! -L "$adapter_path" ] || exit 2
  if [ -e "$adapter_path" ] && [ ! -f "$adapter_path" ]; then exit 2; fi
done

set +e
(
  "$grok_bin" \
    --prompt-file "$prompt_file" \
    --cwd "$workdir" \
    -m grok-4.5 \
    --effort high \
    --always-approve \
    --max-turns 80 \
    --output-format plain \
    --no-subagents
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
