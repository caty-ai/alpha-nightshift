#!/bin/bash
# LIVE scan (checklist M6): the gate must scan this repo in CI, not only selftest.
# Plus a mutation proof that PERSONAL_REPO_REF fires in both directions — the
# rule was rewritten in issue #50 after its first form collided with the
# risk-reviewer roster contract, so both directions are pinned by this test
# instead of by a one-off manual probe.
#
# The account slug is assembled from two halves so this file does not itself
# trip the rule it exercises. The assembled value is plain to read one line
# below — this is trusted policy wiring, not concealment.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHECKER="$ROOT/tools/check_publication_gate.py"
slug="$(printf '%s%s' 'shoji' 'kumaru')"

probe=""
cleanup() {
  if [ -n "$probe" ]; then
    rm -f "$probe"
  fi
}
trap cleanup EXIT

cd "$ROOT"

# 1. The live tree must pass.
python3 -B "$CHECKER" --account-slug "$slug"

# 2. A personal-account repository reference must fail the gate. This is the
#    hole the seat review found: an owner/repo literal that the checker's
#    personal-URL check cannot see because it only matches URL shapes.
probe="$ROOT/.gate-probe-personal-repo-ref.md"
printf 'target=%s/some-repo\n' "$slug" > "$probe"
if python3 -B "$CHECKER" --account-slug "$slug" >/dev/null 2>&1; then
  printf 'FAIL: personal repository reference did not fail the gate\n' >&2
  exit 1
fi
rm -f "$probe"

# 3. The account ID on its own must still pass: .github/risk-reviewers.txt is
#    required by contract to name the owner's GitHub ID, so a rule that forbade
#    every mention of it could never be satisfied (issue #50).
probe="$ROOT/.gate-probe-bare-id.txt"
printf '%s\n' "$slug" > "$probe"
if ! python3 -B "$CHECKER" --account-slug "$slug" >/dev/null 2>&1; then
  printf 'FAIL: a bare account ID (roster shape) was rejected by the gate\n' >&2
  exit 1
fi
rm -f "$probe"
probe=""

printf 'PASS (publication gate live scan; PERSONAL_REPO_REF proven in both directions)\n'
