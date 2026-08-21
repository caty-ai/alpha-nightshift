#!/bin/bash
# LIVE scan (checklist M6): the gate must scan this repo in CI, not only selftest.
# Plus a mutation proof that PERSONAL_ACCOUNT_REF fires in both directions — the
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

# Reap probes stranded by a previous SIGKILL (which no trap can catch). They are
# deliberately not gitignored — the checker enumerates with `--others`, so ignoring
# them would hide them from the scan they exercise — and a stranded bare-ID probe
# would not trip the gate on its own, so nothing else would notice it.
#
# Only probes whose owning PID is gone are removed: a blanket `rm -f .gate-probe-*`
# would delete a concurrently-running sibling suite's live probe and red it out, and
# would abort this script under `set -e` if any match were a directory (seat findings).
for stranded in "$ROOT"/.gate-probe-*; do
  [ -f "$stranded" ] || continue
  stranded_pid=${stranded##*/.gate-probe-}
  stranded_pid=${stranded_pid%%-*}
  case "$stranded_pid" in
    ''|*[!0-9]*) continue ;;
  esac
  if [ "$stranded_pid" = "$$" ] || ! kill -0 "$stranded_pid" 2>/dev/null; then
    rm -f "$stranded"
  fi
done

# 1. The live tree must pass.
python3 -B "$CHECKER" --account-slug "$slug"

# 2. Every locator-bearing shape of the account reference must fail the gate.
#    Each form below was demonstrated by a review seat against an earlier, narrower
#    version of the rule that let it through (PR #51). They are assembled at runtime
#    so this file does not itself carry them.
#
#    The assertion checks WHY the gate failed: an exit code alone would also be
#    satisfied by an unrelated rule or a gate error, which would let this pass while
#    PERSONAL_ACCOUNT_REF was broken.
check_form() {
  form_label=$1
  form_text=$2
  probe="$ROOT/.gate-probe-$$-locator.md"
  printf '%s\n' "$form_text" > "$probe"
  if out=$(python3 -B "$CHECKER" --account-slug "$slug" 2>&1); then
    printf 'FAIL: %s did not fail the gate\n  form: %s\n' "$form_label" "$form_text" >&2
    exit 1
  fi
  case "$out" in
    *"contains PERSONAL_ACCOUNT_REF"*) ;;
    *)
      printf 'FAIL: %s failed the gate, but not via PERSONAL_ACCOUNT_REF:\n%s\n' "$form_label" "$out" >&2
      exit 1
      ;;
  esac
  rm -f "$probe"
  probe=""
}

check_form "owner/repo reference"   "target=${slug}/some-repo"
check_form "@handle mention"        "reported by @${slug} today"
check_form "https clone URL"        "https://github.com/${slug}/some-repo.git"
check_form "scp remote with path"   "git@github.com:${slug}/some-repo.git"
check_form "scp remote, no path"    "git@github.com:${slug}"
check_form "email address"          "contact ${slug}@example.com"
check_form "plus-tagged email"      "contact ${slug}+alerts@example.com"
check_form "pages/blog host"        "see ${slug}.github.io for details"
check_form "social profile path"    "https://x.com/${slug}"
check_form "query parameter"        "https://github.com/o/r/commits?author=${slug}&page=2"
check_form "KEY=value assignment"   "ACCOUNT=${slug}"
check_form "scheme-style locator"   "github:${slug}"
check_form "serialized field"       "{\"login\":\"${slug}\"}"
check_form "markdown link text"     "[${slug}](https://example.invalid/profile)"

# 3. The account ID on its own must still pass: .github/risk-reviewers.txt is
#    required by contract to name the owner's GitHub ID, so a rule that forbade
#    every mention of it could never be satisfied (issue #50). This is the one
#    shape that must stay green, and it is why the rule keys on punctuation
#    adjacency rather than on the ID itself.
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

printf 'PASS (publication gate live scan; PERSONAL_ACCOUNT_REF proven on 14 locator forms + the roster shape)\n'
