# alpha-nightshift

Phase 0 is a macOS nightly observation harness. At 23:30 the dispatcher runs
credential-free observation lanes and serially ingests their JSONL proposals.
At 06:30 a separate machine-template digest reports findings, a clean zero, or
the dead-man condition where the nightly run never started. Phase 0 performs no
GitHub or network operations.

## Requirements

- macOS with `/bin/bash` 3.2
- `git` and `jq`
- standard BSD userland tools

Copy `config/nightshift.conf.example` to `config/nightshift.conf` and adjust the
numbered `LANE_CMD_n` values. Runtime state is stored under `state/` by default.

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
