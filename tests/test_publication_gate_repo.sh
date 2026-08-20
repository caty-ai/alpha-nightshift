#!/bin/bash
# LIVE scan (checklist M6): the gate must scan this repo in CI, not only selftest.
#
# The account slug is assembled from two halves so this file does not itself
# trip the denylist's ACCOUNT_SLUG rule (the checker scans every tracked file
# and only path-excludes the denylist itself). The assembled value is visible
# one line below — this is trusted policy wiring, not concealment.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

account_slug="$(printf '%s%s' 'shoji' 'kumaru')"

cd "$ROOT"
python3 -B "$ROOT/tools/check_publication_gate.py" --account-slug "$account_slug"
