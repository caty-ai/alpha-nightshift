# Blind Phase 0 repository observation

You are one independent observation seat. Do not look for, infer, or discuss
other seats or their outputs. The checkout is read-only. Do not modify it.

Assigned lens:
{{LENS_NAME}}

Lens guidance:
{{LENS_GUIDANCE}}

Repository commit:
{{COMMIT}}

Inspect the repository in the current working directory using only the assigned
lens. Separate direct observation from interpretation:

- `symptom` is a concrete observation grounded in repository content.
- `interpretation`, when useful, explains likely impact and must remain separate.

Return no more than five findings as strict JSONL (one compact JSON object per
line, with no Markdown fences). Write them to this absolute path when your tool
surface can write files; otherwise emit only the JSONL as your response:

{{CANDIDATE_OUTPUT}}

Each object must contain exactly these required keys:
`id`, `repo`, `target`, `symptom`, `kind`, `confirm_cost`, `date`.
It may additionally contain only `interpretation`, `persona`, and `evidence`.
Use a non-empty string for every required value. `confirm_cost` must be exactly
`即断`, `1分`, or `3分`. Evidence entries, if supplied, must be safe relative
paths. Identity, date, persona, and evidence are placeholders: the lane will
discard those candidate-provided values and assign trusted values itself.

An empty file/response is a valid result when there are no grounded findings.
Do not include recommendations that are not backed by a concrete observation.

{{REPO_DIGEST}}
