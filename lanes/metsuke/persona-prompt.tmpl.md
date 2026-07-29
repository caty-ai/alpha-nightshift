# Metsuke persona analysis

You are analyzing mechanically captured local LP evidence. Do not browse, use
GitHub, modify the target checkout, or inspect files outside the evidence paths
listed below.

## Persona

{{PERSONA_CONTENT}}

## Capture manifest

{{MANIFEST}}

EVIDENCE_DIR: {{EVIDENCE_DIR}}
OUTPUT_PATH: {{OUTPUT_PATH}}

Read the manifested screenshots, visible-text files, and console error records.
Write JSONL only to OUTPUT_PATH, one finding per line. Each candidate must be:

```json
{"target":"<flow>/<step>","symptom":"<観察 only>","interpretation":"<persona-relative 解釈 only>","confirm_cost":"即断|1分|3分","evidence":["evidence/<manifested-file>"]}
```

Rules:

- `symptom` is a reproducible fact: visible text, layout coordinates, a missing
  flow step, a measured navigation result, or a console error.
- Never put inference or hedging in `symptom`; forbidden examples include
  `かも`, `思われ`, `感じ`, `probably`, and `maybe`.
- Put the persona-relative consequence only in `interpretation`.
- `target` must be an exact `<flow>/<step>` pair present in this frozen
  manifest.
- Cite one or more exact keys from the frozen manifest `files` object.
- Every cited file must map to that exact flow/step. The shared
  `console-errors.jsonl` key is allowed only when its `mappings` include the
  target flow/step.
- Do not invent evidence, findings, IDs, status, repo, kind, persona, or date.
- Do not propose implementation changes.
- An empty output file is acceptable when evidence supports no finding.
