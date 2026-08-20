← [Back to README](../README.md) ｜ 🇯🇵 [日本語版](engineering.ja.md)

## Overview

alpha-nightshift is a macOS nightly observation and repair harness for repository maintenance. At scheduled hours, the dispatcher launches credential-free observation lanes and sequences their JSONL proposals into a ledger. A separate daytime morning-triage command verifies findings, deduplicates across runs, and surfaces adoption decisions with evidence traces.

---

## Architecture

The system comprises eight core components working within isolation boundaries to maintain safety and auditability.

| Component | Paths | Responsibility |
|---|---|---|
| guard-publisher | `guard/publisher.sh`, `guard/publisher-lib.sh`, `guard/broker.sh`, `guard/remote-preflight.sh` | Enforced Phase 1a/1b publication gateway with deterministic preflight, Git-object scanning via pinned gitleaks 8.30.1, and fail-closed broker orchestration |
| night-bot | `launchd/`, `bin/nightshift-dispatch` | Dispatcher that runs credential-free observation lanes serially, manages worktree lifecycle, handles SIGINT gracefully, and enforces wall-clock timeouts |
| triage | `bin/morning-triage`, `lib/triage-*.sh`, `templates/` | Daytime read-only verification against current main, automatic deduplication across ledger history, and evidence-driven candidate ranking with GitHub integration |
| metsuke | `lanes/review/run.sh`, `lib/evidence.sh` | Multimodel review observation lane with deterministic DESIGN-lens assignment, rotating reviewer seats, JSONL parsing with persona reconstruction, and lane-HOME credential narrowing |
| drift-monitor | `guard/drift-monitor.sh` | Read-only control-plane drift check that verifies GitHub App permissions, webhook configuration, installation identity, and publishes only MATCH / DRIFT_DENY / MONITOR_UNVERIFIED verdicts |
| tests-ci | `.github/workflows/ci.yml`, `.github/workflows/test-lint.yml`, `tests/run_tests.sh` | GitHub-hosted reusable gates (ubuntu + macos) for lint and make test, plus self-hosted mac-mini full-contract suite with pinned tool verification |
| docs | `docs/*.md` | Design documentation including morning-triage specification, night-bot revocation runbook, and this engineering guide |
| i18n | `README.ja.md`, `README.zh.md`, `README.th.md`, `docs/*.ja.md` | Non-code translations: the front-door README in four languages, plus Japanese mirrors of the engineering and reference docs |

---

## Phase Status

### Current deployment: Phase 1a/1c

The checked-in package denies before key or network access. Its mode is `LOCAL_ONLY_REMOTE_UNPROVEN`, preflight always reports `write_mode:false`, and the example publisher policy remains inactive. Nothing in this round created or changed a user, GitHub App installation, token, protection, or ruleset. The existing Phase 0 dispatcher and lane behavior is unchanged.

**Phase 1a — Local enforcement:**

The local package provides a strict typed gateway, deterministic hard-disable preflight, a real Git-object scanner using pinned gitleaks 8.30.1 stdin, a rendered macOS sandbox-exec measurement profile, and offline bypass tests. Candidate-introduced binary, archive, executable, document, media, and opaque objects deny. Sandbox cells that cannot be expressed or measured remain `UNSUPPORTED` hard-disable residuals rather than containment claims. The local base evidence is only a deterministic aggregate of locally read object records; it does not prove protected-tip or remote equality.

The MIME allowlist is deliberately narrow (`text/plain`, `application/json`, recognized empty content only), so common source MIME types such as `text/x-shellscript` or `text/x-c` can also deny. Whole-payload wrapper or checksum shapes are fail-closed, so otherwise innocent Base64, hex, percent, or Base64url-shaped content may false-deny.

**Phase 1b/1c — Remote proof (unproven on live credentials):**

An orchestrator preflight found that protection for a private repository on GitHub Free returned 403. Activation therefore still requires a supporting private-repository plan/host, a dedicated GitHub App installed on exactly one repository, the night-bot broker identity that owns the App private key, and explicit owner authorization for potentially mutating remote proofs.

The only allowed publish target is a freshly generated `refs/heads/night-bot/run-YYYYMMDD-NNNN-HEX8` branch. Rule-suite correlation remains `UNPROVEN_NO_ADMIN_READ`, and any revoke or readback failure is an incident rather than a silent cleanup. Phase 1 must not be marked complete until remote proofs and protection readback succeed.

The read-only drift monitor reuses the publisher policy/JWT/read-IAT/readback machinery, never mints a `contents:write` token, and emits only `MATCH`, `DRIFT_DENY`, or `MONITOR_UNVERIFIED`. Its JWT preflight verifies exact App permissions/events, disabled webhook configuration, and exact installation identity before any token mint. The readback surface proves only current `main`/tags/releases/representative-ref equality and does not prove hidden `refs/notes/*` or `refs/replace/*` provenance.

**Phase 0 — Local observation (active):**

A macOS nightly observation harness runs credential-free observation lanes at 23:30 and serially ingests their JSONL proposals. At 06:30 a separate machine-template digest reports findings, a clean zero, or the dead-man condition where the nightly run never started. Phase 0 performs no GitHub or network operations in the harness itself. The separate daytime `verdict-sync` command can perform bounded read-only GitHub inspection when explicitly given a link file.

---

## CI and Testing

### GitHub-hosted reusable gates

The workflow `.github/workflows/test-lint.yml` uses a reusable gate from the family-dev-handbook at `ci-v1`:

```
uses: caty-ai/family-dev-handbook/.github/workflows/reusable-test-lint.yml@ci-v1
```

This gate runs `make test` and `make lint` on ubuntu and macOS (macOS run controlled by `run_macos: true`). Suite reconciliation is enforced on the ubuntu job (`require_suite_reconciliation: true`); the reusable does not reconcile on its macOS job.

The three test lanes deliberately cover different depths, because most of this suite is Darwin-native:

- **ubuntu** — the portable subset (Darwin-bound suites skip with printed per-suite reasons under a caller-declared skip cap), `make lint`, and the reconciliation arithmetic itself
- **hosted macOS** — everything except the suites bound to the pinned gitleaks/git contract paths that only the self-hosted runner installs
- **self-hosted mac-mini** (`ci.yml`) — the full 29-suite contract, with a step that fails if even one suite skipped

### Self-hosted mac-mini full-contract suite

The `.github/workflows/ci.yml` workflow runs on a self-hosted ARM64 macOS runner because it is the one lane that installs and verifies every suite contract — most importantly the Cellar-pinned git and gitleaks paths that hosted runners do not ship. Tool verification steps:

- ShellCheck installed and invoked on guard scripts
- Pinned gitleaks 8.30.1 binary with SHA-256 verification on every run (not only on install)
- Git compatibility path shim validating actual runner version
- System jq at `/usr/bin/jq` availability
- `sandbox-exec` availability (the sandbox suite would skip elsewhere; this lane fails loudly instead)
- Brew git at `/opt/homebrew/bin/git` availability

Execution and analysis:

- Bash syntax for all shell scripts
- ShellCheck linting of publisher surface and tests
- Full test suite via `tests/run_tests.sh`, followed by a zero-skip assertion (every contract is installed on this runner, so any skip means a contract silently broke)
- PR-range gitleaks scanning lives in the reusable caller `.github/workflows/gitleaks.yml`, not in this workflow

Fallback: if the self-hosted runner is unavailable, the workflow can be edited to use `runs-on: macos-15` (GitHub-hosted, 10x minute rate).

---

## Test Suite

The test suite is discovered and executed by `tests/run_tests.sh`.

### Test discovery and reconciliation

One suite is one `tests/test_*.sh` file. The runner globs those files, then checks the discovered count against `tests/expected_suite_count` and fails closed on any mismatch — so a suite that vanishes (or appears) without the census file being updated turns the run red instead of shrinking coverage silently. It prints a reconciliation line as its final summary:

```
suites: declared=N executed=M skipped=K
```

Where `N` is the discovered (census-checked) suite-file count, `M` were executed, and `K` were skipped. The ubuntu CI job additionally enforces `declared = executed + skipped`, a nonzero executed count, and a caller-declared skip cap.

### Environment contract skips

Before running a suite, the runner checks that suite's declared environment contracts and skips it with a printed `SKIP <suite>: missing contract <name>` line when one is absent. The contract vocabulary is closed:

- `darwin_userland` — BSD userland semantics (`date -v`, `stat -f`, macOS process behavior)
- `sandbox_exec` — the macOS `sandbox-exec` tool
- `pinned_gitleaks` — the hash-pinned gitleaks binary at its contract path
- `cellar_git_shim` / `brew_git` — the pinned and brew git paths the guard suites probe
- `system_jq` — `/usr/bin/jq`

A suite never skips while all of its contracts are present; a failing executed suite always exits the run nonzero. Suites with no macOS-bound contract (including the publication-gate selftest and the live publication-gate scan of the repo) run everywhere.

---

## Manual operation

The dispatcher supports manual invocation for testing and diagnostics:

```sh
/bin/bash bin/nightshift-dispatch run
/bin/bash bin/nightshift-dispatch digest
/bin/bash bin/nightshift-dispatch status
```

SIGINT (Ctrl+C) is handled as a prompt to interrupt the current run. A plain POSIX background job may inherit SIGINT ignored; use SIGTERM to stop that kind of launch.

---

## launchd installation

The checked-in plist files contain the literal `__NIGHTSHIFT_ROOT__` token. To install:

```sh
root=$(pwd -P)
for plist in launchd/ai.caty.nightshift.plist launchd/ai.caty.nightshift.digest.plist; do
  sed "s|__NIGHTSHIFT_ROOT__|$root|g" "$plist" \
    > "$HOME/Library/LaunchAgents/$(basename "$plist")"
  launchctl load "$HOME/Library/LaunchAgents/$(basename "$plist")"
done
mkdir -p state/logs
```

The run lock is `state/locks/nightshift.lock`. A stale lock is deliberately never removed automatically. Inspect its `meta` file and remove the lock directory manually only after confirming that the recorded process is gone.

---

## Related documentation

- [morning-triage design](morning-triage.md) — specification for daytime verdict verification and deduplication
- [night-bot revocation runbook](night-bot-revocation.md) — owner-driven containment procedure
- [DESIGN.md](../DESIGN.md) — full system architecture, design principles, and role assignments
