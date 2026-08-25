# Pinned meetmate corpus

`README.md` and `package.json` are byte-for-byte copies from
`caty-ai/meetmate@e0b5fc5c374305e1038665c3a5f3e6f61b518029`.
`AGENTS.md` is the same upstream document plus corpus-authored wording that:

- keeps one genuine top-level dotted filename reference (`contributing.md`) on a
  stable non-zero OC-D path
- removes generated user-side `config.json` mentions, which are not repository
  paths and would otherwise dominate the fixed-count assertion

Together they are the smallest root-level subset needed to exercise OC-B, OC-C,
and OC-D without network access.

The files under `bin/`, `docs/`, and `src/` are existence-only corpus stubs for
paths that are present at the pinned upstream commit and referenced by
`AGENTS.md`. They prevent fixture truncation from masquerading as OC-D drift.
