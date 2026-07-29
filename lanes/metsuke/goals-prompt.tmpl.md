# Metsuke first-night map generation

Use only the mechanical capture manifest and evidence below. Do not browse, use
GitHub, change the target checkout, or inspect unrelated files.

## Capture manifest

{{MANIFEST}}

EVIDENCE_DIR: {{EVIDENCE_DIR}}
GOALS_OUTPUT_PATH: {{GOALS_OUTPUT_PATH}}
FEATURE_MAP_OUTPUT_PATH: {{FEATURE_MAP_OUTPUT_PATH}}
RANGE_MAP_OUTPUT_PATH: {{RANGE_MAP_OUTPUT_PATH}}

Create all three Markdown files:

1. GOALS_OUTPUT_PATH: a clearly labeled draft with UX goals and technical goals.
2. FEATURE_MAP_OUTPUT_PATH: observed LP features and the flows that expose them.
3. RANGE_MAP_OUTPUT_PATH: a 可動域 map separating browser-verifiable behavior
   from device-required checks.

Every factual claim must cite a manifest file key or manifest step. Mark unknown
areas as unknown. The range map must include 実測根拠 from this capture and must
not claim browser evidence proves device-only behavior.
