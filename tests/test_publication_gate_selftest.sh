#!/bin/bash
# Runs the vendored publication-gate checker's embedded selftest as a counted
# suite (handbook checklist C5 / fma#30 pattern), so a broken or tampered
# checker fails `make test` instead of guarding nothing.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

python3 -B "$ROOT/tools/check_publication_gate.py" --selftest
