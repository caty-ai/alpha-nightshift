# alpha-nightshift

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

The run lock is `state/locks/nightshift.lock`. A stale lock is deliberately
never removed automatically. Inspect its `meta` file and remove the lock
directory manually only after confirming that the recorded process is gone.

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
