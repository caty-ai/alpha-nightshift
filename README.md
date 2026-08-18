# alpha-nightshift

Phase 1a/1c now include an opt-in local guard and an inactive GitHub App
publisher under `guard/`. The checked-in package still denies before key or
network access: its mode is `LOCAL_ONLY_REMOTE_UNPROVEN`, preflight always
reports `write_mode:false`, and the example publisher policy remains inactive.
Nothing in this round created or changed a user, GitHub App installation,
token, protection, or ruleset, and no real GitHub write or negative proof was
attempted. The existing Phase 0 dispatcher and lane behavior is unchanged.

The local package provides a strict typed gateway, deterministic hard-disable
preflight, a real Git-object scanner using pinned gitleaks 8.30.1 stdin, a
rendered macOS sandbox-exec measurement profile, and offline bypass tests.
Candidate-introduced binary, archive, executable, document, media, and opaque
objects deny in Phase 1a. Sandbox cells that cannot be expressed or measured
remain `UNSUPPORTED` hard-disable residuals rather than containment claims.
The local base evidence is only a deterministic aggregate of locally read
object records; it does not prove protected-tip or remote equality. The MIME
allowlist is deliberately narrow, so common source MIME types such as
`text/x-shellscript` or `text/x-c` can also deny in Phase 1a.
Whole-payload wrapper or checksum shapes are also fail-closed, so otherwise
innocent Base64, hex, percent, or Base64url-shaped content may false-deny.
See `guard/README.md` for the local interface.

Phase 1b/1c remain unproven on live credentials. An orchestrator preflight
found that protection for a private repository on GitHub Free returned 403.
Activation therefore still requires a supporting private-repository plan/host,
a dedicated GitHub App installed on exactly `shojikumaru/alpha-nightshift`, the
night-bot broker identity that owns the App private key, and explicit owner
authorization for potentially mutating remote proofs. The only allowed publish
target is a freshly generated `refs/heads/night-bot/run-YYYYMMDD-NNNN-HEX8`
branch, rule-suite correlation remains
`UNPROVEN_NO_ADMIN_READ`, and any revoke or readback failure is an incident
rather than a silent cleanup. Phase 1 must not be marked complete until those
remote proofs and protection readback succeed.

The same remote boundary now has a separate read-only drift monitor under
`guard/drift-monitor.sh`. It reuses the publisher policy/JWT/read-IAT/readback
machinery, never mints a `contents:write` token, emits only `MATCH`,
`DRIFT_DENY`, or `MONITOR_UNVERIFIED`, and leaves the checked-in
`config/drift-monitor.example.json` inactive with `write_mode:false`. Its JWT
preflight machine-verifies exact App permissions/events, disabled webhook
configuration, and exact installation identity before any token mint; "OAuth
user auth disabled" still has no public read API and remains
`UNPROVEN_MANUAL_OWNER_BASELINE`. The readback surface proves only current
`main`/tags/releases/representative-ref equality and does not prove hidden
`refs/notes/*` or `refs/replace/*` provenance. The owner revocation sequence is
documented in [docs/night-bot-revocation.md](docs/night-bot-revocation.md).

Phase 0 is a macOS nightly observation harness. At 23:30 the dispatcher runs
credential-free observation lanes and serially ingests their JSONL proposals.
At 06:30 a separate machine-template digest reports findings, a clean zero, or
the dead-man condition where the nightly run never started. Phase 0 performs no
GitHub or network operations in the harness itself. The separate daytime
`verdict-sync` command can perform bounded, read-only GitHub inspection when
explicitly given a link file. Phase 0 lanes are not network-confined; network
sandboxing is planned for Phase 1.

## Requirements

- macOS with `/bin/bash` 3.2
- `git` and `jq`
- standard BSD userland tools

Copy `config/nightshift.conf.example` to `config/nightshift.conf` and adjust the
numbered `LANE_CMD_n` values. Runtime state is stored under `state/` by default.

### Multimodel review observation lane

`lanes/review/run.sh` clones an absolute local Git checkout into its lane state,
deterministically assigns one of the ten DESIGN lenses and a rotating subset of
configured Codex/Kimi/GLM/Grok seats, then runs the seats serially and blindly.
Opus is an explicit experimental opt-in. Each adapter is independently
timeboxed; malformed model JSONL is rejected and trusted finding identity,
persona, date, and evidence are reconstructed by the lane. The lane performs no
GitHub operations. See the commented `LANE_CMD_2` in
`config/nightshift.conf.example` for the complete host configuration.
Each seat receives a separate HOME containing only its own available auth
symlink; this narrows cross-seat credential exposure, but Phase 0 has no OS
sandbox and host files readable by the user process remain readable. If a
later infrastructure check fails, findings already validated against the clean
checkout are still published and ingested. The review-lane evidence manifest
covers files only and is intentionally standalone from the `lib/evidence.sh`
freeze-capture workflow.

`LANE_HOME_LINKS` is empty by default. Any opted-in path is reachable
**read-write** through its lane HOME symlink; linking it grants the lane the
same access. Before linking, the dispatcher resolves and case-normalizes the
security comparison and refuses `.ssh`, `.config/gh`, `.git-credentials`,
`.netrc`, `.aws`, `.gnupg`, and all of their descendants; `.config` itself is
also refused. Unresolvable entries fail closed. Link only the minimum path
needed for Codex authentication. Other host secret stores readable by the same
macOS user remain reachable until the Phase 1 sandbox is available.

Phase 0 timeboxes terminate observed process-group members and recursively
sweep discoverable descendants, including children observed before they call
`setsid()`. Any process the Phase 0 inspector can still identify after cleanup
is recorded in `lane_end.survivors`, fails the lane, and aborts the rest of the
night. The array is therefore an inspector result, not proof that no other
process exists. A classic double fork (`fork` → `setsid` → `fork`) can reparent
the grandchild before Phase 0 observes it; that process can be invisible to the
parent/PGID inspector and survive without appearing in `survivors`. Prevention
and full filesystem, credential, and process containment require the Phase 1
sandbox.

## Run manually

```sh
/bin/bash bin/nightshift-dispatch run
/bin/bash bin/nightshift-dispatch digest
/bin/bash bin/nightshift-dispatch status
```

`launchd` and foreground launches deliver SIGINT with its default disposition,
so the dispatcher handles it as a prompt interrupted run. A script started as a
plain POSIX background job may inherit SIGINT ignored; use SIGTERM to stop that
kind of manual background launch.

## Install the launchd jobs

The checked-in plists contain the literal `__NIGHTSHIFT_ROOT__` token. Substitute
the absolute checkout path while copying each file into `~/Library/LaunchAgents`,
then load the resulting files with `launchctl`. For example:

```sh
root=$(pwd -P)
sed "s|__NIGHTSHIFT_ROOT__|$root|g" \
  launchd/ai.caty.nightshift.plist \
  > "$HOME/Library/LaunchAgents/ai.caty.nightshift.plist"
sed "s|__NIGHTSHIFT_ROOT__|$root|g" \
  launchd/ai.caty.nightshift.digest.plist \
  > "$HOME/Library/LaunchAgents/ai.caty.nightshift.digest.plist"
launchctl load "$HOME/Library/LaunchAgents/ai.caty.nightshift.plist"
launchctl load "$HOME/Library/LaunchAgents/ai.caty.nightshift.digest.plist"
```

Create `state/logs` before loading so launchd can open its output paths.

`launchd/ai.caty.nightshift-drift-monitor.plist.example` is a disabled example
for a morning read-only drift check. Keep it disabled until an owner-sealed
active monitor config exists outside the repo.

The run lock is `state/locks/nightshift.lock`. A stale lock is deliberately
never removed automatically. Inspect its `meta` file and remove the lock
directory manually only after confirming that the recorded process is gone.

## Morning triage

`launchd/ai.caty.nightshift.triage.plist` schedules `bin/morning-triage` at
06:35. Keep the job disabled until local config sets `TRIAGE_ENABLED=1`,
`TRIAGE_REPORT_ISSUE` points to the pinned + locked `auto-triage` execution
record Issue, and `TRIAGE_TARGET_REPOS` lists the repos to triage.

Keep that execution-record Issue pinned and locked forever. Do not close or
delete it; `source_ref` values depend on the URL staying live.

The run is meant for the 06:30-08:00 morning window. `bin/morning-triage`
exits outside that window, so the launchd schedule is a trigger, not the only
guard.

`--force` bypasses only that execution-window check. It does not bypass
`TRIAGE_ENABLED=0` or the `TRIAGE_HARD_WALL` Phase B cutoff.

`--dry-run` stays inside the selected `--state-dir`, publishes the Phase A
draft, report, cluster, verification, and watermark artifacts under
`state/triage/`, and skips GitHub, final `decisions.jsonl`, and `verdict-sync`.

The watermark is the A1 projection read time frozen for that run. If
`verdict-sync --github-links` rejects an old label or comment because it
predates that watermark, leave the old evidence in place and post a fresh
comment or relabel after the next run instead of trying to rewrite the stale
record.

After the initial report can be posted, B2.5 gate failures and B3 sync failures
also get a best-effort visible result comment. Earlier lock, configuration,
ledger-projection, clone, hard-wall, or report-post failures may not have a
working comment channel and are visible only in the state log.

## Record morning verdicts

`verdict-sync` is a daytime/core command, not a lane. It takes the same
single-writer lock as the nightly dispatcher, validates the complete decision
batch before appending, and never changes existing finding records. Decisions
are immutable `type:"verdict"` events; current finding status is a projection
of the original open finding and its accepted event sequence.

The offline Phase-0 path accepts a trusted canonical JSONL snapshot:

```sh
/bin/bash bin/verdict-sync --input /absolute/path/to/decisions.jsonl
```

Each object requires `finding_id`, `status` (`adopted`, `fixed`, or
`rejected`), `actor`, `source` (`manual-comment`, `manual-label`, or `github`),
`source_ref`, and a seconds-precision UTC `observed_at` ending in `Z`.
`rejection_reason` is required for rejected decisions and forbidden otherwise.
Optional completion-draft fields are validated strictly; unknown fields and
unsafe declared-file paths fail the entire batch. Input results and evidence
are only unverified hints.

The linked GitHub path is:

```sh
/bin/bash bin/verdict-sync \
  --github-links /absolute/path/to/links.jsonl
```

Each link requires `finding_id`, `repo_full_name`, and at least one positive
integer `issue` or `pr`. `VERDICT_GH_BIN` defaults to `gh`. The adapter invokes
only these direct, non-shell command shapes:

```text
gh api --method GET repos/OWNER/REPO/issues/NUMBER
gh api --method GET repos/OWNER/REPO/pulls/NUMBER
gh api --method GET repos/OWNER/REPO/issues/NUMBER/events?per_page=100
gh api --method GET repos/OWNER/REPO/issues/NUMBER/comments?per_page=100
```

It does not create, edit, label, close, comment on, or merge GitHub resources.
An events or comments response containing 100 items is treated as potentially
truncated and fails the complete invocation. Conflicting decision labels also
fail closed. When a link supplies both issue and PR observations, their
inferred statuses must agree; the unique newest UTC observation is selected,
and an equal-time tie between distinct candidates is rejected.
An unmerged closed PR or `night:rejected` label is accepted only with a human
comment whose entire body parses as this exact versioned JSON object (no extra
keys):

```json
{"schema":"alpha-nightshift/verdict-marker/v1","finding_id":"FINDING_ID","status":"rejected","rejection_reason":"NON_EMPTY_REASON"}
```

The comment author must have GitHub type `User`, must not equal
`NIGHT_BOT_LOGIN` (default `night-bot`), and the comment must provide a valid
UTC creation timestamp. Missing or conflicting state, markers, actors, times,
or reasons fail the complete invocation before any append.

Morning triage still writes the verdict decision set, but the template contract
now treats `removed_pattern` as part of the verification evidence for fixed
findings. The design in `docs/morning-triage.md` is the source of truth for the
triage templates and their field names.

After a durable verdict append, the command atomically publishes an explicitly
incomplete draft at
`state/verdicts/finding-SHA256_OF_FINDING_ID/L1-7-draft.md`. It is never a
completion or merge-authorizing record. Digest footers report cumulative exact
counts and rational decision/completion/rejection rates; revert rate remains
unavailable until an explicit revert relation exists.

## Test

```sh
/bin/bash tests/run_tests.sh
```
