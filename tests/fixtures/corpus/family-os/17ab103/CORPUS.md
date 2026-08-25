# Pinned family-os corpus

These files are pinned from `caty-ai/family-os` commit
`17ab1034a964256aac07a0690a880a6592cc2440`:

- `tools/check_registry.py`
- `tools/family_common.py`
- `registry/modules.json`

The Python files are byte-for-byte copies. `registry/modules.json` is the same
upstream document with only `retired_repos` replaced by `[]`: those historical
personal-account paths are forbidden by alpha-nightshift's publication gate and
are irrelevant to exercising the five offline checks in this fixture.

The corpus deliberately vendors only the checker's minimum executable inputs.
The omitted README and `FOR-AGENTS.md` files make the real checker emit a
stable non-zero offline inventory, which prevents a vacuous always-green OC-A
integration test. Refresh all three files and this SHA together when the
upstream registry schema changes.
