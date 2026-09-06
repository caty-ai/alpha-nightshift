# Contributing to alpha-nightshift

Thanks for your interest. This repository is the reference implementation of a
fail-closed nightly maintenance loop; contributions are welcome within its
safety boundaries.

## Prerequisites

- **bash 3.2+.** The loop targets the stock bash that ships on macOS.
- **GNU make.** `make test` and `make lint` are the canonical entry points
  (`make test` wraps `tests/run_tests.sh`).
- **`jq`** and **Python 3.9+** for the guard and publication-gate suites.
- **Optional `shellcheck`.** `make lint` requires it and fails without it
  (a lint that cannot fail is not a lint).
- **Platforms.** Every pull request runs the suite on Ubuntu and macOS via the
  family-dev-handbook reusable gates; ci.yml additionally runs the
  full-contract suite with pinned tool paths on hosted macOS.

## Ground rules

- **Issue first.** Open an issue with the why and the "done when" before
  sending a PR, and list the files you expect to touch.
- **Fail-closed is the design.** A change that turns a deny into an allow
  needs an explicit test proving the new allowance is safe. PRs that weaken
  a gate "for convenience" will be declined.
- **Suites must reconcile.** `make test` ends with
  `suites: declared=N executed=M skipped=K`; new suites are auto-discovered
  from `tests/test_*.sh`, and skips must print a reason.
- The loom runner template `tests/run.sh` has the same discovery and summary as
  `tests/run_tests.sh`; `make lint` fails if its contract table diverges.
  Do not add `TODO`/`SKIP`-shaped lines or exotic heredoc forms without reading
  the [engineering doc section](docs/engineering.md#loom-verifier-runner-template-testsrunsh).
- **Development rules.** This repo follows the
  [family-dev-handbook](https://github.com/caty-ai/family-dev-handbook)
  lane discipline (worktrees, review seats, completion records).

## Security-sensitive paths

Changes under `guard/` touch the remote-write boundary and get the strictest
review. See [SECURITY.md](SECURITY.md) for what counts as a vulnerability.
