# alpha-nightshift

Phase 0 is a macOS nightly observation harness. At 23:30 the dispatcher runs
credential-free observation lanes and serially ingests their JSONL proposals.
At 06:30 a separate machine-template digest reports findings, a clean zero, or
the dead-man condition where the nightly run never started. Phase 0 performs no
GitHub or network operations in the harness itself. Phase 0 lanes are not
network-confined; network sandboxing is planned for Phase 1.

## Requirements

- macOS with `/bin/bash` 3.2
- `git` and `jq`
- standard BSD userland tools

Copy `config/nightshift.conf.example` to `config/nightshift.conf` and adjust the
numbered `LANE_CMD_n` values. Runtime state is stored under `state/` by default.

`LANE_HOME_LINKS` is empty by default. Any opted-in path is reachable
**read-write** through its lane HOME symlink; linking it grants the lane the
same access. The dispatcher refuses sensitive basenames (`.ssh`, `.config`,
`.git-credentials`, `.netrc`, `.aws`, `.gnupg`, and `.config/gh`) even when an
operator opts in. Link only the minimum path needed for Codex authentication.
Other host secret stores readable by the same macOS user remain reachable until
the Phase 1 sandbox is available.

Phase 0 timeboxes kill the lane process group and recursively sweep descendants,
including children that call `setsid()`. A survivor is recorded in
`lane_end.survivors`, fails the lane, and aborts the rest of the night. This is
detection and fail-closed cleanup, not containment: a process can still race or
evade observation. Full filesystem, credential, and process containment
requires the Phase 1 sandbox.

## Run manually

```sh
/bin/bash bin/nightshift-dispatch run
/bin/bash bin/nightshift-dispatch digest
/bin/bash bin/nightshift-dispatch status
```

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

## Test

```sh
/bin/bash tests/run_tests.sh
```
