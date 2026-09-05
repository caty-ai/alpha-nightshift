# digest-lane-status design v1.3 — "Lane status" section from an external reporter (#16)

- Origin: caty-ai/alpha-nightshift #16 (size **L**: crosses a tool boundary and adds an input contract to a published component)
- Author: Alpha (design only; implementation writer = Codex GPT-5.6 Sol) · 2026-09-05 · owner mode: hands-off (push, then review)
- Upstream design: `DESIGN.md` §9 (morning digest), §2 principle 7 ("reflex = machine / deliberation = LLM"); [`docs/morning-triage.md`](morning-triage.md) for the digest → triage → report clock
- Owner decisions already taken (clarify batch 2026-09-05): **D-1** acquisition = a configured CLI command, not HTTP; **D-2** content = essentials only (counts + three short lists), full JSON saved to state
- Status: **v1.3 — FROZEN (v1.2 + implementation-review r1 corrections)** (3 heterogeneous seats; §13). Change log in §14.

## 0. In one sentence

Every morning the digest runs one operator-configured command under a minimal environment, expects a small documented JSON object on stdout, renders counts plus three capped lists (CI red on default branches, lanes owned by the human, stale lanes), saves the raw JSON next to the digest for drill-down, and **never** lets a failure of that command stop, silence, or dirty the rest of the digest.

## 1. Scope

### In scope (v1)

| # | Item | Done when |
|---|---|---|
| 1 | `## Lane status` section in the digest when `LANE_STATUS_CMD` is set: header counts + up to `LANE_STATUS_MAX_ROWS` rows per list, overflow line. **Extension recorded**: the header gains a seventh count `malformed rows N` (printed only when N > 0) — it is what keeps row-level tolerance (D-8) non-silent | (1) |
| 2 | Tool-agnostic input contract, documented in `docs/reference.md` / `.ja.md` and enforced by the renderer (§4 closed type / enum table) | (2) |
| 3 | Six fail-visible runtime paths, each tested, none changing the digest exit code (§8) | (3) |
| 4 | Raw JSON at `state/digests/<night>/lane-status.json` (0600), linked from the section by a **state-relative** path; command runs under the isolation of §5; stderr goes to the digest log only | (4) |
| 5 | `config/nightshift.conf.example` keys + `docs/engineering.md` / `.ja.md` manual try-out; a test greps the keys in the example and both reference tables | (5) |
| 6 | Fixture-driven tests incl. cap and every failure path; mutation checks | (6) |
| 7 | A real one-night digest with the section attached to the PR; existing digest tests green; CI green | (7) |

**Done-when amendments recorded for owner ratification at merge GO** (the design keeps them; the owner can strike either): (a) Done when (1) header + `malformed rows N`; (b) Done when (2) "a missing required field → unavailable" is read as **top-level** required keys; a **row** with a missing / mistyped field is excluded and counted (D-8) instead of blanking the whole section.

### Out of scope (explicit)

- Running the lane scan inside this repository (the reporter stays an external tool; this document names it only as *the lane-status reporter*).
- Any write-back to repositories, labels, or Issues; reconciling lane status with org-consistency findings; changing which repositories the night lanes target; changing the ledger schema (`digest_written` records keep their fields).
- HTTP acquisition, retries, caching across nights, `sandbox-exec` wrapping, a long-form rendering.

## 2. Invariants (design → code mapping)

1. **Fail-visible, never fatal.** No **acquisition or validation** outcome changes the digest's exit code or its `digest_written` ledger record. Code contract: `digest_lane_status_block` **returns 0 on every runtime path** (§8 rows 1–7, plus state-dir problems, D-11) after emitting its lines; it returns non-zero **only** for invariant 6. In `digest_command` the `if ! … ; then return 1` guard wraps **only** the config validation call, never the acquisition call. Every subcommand inside the block is guarded (`if …; then`), `wait` is captured as in `budget_check` (`if wait "$pid"; then rc=0; else rc=$?; fi`), and `jq -e` results are tested, never bare, because `lib/digest.sh` runs under `set -euo pipefail`.
2. **Never silent.** The footer **always** carries one line `lane status: ok (…)` / `lane status: unavailable (<reason>)` / `lane status: not configured`; there is no state in which the digest says nothing about lane status.
3. **stderr never reaches the digest.** The reporter's stderr is captured to a file; its first three lines (each cut at 200 bytes, control characters stripped) are re-emitted via `nightshift_log WARN` into the digest log. The digest body is built only from validated, whitelisted JSON fields, each sanitized (§7) — including `number`.
4. **Tool-agnostic contract.** The renderer depends on the §4 shape only. No option, file, or name of the reporter is baked into `lib/digest.sh`; `nightshift.conf.example` shows a placeholder absolute path.
5. **Bounded at write time.** One command; one timeout (`LANE_STATUS_TIMEOUT_SEC`, default 120); stdout and stderr files bounded **while the reporter runs** by `ulimit -f 2048` (bash 3.2 on macOS counts 1 KiB blocks = 2 MiB) inside the launch subshell — an oversize write gets `SIGXFSZ`, the run ends non-zero, and a stdout file of ≥ 2 MiB renders `unavailable (output too large)`; row cap per list (`LANE_STATUS_MAX_ROWS`, default 10) with a visible `… +N more` line; stderr excerpt 3 × 200 bytes. Nothing is retried.
6. **Operator-trusted configuration fails closed.** Malformed `LANE_STATUS_TIMEOUT_SEC` / `LANE_STATUS_MAX_ROWS` (non-integer, zero, > 7 digits) make the digest fail with an ERROR log line, exactly like `OC_REPORT_MAX_AGE_DAYS` today. This is a **pre-runtime** path (§8 row 0), deliberately outside Done when (3)'s six runtime paths (D-4).
7. **bash 3.2 / POSIX userland**: no `timeout(1)`, no associative arrays, no `mapfile`, `${11}`-style positional references; `jq` is the only parser. Fractional `sleep` is already relied upon by `lib/budget.sh`.
8. **Concurrency-safe by construction.** The digest takes no lock today; every working path this feature creates is unique per run (`mktemp -d` under the night dir), and only the two final files have fixed names (last writer wins, like the digest itself).

## 3. Architecture placement

```
06:30 digest (bin/nightshift-dispatch digest_command)
  ledger projection → findings block → budget/lane stats → org-consistency freshness
  → NEW digest_lane_status_validate_config   → non-zero = digest fails closed (invariant 6; the ONLY `if !` guard)
  → NEW digest_lane_status_block             → always returns 0; prints SECTION and FOOTER_LINE via two variables
       ├─ not configured?                     → SECTION="" · FOOTER_LINE="lane status: not configured"
       ├─ digest_lane_status_run              → isolated subprocess (§5): rc / timed_out / stdout / stderr files
       ├─ digest_lane_status_check            → §4 contract (jq)          → reason or accept
       ├─ mv <run>/stdout → <night>/lane-status.json (0600); cp stderr → <night>/lane-status.stderr (0600)
       └─ digest_lane_status_render           → SECTION (heading + header + 3 lists + raw link) · FOOTER_LINE
  → digest_render_template (templates/digest.md gains {{LANE_STATUS_SECTION}} and {{LANE_STATUS_FOOTER}})
06:35 morning-triage (unchanged) · 07:05 morning-report (unchanged)
```

`digest_command` grows by two calls and two template arguments; all logic lives in `lib/digest.sh` so `tests/test_digest_lane_status.sh` can drive it through `bin/nightshift-dispatch digest` (integration, like `test_digest.sh`) **and** call the pure functions directly (boundary cases).

## 4. Input contract (the only thing the reporter and the digest share)

The reporter prints **exactly one JSON value** — an object — to stdout and exits 0. Unknown top-level keys and unknown row fields are ignored.

```json
{
  "ci_red":   [ { "repo": "owner/name", "scope": "main", "branch": "main", "workflow": "ci",
                  "conclusion": "failure", "since": "2026-09-01T15:02:11Z" } ],
  "lanes":    [ { "repo": "owner/name", "kind": "issue", "number": 42, "title": "…",
                  "owner": "human", "stale": false, "reason": "ball:human", "state": "hold" } ],
  "roster":   { "repos": [ "owner/name", "…" ] },
  "errors":   [ { "repo": "owner/name", "message": "…" } ],
  "truncated": [ "LIST TRUNCATED: owner/name pulls" ]
}
```

### 4.1 Top level (a failure here = `unavailable (contract: …)`, checked in this order, first failure wins)

| Step | Rule | Reason string |
|---|---|---|
| 1 | stdout file size ≥ 2 MiB (the `ulimit` bound) | `output too large` |
| 2 | stdout non-empty | `empty output` |
| 3 | `jq -s 'length == 1'` — exactly one JSON value | `contract: not JSON` (parse failure) / `contract: not a single JSON value` |
| 4 | `type == "object"` | `contract: not an object` |
| 5 | `ci_red` present and `type == "array"` | `contract: ci_red missing` / `contract: ci_red not an array` |
| 6 | `lanes` present and `type == "array"` | `contract: lanes missing` / `contract: lanes not an array` |
| 7 | `roster` present, `type == "object"`, `.repos` present and an array of strings | `contract: roster missing` / `contract: roster.repos missing` / `contract: roster.repos not an array of strings` |
| 8 | `errors` / `truncated`: **optional**; when present must be arrays, else `contract: errors not an array` / `contract: truncated not an array`; when absent they count as `[]` (D-10) | |

### 4.2 Rows (never fatal; judged on the **unfiltered** arrays; a failing row is excluded from lists and counted once in `malformed rows N`)

"Missing" means: key absent, `null`, or wrong type.

| Array | Field | Type | Enum | Printed |
|---|---|---|---|---|
| `ci_red` | `repo` | string | — | yes |
| | `scope` | string | `main` \| `pr` \| `branch` (closed; anything else → malformed) | no (filter) |
| | `branch` | string | — | yes |
| | `workflow` | string | — | yes |
| | `conclusion` | string | — | no |
| | `since` | string | — | yes (verbatim; may carry `≥`) |
| `lanes` | `repo` | string | — | yes |
| | `kind` | string | `pr` \| `issue` (anything else → malformed) | no |
| | `number` | **integer** (JSON number) | — | yes (via sanitizer, as a string) |
| | `title` | string | — | yes |
| | `owner` | string | `human` \| `alpha` \| `unknown` (anything else → malformed) | no (filter) |
| | `stale` | boolean | — | no (filter) |
| | `reason` | string | — | yes |
| | `state` | string, optional | — | no |

`scope: "main"` is the reporter's token for "the repository's default branch, whatever its name" (the reporter, not the digest, knows the default branch); `branch` is the branch name and is printed. Reporters **must** emit `scope: "main"` for default-branch reds regardless of the branch's name; the digest never infers scope from `branch`.

### 4.3 Header counts (from the validated, uncapped arrays)

`repos` = `roster.repos | length` · `ci red` = valid `ci_red` rows with `scope == "main"` · `human-owned lanes` = valid `lanes` rows with `owner == "human"` · `stale lanes` = valid `lanes` rows with `stale == true` (any owner; a human-owned stale lane appears in both lists — intended) · `errors` / `truncated` = array lengths (absent = 0) · `malformed rows` = excluded rows across both arrays.

## 5. Execution model and isolation (D-1, D-3 revised)

`digest_lane_status_run "$LANE_STATUS_CMD" "$LANE_STATUS_TIMEOUT_SEC" "$night_dir"`:

- Paths: `night_dir = $STATE_DIR/digests/$NIGHT_ID` created `0700` **only when the command is configured**; a per-run scratch `run_dir=$(mktemp -d "$night_dir/.run.XXXXXX")` holding `work/` (cwd), `tmp/` (`TMPDIR`), `home/` (quarantined `HOME` with the lane-style empty-helper `.gitconfig`), `stdout`, `stderr`. `run_dir` is removed after the run; only `lane-status.json` and `lane-status.stderr` (fixed names, `0600`, last writer wins) remain.
- Launch — replicate the `budget_check` frame **verbatim** (the `set -m` wrapper is load-bearing: `nightshift_stop_process_tree` ends with a process-group kill that only binds when the child is a group leader; measured on this platform by seat review):

  ```bash
  NIGHTSHIFT_PROCESS_INSPECTION_FAILED=false
  set -m
  (
    exec 3>&- 4>&-                        # do not inherit the pre-logging stdout/stderr of the dispatcher
    ulimit -f 2048                        # bash 3.2 on macOS counts 1 KiB blocks: 2048 = 2 MiB (v1.3; measured)
    cd "$run_dir/work" || exit 125
    exec env -i \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin \
      HOME="$run_dir/home" \
      TMPDIR="$run_dir/tmp" \
      LANG="$LANG" TERM=dumb NIGHT_ID="$NIGHT_ID" \
      GIT_CEILING_DIRECTORIES="$run_dir" \
      GH_CONFIG_DIR="${GH_CONFIG_DIR:-$HOME/.config/gh}" \
      /bin/bash -c "$LANE_STATUS_CMD"
  ) </dev/null >"$run_dir/stdout" 2>"$run_dir/stderr" &
  pid=$!
  set +m
  ```

  then the launch-window tick loop (10 × `sleep 0.01`, sampling descendants), the deadline loop (`nightshift_process_tree_alive` at 0.1 s, `nightshift_stop_process_tree` on the deadline), `if wait "$pid"; then rc=0; else rc=$?; fi`, and the post-exit sweep — all as `lib/budget.sh` lines 40–95. Redirections are **absolute** (a relative redirection is opened in the dispatcher's cwd, i.e. the repository). This is the complete allow-list; prose elsewhere does not add variables.
- **`HOME` is quarantined; `GH_CONFIG_DIR` is the single credential carve-out** (D-3): the reporter authenticates to GitHub through `gh`, whose file-based auth lives in the operator's `gh` config directory. Passing that one directory (read-write — `gh` may refresh its own files) removes the **`HOME`-lookup** path to `.ssh`, `.netrc`, `.aws`, `.gnupg`, `.git-credentials` (nothing resolves `~` to them any more); it does not stop an operator-trusted command from walking the filesystem — `sandbox-exec` remains out of scope. The `GH_CONFIG_DIR` default is expanded in the dispatcher shell **before** `env -i` reassigns `HOME`, so it names the operator's directory, never the quarantined one. Consequences documented in `docs/reference.md`: env-token auth (`GH_TOKEN` / `GITHUB_TOKEN`) is **not** passed (a reporter relying on it fails visibly as `unavailable (exit N)`); `PATH` has no version-manager shim directories, so `LANE_STATUS_CMD` should be an absolute path to an operator-controlled wrapper that sets up its own interpreter. Descendant survivors after the sweep are logged WARN and do not change the verdict.
- Outcome precedence (a run can match several rows; the first applicable wins): process inspection unavailable → timeout → **output too large** (stdout file size ≥ 2 MiB **or** wait status = 128 + SIGXFSZ, checked before `run_dir` is removed) → `rc = 127` (`command not found`) → other non-zero rc (`exit <rc>`) → empty output → contract steps 3–8. A stderr file hitting the cap while stdout stays small is reported as `exit <rc>` (acceptable: the reporter died of its own noise). `ulimit` and `wait` are guarded so a signal-terminated child can never `set -e` the parent.
- Only after §4.1 passes is `run_dir/stdout` moved to `lane-status.json` and chmod'ed `0600`; `run_dir/stderr` is always copied to `lane-status.stderr` (`0600`). On failure the raw JSON is **never** written (D-6).
- "No network beyond `gh`, no write outside the state dir" is the **reporter's contract**, stated in `docs/reference.md` next to the JSON shape and in `nightshift.conf.example`. The cwd, `TMPDIR`, `HOME` under `run_dir` make accidental writes land in state, and `GIT_CEILING_DIRECTORIES` keeps a stray `git` from discovering this repository; v1 does not wrap the command in `sandbox-exec`.

## 6. Configuration (`LANE_STATUS_*`, daytime scope, not exported into lanes)

| Key | Default | Meaning |
|---|---|---|
| `LANE_STATUS_CMD` | unset | Shell command string run by `/bin/bash -c` in the §5 environment; must print the §4 object to stdout. Unset or empty = not configured. Read as `${LANE_STATUS_CMD:-}` (never defaulted or validated in `nightshift_init`, so `run` cannot fail on an unused key). |
| `LANE_STATUS_TIMEOUT_SEC` | `120` | Positive integer (≤ 7 digits). Fail closed when malformed (invariant 6). |
| `LANE_STATUS_MAX_ROWS` | `10` | Positive integer (≤ 7 digits). Rows per list before the overflow line. Fail closed when malformed. |

Like `OC_FRESHNESS_*`, these are read by the dispatcher outside `env -i`, so top-level assignments in `nightshift.conf` work. `nightshift.conf.example` ships them commented out with a placeholder absolute path; the example never names a real host, user, or repository.

## 7. Rendering

Template: `templates/digest.md` gains **two** placeholders: `{{LANE_STATUS_SECTION}}` between the `## 観測結果` block and `## Footer` (the section, or an empty line), and `{{LANE_STATUS_FOOTER}}` at the end of `## Footer` (always one line — Done when (3)'s "footer says …"). `digest_render_template` gains two positional arguments (`${11}`, `${12}`).

| state | section | footer line |
|---|---|---|
| not configured | *(empty)* | `lane status: not configured` |
| configured, failed | `## Lane status` + blank + `lane status: unavailable (<reason>)` | `lane status: unavailable (<reason>)` |
| configured, valid | below | `lane status: ok (repos N · ci red N · human-owned lanes N · stale lanes N)` |

Valid section:

```
## Lane status

repos N · ci red N · human-owned lanes N · stale lanes N · errors N · truncated N[ · malformed rows N]

### CI red (default branches)
- repo · workflow · branch · since
… +N more (see lane-status.json)

### Human-owned lanes
- repo#number · title · reason

### Stale lanes
- repo#number · title · reason

raw: digests/<night>/lane-status.json
```

- Each list prints `none` when empty and never an overflow line. The overflow line appears only when the **filtered, validated** list exceeds the cap; `N` = that list's length − cap. Header counts are taken before capping (§4.3) — the cap test pins `ci red 12` next to `… +2 more`.
- Ordering (deterministic, ties broken by the next key): CI red by `repo`, `workflow`, `branch`, `since`; lanes by `repo`, `number` (numeric), `kind`.
- Sanitizer (applied in `jq` to **every** printed value, numbers included, before it enters a line): `\r\n\t` → space, other control characters (U+0000–U+001F, U+007F) removed, then cut at **120 characters** (codepoints, `.[0:120]`, UTF-8 safe) with `…`. Nothing from `errors[].message` or `truncated[]` is printed (counts only). `digest_render_template` substitutes only whole template lines that equal a `{{…}}` token and never re-scans substituted text (verified by seats), so a title equal to `{{FINDINGS_BLOCK}}` renders literally; the sanitization test still pins it.
- The `raw:` path is **relative to `STATE_DIR`** so the digest never carries a host path (Done when (7) attaches a digest to a public PR).

## 8. Fail-visible paths (Done when 3) and what each looks like

| # | Path | Section line | Footer line | Log | Digest exit |
|---|---|---|---|---|---|
| 0 | malformed `LANE_STATUS_TIMEOUT_SEC` / `_MAX_ROWS` (pre-runtime, invariant 6) | — (digest fails) | — | ERROR | **1** (fail closed, as `OC_REPORT_MAX_AGE_DAYS`) |
| 1 | `LANE_STATUS_CMD` unset/empty | *(no section)* | `lane status: not configured` | none | unchanged |
| 2 | command not found (`rc = 127`) | `unavailable (command not found)` | same | WARN + stderr excerpt | unchanged |
| 3 | timeout | `unavailable (timeout after <N>s)` | same | WARN | unchanged |
| 4 | non-zero exit | `unavailable (exit <rc>)` | same | WARN + stderr excerpt | unchanged |
| 5 | non-JSON stdout / empty / too large / several values | `unavailable (contract: not JSON)` / `(empty output)` / `(output too large)` / `(contract: not a single JSON value)` | same | WARN | unchanged |
| 6 | JSON missing `lanes` (or any §4.1 failure) | `unavailable (contract: lanes missing)` etc. | same | WARN | unchanged |
| 7 | process inspection unavailable (`NIGHTSHIFT_PROCESS_INSPECTION_FAILED`) | `unavailable (process inspection unavailable)` | same | ERROR | unchanged (**not** the budget meter-error path) |
| 8 | state-dir problem (`mkdir`/`mktemp`/`mv`/`chmod` failure — D-11) | `unavailable (state: <what> failed)` | same | ERROR | unchanged |

In rows 2–8 the raw file is **not** written; the stderr file is copied when it exists. `state/digests/<night>/` may therefore exist without `lane-status.json` — the `raw:` line is printed only on success.

## 9. State layout and retention

```
state/digests/<night>.md                 (existing)
state/digests/<night>/                   0700 — created only when LANE_STATUS_CMD is configured
state/digests/<night>/.run.XXXXXX/       per-run scratch (work/ tmp/ home/ stdout stderr) — removed after the run
state/digests/<night>/lane-status.json   0600 — written only on success, byte-identical to the reporter's stdout
state/digests/<night>/lane-status.stderr 0600 — copied on every run that launched the command (may be empty)
```

Retention: identical to the digest itself (no automatic pruning). A re-run for the same night overwrites the two fixed-name files (last writer wins); concurrent runs cannot corrupt each other's scratch (invariant 8). The previous night's `lane-status.json` is removed **before** the reporter runs so a stale raw file can never sit next to a failed run; with two concurrent digests for one night this means run A's digest may link a raw file that run B has just replaced — accepted under last-writer-wins (v1.3).

## 10. Tests (`tests/test_digest_lane_status.sh`, counted suite; `tests/expected_suite_count` 42 → 43; `tests/run_tests.sh` `suite_contracts` gets the same contract as `test_digest.sh`)

Fake reporters are tiny scripts written into the test's temp dir (no network, no real tool). Fixtures under `tests/fixtures/lane-status/`: `happy.json` (2 `main` reds + 1 `pr` red, 3 human lanes, 2 stale lanes incl. one `alpha`, 1 error, 1 truncated, 1 malformed lane row, 1 `scope: "default"` red row → malformed), `overflow.json` (12 main reds, 12 human lanes, 12 stale lanes), `missing-lanes.json`, `not-object.json` (a JSON array), `no-errors-key.json` (errors/truncated absent). All repository names are synthetic (`example/alpha` …).

- Happy path: heading, header counts (`repos 3 · ci red 2 · human-owned lanes 3 · stale lanes 2 · errors 1 · truncated 1 · malformed rows 2`), one row per list in the stated format and order, `pr`-scope red absent from the list, `raw: digests/<night>/lane-status.json`, footer `lane status: ok (…)`, file exists with mode `0600` and `cmp`-equal to the fixture, stderr file exists, no `.run.*` directory remains, digest exit 0, `digest_written` record unchanged in shape.
- Optional keys: `no-errors-key.json` → `errors 0 · truncated 0`, still `ok`.
- Cap: `LANE_STATUS_MAX_ROWS=10` → each list shows 10 rows, `… +2 more (see lane-status.json)`, **and the header still says `ci red 12 · human-owned lanes 12 · stale lanes 12`**; `=1` → `… +11 more`; a list with 0 or 1 rows at `=1` has no overflow line.
- Each of §8 rows 1–6 (timeout: `LANE_STATUS_TIMEOUT_SEC=1`, reporter sleeps 5; expected wall-clock ≈ 1 s deadline + launch window, assert generously), row 7 (force `NIGHTSHIFT_PROCESS_INSPECTION_FAILED` through the existing test hook used by `test_process_inspection_failclosed.sh`: footer `unavailable (process inspection unavailable)`, digest exit 0, **no** `meter_error` ledger row) and row 8 (unwritable night dir): the exact section and footer lines, digest exit 0, no `lane-status.json`, stderr excerpt present in `state/logs/digest-<night>.log` and absent from the digest.
- Too large: a reporter that writes > 2 MiB → `unavailable (output too large)` (not `exit 153`), the size is measured before the run dir is removed and is ≤ 2 MiB (the `ulimit` bound held), digest exit 0.
- stderr isolation: a reporter that prints a sentinel to stderr and valid JSON to stdout → sentinel in the log and in `lane-status.stderr`, not in the digest.
- Sanitization: a title containing a newline, a multibyte title longer than 120 characters (cut at 120 codepoints with `…`, no broken sequence), a title equal to `{{FINDINGS_BLOCK}}` (renders literally), `number` as a string with a newline → that row is malformed (integer required).
- Config fail-closed: `LANE_STATUS_TIMEOUT_SEC=abc` / `LANE_STATUS_MAX_ROWS=0` → `run_digest` fails (non-zero), ERROR logged; `run` (not digest) with the same bad values is unaffected.
- Isolation: the fake reporter prints `$HOME`, `$PWD`, `$TMPDIR`, `$GIT_CEILING_DIRECTORIES`, `$GH_CONFIG_DIR`, `$SENTINEL_ENV` to stderr → `HOME`/`PWD`/`TMPDIR`/`GIT_CEILING_DIRECTORIES` are under the night dir, `GH_CONFIG_DIR` equals the test's value, `SENTINEL_ENV` is empty; a file the reporter writes to `$HOME/x` lands under the run dir and is gone after the run.
- Docs / example (Done when 5): the three keys appear in `config/nightshift.conf.example`, `docs/reference.md`, `docs/reference.ja.md`; `docs/engineering.md` and `.ja.md` mention `LANE_STATUS_CMD` in Manual operation.
- **Mutation checks (reviewer sweep, each must turn a test red)**: remove the cap → the overflow test; make a non-zero exit fall through to rendering → the `exit <rc>` test; delete the `unavailable` line → every §8 test; drop `set -m` → the timeout test (sleeper survives, run exceeds the bound); skip `chmod 0600` → the mode test; write the raw file before validation → the missing-`lanes` "no raw file" test; count rows after slicing → the cap-header test.

## 11. Files to touch (WIP declaration must match)

New: `lib/digest.sh` functions (`digest_lane_status_validate_config`, `digest_lane_status_run`, `digest_lane_status_check`, `digest_lane_status_render`, `digest_lane_status_block`) · `docs/digest-lane-status.md` (this) · `tests/test_digest_lane_status.sh` · `tests/fixtures/lane-status/*.json`

Changed: `bin/nightshift-dispatch` (`digest_command`: two calls + two template arguments) · `templates/digest.md` (two placeholders) · `config/nightshift.conf.example` · `docs/reference.md` + `docs/reference.ja.md` (settings table + contract) · `docs/engineering.md` + `docs/engineering.ja.md` ("Manual operation") · `tests/expected_suite_count` · `tests/run_tests.sh` (`suite_contracts` entry)

Not changed: `lib/ledger.sh`, `lib/verdict.sh`, `lib/lock.sh`, `lib/lane-env.sh`, `lib/budget.sh`, `lib/common.sh`, `bin/morning-triage`, `lanes/**`, `guard/**`, `launchd/**`, README files.

## 12. Decision log

| # | Question | Decision | Why |
|---|---|---|---|
| D-1 (owner) | acquisition | configured CLI command (`LANE_STATUS_CMD`) | no dependency on a running dashboard; the night stack already runs configured commands |
| D-2 (owner) | content | counts + three capped lists; raw JSON to state | the digest is a one-page morning read; drill-down has a file |
| D-3 (rev.) | `HOME` in the isolated environment | **quarantined `HOME` + `GH_CONFIG_DIR` passthrough only** | `gh` file auth needs one directory; a full `HOME` would expose `.ssh`/`.netrc`/`.aws` and let the reporter write outside state (Grok r1) |
| D-4 | malformed `LANE_STATUS_*` values | fail closed (digest returns 1), §8 row 0, outside Done when (3) | same as `OC_REPORT_MAX_AGE_DAYS`; config bugs must surface before the first morning (Opus/Grok r1 accepted) |
| D-5 (rev.) | CI red list scope | `scope == "main"` with a **closed enum** `main|pr|branch`; unknown → malformed row | the reporter knows the default branch; an unknown token must be visible, not an empty list |
| D-6 | raw file on failure | never written | a half-valid file would be mistaken for a good night |
| D-7 (rev.) | not-configured rendering | footer line always; section only when configured | Done when (3) "footer says …" taken literally; never silent |
| D-8 | row-level contract problems | count as `malformed rows N`, never fatal | recorded as a Done when (2) amendment for owner ratification (§1) |
| D-9 | sanitization | control chars stripped, 120-codepoint cut, whitelisted fields only, numbers included | reporter output is data, not template |
| D-10 | `errors` / `truncated` absent | treated as `[]` | count-only keys must not blank the section for a minimal reporter |
| D-11 | state-dir failures (`mkdir`/`mktemp`/`mv`/`chmod`) | `unavailable (state: … failed)`, return 0 | one rc contract for the whole block; the digest's own write failure still fails the digest as today |

## 13. Design review record (L1-9, round 1, 2026-09-05)

| seat | requested → actual | verdict | adopted findings |
|---|---|---|---|
| Kimi K3 | kimi-k3 → **absent** (weekly quota) | — | — |
| Grok 4.6 | grok-4.6 (deterministic substitute; reviewed the whole design) | **NO-GO** | C1 rc contract under `set -e` (→ invariant 1 rewritten, §3, §8 row 7/8); C2 `set -m` + absolute redirections + `GIT_CEILING` in the list (→ §5 verbatim frame); M3 write-time cap (→ `ulimit -f`); M4 closed contract table (→ §4.2, single JSON value); M5 header counts pinned uncapped (→ §7, §10); M6 quarantined HOME + `GH_CONFIG_DIR` (→ D-3); M7 footer placeholder (→ two placeholders); M8 `docs/engineering.ja.md` + `${11}` (→ §11, invariant 7); m9 D-4 kept explicit; m10 relative `raw:` path; n11 night dir only when configured, tie-breaks |
| Opus 5 | opus-5 → opus-5 (Agent, final-message delivery) | GO-WITH-CHANGES | M-1 `set -m` (measured); M-2 `mktemp -d` per run; M-3 write-time bound; M-4 `scope` enum + malformed; M-5 `number` sanitized/type-checked; M-6 relative `raw:`; M-7 Done when (5) test; m-1 invariant 1 scoped; m-2 absolute redirections; m-3 `set -e` guards + inspection flag reset; m-4 footer placement; m-5 `roster` type rule + optional `errors`/`truncated` (D-10); m-6 env-token / PATH documented; n-1 timeout test timing. Coverage matrix: (5) ZERO-COVERAGE → fixed; no unrequested MAJOR |
| GLM 5.3 | glm-5.3 → glm-5.3 | GO-WITH-CHANGES | 1 relative `raw:` (publication gate); 2 D-8 as recorded Done when (2) amendment for owner ratification (→ §1); 3 closed enums / types / unfiltered malformed count; 4 `set -m`; 5 unique scratch; 6 absolute redirections + single allow-list; 7 codepoint cut; 8 footer placement; 9 mkdir/mv branch (→ D-11), rc precedence (→ §5), fd 3/4 (→ `exec 3>&- 4>&-`) |

Rejected: none. Kept against one seat: D-4 fail-closed config (Grok m9 preferred `unavailable (config: …)`; Opus and GLM endorsed the `OC_REPORT_MAX_AGE_DAYS` precedent; kept, explicitly outside Done when (3)).

Grok delta on v1.1 (same seat, whole-design re-read): **cumulative GO-WITH-CHANGES** — C1/C2/M4–M8/m9/m10/n11 RESOLVED, M3 PARTIAL → N1 MAJOR (SIGXFSZ oversize run would have rendered `exit 153` under the v1.1 precedence) → v1.2 moves *output too large* ahead of `exit <rc>` and keys it on size **or** wait status; N2 MINOR (soften the `HOME` claim; compute `GH_CONFIG_DIR` before `HOME` is reassigned) → §5; N3 MINOR (test §8 row 7) → §10. Final quorum: Opus GO-WITH-CHANGES · GLM GO-WITH-CHANGES · Grok GO-WITH-CHANGES (cumulative). Frozen at v1.2.

## 14. Change log

- v1.0 (2026-09-05): first draft for upstream review.
- v1.1 (2026-09-05, after r1): rc contract (invariant 1, §3), verbatim `budget_check` launch frame with `set -m`, absolute redirections, `ulimit -f`, fd 3/4 closed, quarantined `HOME` + `GH_CONFIG_DIR` (D-3), per-run `mktemp -d` scratch (invariant 8), closed contract table with `scope` / `kind` / `owner` enums and integer `number` (§4.2), optional `errors` / `truncated` (D-10), single-JSON-value check, outcome precedence, two template placeholders (D-7), state-relative `raw:` path, codepoint cut, cap-header pin and overflow semantics, §8 rows 0 / 7 / 8, Done when (5) test, `docs/engineering.ja.md` in the file set, Done-when amendments (a)(b) recorded for owner ratification.
- v1.3 (2026-09-05, after implementation review r1): `ulimit -f` value corrected to the bash 3.2 / macOS unit (1 KiB blocks → `2048` for 2 MiB; writer measured, seats confirmed); the timeout test proves the process-tree kill by checking the reporter's forked child is dead after the digest returns, with a generous wall-clock bound (a hosted macOS runner needed > 4 s for the normal path); `LANG` passed as `${LANG:-C}`.
- v1.2 (2026-09-05, after the Grok delta): *output too large* outranks `exit <rc>` and is keyed on size or SIGXFSZ wait status (§5); `HOME` claim softened and `GH_CONFIG_DIR` default expanded before `env -i` (§5); §8 row 7 test added (§10). Frozen.
