# Pinned meetmate corpus

`README.md` and `AGENTS.md` are byte-for-byte copies from
`caty-ai/meetmate@e0b5fc5c374305e1038665c3a5f3e6f61b518029`.
They are the smallest root-level subset needed to exercise OC-B, OC-C, and
OC-D against public-HEAD documentation without network access.

The files under `bin/`, `docs/`, and `src/` are existence-only corpus stubs for
paths that are present at the pinned upstream commit and referenced by
`AGENTS.md`. They prevent fixture truncation from masquerading as OC-D drift.
