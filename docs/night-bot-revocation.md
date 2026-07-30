# Night Bot Revocation Runbook

This runbook is for owner-driven containment after a drift-monitor denial,
publisher incident, or any suspicion that the night-bot control plane drifted.
It is ordered, fail-closed, and intentionally dry-run friendly. The checked-in
examples remain inactive; do not treat this document as approval to mint live
credentials or mutate GitHub from CI.

Use the dry-run renderer first. It validates that the case metadata is present,
prints the exact owner action order, and never expands a live token or key in
its output.

```sh
night_bot_revocation_dry_run() {
  : "${REVOCATION_CASE_ID:?set REVOCATION_CASE_ID}"
  : "${NIGHTSHIFT_ROOT:?set NIGHTSHIFT_ROOT}"
  : "${AUDIT_JSONL:?set AUDIT_JSONL}"
  : "${PUBLISH_POLICY_SHA256:?set PUBLISH_POLICY_SHA256}"
  : "${REPRESENTATIVE_REF:?set REPRESENTATIVE_REF}"

  /usr/bin/printf '%s\n' \
    "1. stop/disable local publisher and drift-monitor services: launchctl bootout gui/\$(id -u) \"\$HOME/Library/LaunchAgents/ai.caty.nightshift.plist\" ; launchctl bootout gui/\$(id -u) \"\$HOME/Library/LaunchAgents/ai.caty.nightshift-drift-monitor.plist\"" \
    "2. quarantine the request spool and preserve redacted evidence: mv \"\$NIGHTSHIFT_ROOT/state/spool\" \"\$NIGHTSHIFT_ROOT/state/spool.quarantine.\$REVOCATION_CASE_ID\" ; cp \"\$AUDIT_JSONL\" \"\$NIGHTSHIFT_ROOT/state/forensics/\$REVOCATION_CASE_ID.audit.jsonl\"" \
    "3. revoke the in-flight read IAT if one exists: curl -fsS -X DELETE https://api.github.com/installation/token  # Authorization: Bearer REDACTED_INSTALLATION_IAT_IF_PRESENT" \
    "4. suspend or uninstall the GitHub App installation from the owner control plane: github.com/settings/installations -> night-publisher -> suspend or uninstall" \
    "5. revoke the compromised App private key in GitHub, move the local key out of service, and create a replacement only by owner action: github.com/settings/apps -> keys -> revoke old ; mv key.pem key.pem.revoked.\$REVOCATION_CASE_ID" \
    "6. read back that installation token mint/use is blocked and that main/tags/releases/\$REPRESENTATIVE_REF did not change: GET /app/installations/INSTALLATION_ID ; GET /repos/OWNER/REPO/git/ref/heads/main ; GET /repos/OWNER/REPO/tags?per_page=1 ; GET /repos/OWNER/REPO/releases?per_page=1" \
    "7. retain the active deny rulesets; do not loosen create/update/delete/force/merge/release restrictions during recovery" \
    "8. treat any successful main/tag/delete/force/merge/release mutation as an incident that requires owner investigation, not automated cleanup" \
    "9. re-enable only after a fresh owner-sealed policy digest (\$PUBLISH_POLICY_SHA256 replaced), full readback, mock suite, required independent reviews, and a separately approved live proof matrix"
}
```

## Ordered owner actions

1. Stop and disable both local services first so no new request is accepted
   while containment is in progress.
2. Quarantine the local spool before touching GitHub so the exact pending input
   and audit trail remain preserved.
3. Revoke the read installation access token if one is known. If the token is
   unavailable, note that gap in the case record and continue with App-level
   containment.
4. Suspend or uninstall the GitHub App installation through the owner control
   plane. This is the fastest way to prevent any new token mint.
5. Revoke the compromised App private key in GitHub, retire the local copy, and
   generate a replacement only as an owner action.
6. Read back that token minting is blocked and that `main`, tags, releases, and
   the representative `night-bot/run-*` surface did not change unexpectedly.
   Treat hidden `refs/notes/*` and `refs/replace/*` as residual incident
   surfaces that still require owner judgment.
7. Keep the deny rulesets in place. Recovery must not loosen branch or release
   protections.
8. Escalate any successful protected mutation as an incident. Do not automate
   cleanup such as branch deletion or ruleset edits.
9. Re-enable only after a fresh owner-sealed policy, full readback, mock suite,
   required independent reviews, and a separately approved live proof matrix.

## Notes

- The dry-run renderer is intentionally non-mutating. It prints owner-only
  example commands but never executes them.
- `UNPROVEN_NO_ADMIN_READ` still applies to hidden bypass-actor completeness.
  This runbook does not claim exact rule-suite correlation.
- The automated readback boundary covers only `main`, tags, releases, and one
  representative generated ref. Hidden `refs/notes/*` and `refs/replace/*`
  remain manual residuals, and "OAuth user authorization disabled" remains
  `UNPROVEN_MANUAL_OWNER_BASELINE` because GitHub exposes no equivalent public
  read API.
- Keep all incident artifacts redacted. Tokens, JWTs, and private-key material
  must never appear in stdout, stderr, or checked-in files.
