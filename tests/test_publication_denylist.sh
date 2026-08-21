#!/bin/bash
# Denylist self-scan + per-rule liveness (issue #50).
#
# The publication checker path-excludes .publication-denylist from its own scan
# (tools/check_publication_gate.py, policy_key), so it is structurally unable to
# notice that the denylist itself publishes the literals it protects. That is the
# whole point of the D8 decision: a committed denylist becomes public too.
#
# This suite is the enforcement the checker cannot provide, in two directions:
#
#   1. NEGATIVE — no rule may match this file, in the raw text OR in any of the
#      percent/HTML-decoded views the checker itself scans. A percent-encoded
#      literal would otherwise pass here while staying trivially recoverable.
#   2. POSITIVE — every rule must still match the literal it protects.
#
# Direction 2 exists because direction 1 passes trivially on a dead rule: a typo
# that makes a pattern match nothing satisfies "no rule matches this file" while
# silently removing that rule's protection, and the live scan stays green because
# the tree contains no violation either. That is precisely this repo's named worst
# failure mode — a gate that looks stricter but scans less. Four independent review
# seats converged on it; a fifth found the decoded-view hole (PR #51).
#
# Both directions carry a mutation proof, so neither can pass vacuously.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DENYLIST="$ROOT/.publication-denylist"

scan=$(cat <<'PY'
import html
import re
import sys
import urllib.parse

denylist_path, target_path = sys.argv[1], sys.argv[2]


def scan_views(text):
    """Mirror of the checker's scan_views: raw plus decoded views."""
    views = [text]
    current = text
    for _ in range(3):
        unquoted = urllib.parse.unquote(current)
        if unquoted not in views:
            views.append(unquoted)
        unescaped = html.unescape(unquoted)
        if unescaped not in views:
            views.append(unescaped)
        if unescaped == current:
            break
        current = unescaped
    return tuple(views)


rules = []
with open(denylist_path, encoding="utf-8") as handle:
    for lineno, raw in enumerate(handle, 1):
        line = raw.lstrip("﻿").rstrip("\n")
        if not line or line.startswith("#"):
            continue
        name, sep, pattern = line.partition("\t")
        if not sep or not name or not pattern:
            print("malformed rule at line %d" % lineno)
            sys.exit(2)
        rules.append((name, re.compile(pattern, re.IGNORECASE)))

if not rules:
    print("no rules loaded")
    sys.exit(2)

text = open(target_path, encoding="utf-8").read()
hits = []
for view_index, view in enumerate(scan_views(text)):
    for name, pattern in rules:
        for match in pattern.finditer(view):
            hits.append(
                "%s matches its own protected literal at offset %d%s"
                % (name, match.start(), "" if view_index == 0 else " (decoded view)")
            )

for hit in hits:
    print(hit)
sys.exit(1 if hits else 0)
PY
)

# Every rule must fire on the literal it protects. The samples are assembled at
# runtime from fragments for the same reason the rules are split: spelling them out
# here would make this file trip the rules it is testing.
liveness=$(cat <<'PY'
import re
import sys

denylist_path = sys.argv[1]

slug = "shojikumar" + "u"
samples = {
    "HOME_ABS_PATH": "/Users/" + "someone" + "/project",
    "PERSONAL_ACCOUNT_REF": slug + "/some-repo",
    "FAMILY_VAULT_PATH": "SharedHub/" + "famil" + "y" + "-vault",
    "ALPHA_WIKI_PATH": "claude-workspace/" + "alph" + "a" + "-wiki",
    "TAILSCALE_CGNAT_IP": "100." + "64.0.1",
    "HANDOFF_DIR": "_handoff" + "s" + "/note.md",
}

# Rows are kept as a list, not folded into a dict keyed by name. A dict lets a
# duplicate name overwrite an earlier row, so an inert rule followed by a live one
# of the same name would satisfy "every rule fires" while the inert row is still
# loaded and applied by the real checker (seat finding, PR #51 delta).
rows = []
with open(denylist_path, encoding="utf-8") as handle:
    for lineno, raw in enumerate(handle, 1):
        line = raw.lstrip("﻿").rstrip("\n")
        if not line or line.startswith("#"):
            continue
        name, sep, pattern = line.partition("\t")
        rows.append((lineno, name, re.compile(pattern, re.IGNORECASE)))

duplicates = sorted({n for _, n, _ in rows if [m for _, m, _ in rows].count(n) > 1})
if duplicates:
    print("duplicate rule name(s): %s" % ", ".join(duplicates))
    print("every row is loaded by the checker, so a duplicate name hides one of them")
    sys.exit(2)

rules = {name: pattern for _, name, pattern in rows}

missing_sample = sorted(set(rules) - set(samples))
if missing_sample:
    print("no liveness sample for: %s" % ", ".join(missing_sample))
    print("a new rule must ship with a runtime-assembled sample of what it protects")
    sys.exit(2)

stale_sample = sorted(set(samples) - set(rules))
if stale_sample:
    print("sample without a matching rule (renamed or removed?): %s" % ", ".join(stale_sample))
    sys.exit(2)

dead = [
    (lineno, name)
    for lineno, name, pattern in rows
    if not pattern.search(samples[name])
]
for lineno, name in sorted(dead):
    print("%s (line %d) no longer matches the literal it protects" % (name, lineno))
sys.exit(1 if dead else 0)
PY
)

unsafe=$(mktemp "${TMPDIR:-/tmp}/denylist-unsafe.XXXXXX")
encoded=$(mktemp "${TMPDIR:-/tmp}/denylist-encoded.XXXXXX")
dead_copy=$(mktemp "${TMPDIR:-/tmp}/denylist-dead.XXXXXX")
dup_copy=$(mktemp "${TMPDIR:-/tmp}/denylist-dup.XXXXXX")
cleanup() { rm -f "$unsafe" "$encoded" "$dead_copy" "$dup_copy"; }
trap cleanup EXIT INT TERM

# 1. The committed denylist must not contain any literal its own rules match,
#    in the raw text or in any decoded view.
if ! python3 -B -c "$scan" "$DENYLIST" "$DENYLIST"; then
  printf 'FAIL: the committed denylist publishes a literal it claims to protect (D8-(a) violated)\n' >&2
  exit 1
fi

# 2. Mutation proof, raw view: a denylist that spells out its literal must be caught.
#    The unsafe literal is assembled at runtime — writing it out here would make this
#    very file trip the rule it is testing.
printf 'UNSAFE_RULE\t%s/famil%s-vault\n' 'SharedHub' 'y' > "$unsafe"
if python3 -B -c "$scan" "$unsafe" "$unsafe"; then
  printf 'FAIL: self-scan did not catch a denylist that spells out its protected literal\n' >&2
  exit 1
fi

# 3. Mutation proof, decoded view: the REAL rules must catch a percent-encoded
#    protected literal, because the checker scans decoded views of every file.
#
#    Rules come from $DENYLIST, not from the fixture. An earlier version used the
#    fixture as both rule source and target, so its rule matched its own text in
#    the RAW view and the proof stayed green even with decoding removed — a
#    mutation proof that could not fail, which is the exact defect class this
#    suite exists to catch. Two seats found it independently (PR #51 delta).
printf '%s%%2Ffamil%s-vault\n' 'SharedHub' 'y' > "$encoded"
if python3 -B -c "$scan" "$DENYLIST" "$encoded"; then
  printf 'FAIL: self-scan missed a percent-encoded protected literal (raw view only)\n' >&2
  exit 1
fi

# 4. Every rule must still match what it protects.
if ! python3 -B -c "$liveness" "$DENYLIST"; then
  printf 'FAIL: a denylist rule no longer matches the literal it protects (silently dead rule)\n' >&2
  exit 1
fi

# 5. Mutation proof for check 4: a rule edited into an inert pattern must be caught.
sed 's|^FAMILY_VAULT_PATH	.*|FAMILY_VAULT_PATH	zzz9nevermatch9zzz|' "$DENYLIST" > "$dead_copy"
if python3 -B -c "$liveness" "$dead_copy"; then
  printf 'FAIL: liveness check did not notice a rule mutated into an inert pattern\n' >&2
  exit 1
fi

# 6. Mutation proof for the duplicate-name guard: an inert row shadowed by a live
#    row of the same name must be rejected. The checker loads every row, so a
#    duplicate would otherwise hide a dead rule behind a live one.
{
  printf 'FAMILY_VAULT_PATH\tzzz9nevermatch9zzz\n'
  cat "$DENYLIST"
} > "$dup_copy"
if python3 -B -c "$liveness" "$dup_copy"; then
  printf 'FAIL: liveness check accepted a denylist with a duplicated rule name\n' >&2
  exit 1
fi

printf 'PASS (denylist self-scan incl. decoded views + per-rule liveness; all mutation-proven)\n'
