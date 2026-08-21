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
trap cleanup EXIT INT TERM

cd "$ROOT"

# Sweep probes stranded by a previous SIGKILL (which no trap can catch). They are
# deliberately not gitignored — the checker enumerates with `--others`, so ignoring
# them would hide them from the scan they exercise — and a stranded bare-ID probe
# would not trip the gate on its own, so nothing else would notice it (seat finding).
rm -f "$ROOT"/.gate-probe-*

# 1. The live tree must pass.
python3 -B "$CHECKER" --account-slug "$slug"

# 2. A personal-account reference must fail the gate. This is the
#    hole the seat review found: an owner/repo literal that the checker's
#    personal-URL check cannot see because it only matches URL shapes.
probe="$ROOT/.gate-probe-$$-personal-ref.md"
printf 'target=%s/some-repo\n' "$slug" > "$probe"
if out=$(python3 -B "$CHECKER" --account-slug "$slug" 2>&1); then
  printf 'FAIL: personal repository reference did not fail the gate\n' >&2
  exit 1
fi
# Assert WHY it failed: an exit code alone would also be satisfied by an
# unrelated rule or a gate error, which would let this assertion pass while
# PERSONAL_ACCOUNT_REF was broken (seat finding, PR #51).
case "$out" in
  *"contains PERSONAL_ACCOUNT_REF"*) ;;
  *)
    printf 'FAIL: the gate failed, but not because of PERSONAL_ACCOUNT_REF:\n%s\n' "$out" >&2
    exit 1
    ;;
esac
rm -f "$probe"

# 3. The account ID on its own must still pass: .github/risk-reviewers.txt is
#    required by contract to name the owner's GitHub ID, so a rule that forbade
#    every mention of it could never be satisfied (issue #50).
probe="$ROOT/.gate-probe-$$-bare-id.txt"
printf '%s\n' "$slug" > "$probe"
if ! out=$(python3 -B "$CHECKER" --account-slug "$slug" 2>&1); then
  printf 'FAIL: a bare account ID (roster shape) was rejected by the gate:\n%s\n' "$out" >&2
  exit 1
fi
case "$out" in
  *"OK — publication gate passed"*) ;;
  *)
    printf 'FAIL: gate exited 0 without reporting a pass:\n%s\n' "$out" >&2
    exit 1
    ;;
esac
rm -f "$probe"
probe=""

printf 'PASS (publication gate live scan; PERSONAL_ACCOUNT_REF proven in both directions)\n'
