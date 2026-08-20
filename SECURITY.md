# Security Policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately via GitHub Security
Advisories: **Security → Report a vulnerability** on this repository.
Do not open a public issue for anything you believe is exploitable.

When reporting, please include the commit SHA you tested, your OS and
bash/python versions, and a minimal reproduction.

## Scope notes for this repository

alpha-nightshift is a nightly maintenance loop whose central security claim
is a deny-by-default guard between night work and the real remote:

- The publisher's preflight must answer `write_mode:false` unless remote-safety
  proofs exist; anything that makes an unproven path writable is a
  vulnerability, not a feature request.
- Candidate objects are scanned with a hash-pinned gitleaks binary; a way to
  smuggle an unscanned object past the scanner (wrapper encodings, MIME
  confusion, denylist bypass) is in scope.
- Sandbox cells marked `UNSUPPORTED` are hard-disabled residuals. A claim that
  containment holds where it is not measured is itself a reportable bug.

Reports that show a fail-open path in `guard/` — any input that turns a
deny into a silent allow — are treated at the highest severity.
