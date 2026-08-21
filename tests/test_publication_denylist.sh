#!/bin/bash
# Denylist self-scan (issue #50).
#
# The publication checker path-excludes .publication-denylist from its own scan
# (tools/check_publication_gate.py, policy_key), so it is structurally unable to
# notice that the denylist itself publishes the literals it protects. That is the
# whole point of the D8 decision: a committed denylist becomes public too.
#
# This suite is the enforcement the checker cannot provide. It compiles the
# denylist's own rules and applies them to the denylist file, plus proves the
# check has teeth by re-running it against a deliberately unsafe copy.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DENYLIST="$ROOT/.publication-denylist"

scan=$(cat <<'PY'
import re
import sys

denylist_path, target_path = sys.argv[1], sys.argv[2]
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
for name, pattern in rules:
    for match in pattern.finditer(text):
        hits.append("%s matches its own protected literal at offset %d" % (name, match.start()))

for hit in hits:
    print(hit)
sys.exit(1 if hits else 0)
PY
)

# 1. The committed denylist must not contain any literal its own rules match.
if ! python3 -B -c "$scan" "$DENYLIST" "$DENYLIST"; then
  printf 'FAIL: the committed denylist publishes a literal it claims to protect (D8-(a) violated)\n' >&2
  exit 1
fi

# 2. Mutation proof: an unsafe denylist (literal written out in full) must be
#    caught, so a green result above cannot come from a scan that never fires.
#    The unsafe literal is assembled at runtime — writing it out here would make
#    this very file trip the rule it is testing, which is the trap this suite
#    exists to catch.
unsafe=$(mktemp "${TMPDIR:-/tmp}/denylist-unsafe.XXXXXX")
cleanup() { rm -f "$unsafe"; }
trap cleanup EXIT INT TERM
printf 'UNSAFE_RULE\t%s/famil%s-vault\n' 'SharedHub' 'y' > "$unsafe"
if python3 -B -c "$scan" "$unsafe" "$unsafe"; then
  printf 'FAIL: self-scan did not catch a denylist that spells out its protected literal\n' >&2
  exit 1
fi

printf 'PASS (denylist self-scan; D8-(a) proven in both directions)\n'
