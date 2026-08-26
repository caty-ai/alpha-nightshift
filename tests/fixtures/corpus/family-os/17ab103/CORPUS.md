# Pinned family-os corpus

These files are pinned from `caty-ai/family-os` commit
`17ab1034a964256aac07a0690a880a6592cc2440`:

- `tools/check_registry.py`
- `tools/family_common.py`
- `registry/modules.json`
- `README.md`
- `README.ja.md`
- `README.zh.md`
- `README.th.md`

The Python files are byte-for-byte copies. `registry/modules.json` is the same
upstream document with only `retired_repos` replaced by `[]`: those historical
personal-account paths are forbidden by alpha-nightshift's publication gate and
are irrelevant to exercising the five offline checks in this fixture.

The Python and README files are byte-for-byte copies. The omitted
`FOR-AGENTS.md` keeps the real checker on a stable non-zero offline path, while
the four real README files pin OC-C's corrected input set. Refresh the corpus
and this SHA together when the upstream registry schema changes.
