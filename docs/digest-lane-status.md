# digest-lane-status design v1.0 — "Lane status" section from an external reporter (#16)

- Origin: caty-ai/alpha-nightshift #16 (size **L**: crosses a tool boundary and adds an input contract to a published component)
- Author: Alpha (design only; implementation writer = Codex GPT-5.6 Sol) · 2026-09-05 · owner mode: hands-off (push, then review)
- Upstream design: `DESIGN.md` §9 (morning digest), §2 principle 7 ("reflex = machine / deliberation = LLM"); [`docs/morning-triage.md`](morning-triage.md) for the digest → triage → report clock
- Owner decisions already taken (clarify batch 2026-09-05): **D-1** acquisition = a configured CLI command, not HTTP; **D-2** content = essentials only (counts + three short lists), full JSON saved to state
- Status: **draft for L1-9 upstream review** (3 heterogeneous seats) — §13 records the review

## 0. In one sentence

Every morning the digest runs one operator-configured command, expects a small documented JSON shape on stdout, renders counts plus three capped lists (CI red on default branches, lanes owned by the human, stale lanes), saves the raw JSON next to the digest for drill-down, and **never** lets a failure of that command stop, silence, or dirty the rest of the digest.

## 1. Scope

### In scope (v1)

| # | Item | Done when |
|---|---|---|
| 1 | `## Lane status` section in the digest when `LANE_STATUS_CMD` is set: header counts + up to `LANE_STATUS_MAX_ROWS` rows per list, overflow line | (1) |
| 2 | Tool-agnostic input contract, documented in `docs/reference.md` / `.ja.md` and enforced by the renderer | (2) |
| 3 | Six fail-visible paths, each tested, none changing the digest exit code | (3) |
| 4 | Raw JSON at `state/digests/<night>/lane-status.json` (0600), linked from the section; command runs under the daytime isolation described in §5; stderr goes to the digest log only | (4) |
| 5 | `config/nightshift.conf.example` keys + `docs/engineering.md` manual try-out | (5) |
| 6 | Fixture-driven tests incl. cap and every failure path; mutation checks | (6) |
| 7 | A real one-night digest with the section attached to the PR; existing digest tests green; CI green | (7) |

### Out of scope (explicit)

- Running the lane scan inside this repository (the reporter stays an external tool; this document names it only as *the lane-status reporter*).
- Any write-back to repositories, labels, or Issues.
- Reconciling lane status with org-consistency findings (that join lives on the reporter's side).
- Changing which repositories the night lanes target; changing the ledger schema (`digest_written` records keep their fields).
- HTTP acquisition, retries, caching across nights, or a second placeholder in the template for a "short" and "long" form.

## 2. Invariants (design → code mapping)

1. **Fail-visible, never fatal.** Any failure of acquisition or validation renders one line `lane status: unavailable (<reason>)` inside the section and the digest continues. The digest's exit code and its `digest_written` ledger record are unchanged by the section's outcome (`run_digest` in tests must succeed on every failure path).
2. **Never silent.** With the command unset the digest prints `lane status: not configured` (single line, no section heading) so an operator who forgot to configure it sees the gap every morning; there is no state in which the digest says nothing about lane status.
3. **stderr never reaches the digest.** The reporter's stderr is captured to a file and its first lines are re-emitted through `nightshift_log WARN` into the digest log; the digest body is built only from validated JSON fields, each sanitized (§7).
4. **Tool-agnostic contract.** The renderer depends on the JSON shape in §4 only. No option, file, or name of the reporter is baked into `lib/digest.sh`; `nightshift.conf.example` shows a placeholder absolute path.
5. **Bounded.** One command, one timeout (`LANE_STATUS_TIMEOUT_SEC`, default 120), one output size cap (2 MiB on stdout → `unavailable (output too large)`), one row cap per list (`LANE_STATUS_MAX_ROWS`, default 10) with a visible `… +N more` line. Nothing is retried.
6. **Operator-trusted configuration fails closed.** Malformed `LANE_STATUS_TIMEOUT_SEC` / `LANE_STATUS_MAX_ROWS` (non-integer, zero, > 7 digits) make the digest fail with an ERROR log line, exactly like `OC_REPORT_MAX_AGE_DAYS` today — config errors are not "unavailable" runtime paths; they are bugs the operator must see before the first morning.
7. **bash 3.2 / POSIX userland**: no `timeout(1)`, no associative arrays, no `mapfile`; `jq` is the only parser (already a hard dependency).

## 3. Architecture placement

```
06:30 digest (bin/nightshift-dispatch digest_command)
  ledger projection → findings block → budget/lane stats → org-consistency freshness
  → NEW digest_lane_status_block  (lib/digest.sh)
       ├─ config validation (LANE_STATUS_*)              → fail closed on malformed config (invariant 6)
       ├─ not configured?                               → "lane status: not configured"
       ├─ digest_lane_status_run: isolated subprocess    → stdout.tmp / stderr file / rc / timed_out
       ├─ contract check (jq)                           → "unavailable (contract: …)" or accept
       ├─ mv stdout.tmp → state/digests/<night>/lane-status.json (0600)
       └─ render header + 3 lists + overflow + raw link
  → digest_render_template (templates/digest.md gains {{LANE_STATUS}})
06:35 morning-triage (unchanged) · 07:05 morning-report (unchanged)
```

`digest_command` grows by one call and one template argument; all logic lives in `lib/digest.sh` so `tests/test_digest_lane_status.sh` can drive it through `bin/nightshift-dispatch digest` (integration, like `test_digest.sh`) **and** call the pure functions directly (boundary cases).

## 4. Input contract (the only thing the reporter and the digest share)

The reporter prints **one JSON object** to stdout and exits 0. The digest requires the five top-level keys below; every other key is ignored; extra fields inside rows are ignored.

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

| Key | Type | Required | Used for |
|---|---|---|---|
| `ci_red[]` | array of objects | yes | "CI red" list: rows with `scope == "main"` only (default-branch reds; PR / branch scopes are the lane owner's daily business, not the morning headline). Row fields used: `repo`, `workflow`, `branch`, `since`; `scope`, `conclusion` validated, not printed |
| `lanes[]` | array of objects | yes | "Human-owned lanes" = `owner == "human"`; "Stale lanes" = `stale == true` (any owner). Row fields used: `repo`, `number`, `title`, `reason`; `kind`, `owner`, `stale` validated; `state` optional |
| `roster.repos[]` | array of strings | yes | `repos N` in the header |
| `errors[]` | array | yes | `errors N` in the header (per-repo fetch failures on the reporter side) |
| `truncated[]` | array | yes | `truncated N` in the header (reporter-side list caps) |

Validation (all with `jq -e`, in this order; the first failure wins and its reason is printed):

1. stdout non-empty → else `unavailable (empty output)`
2. parses as JSON → else `unavailable (contract: not JSON)`
3. top level is an object → else `unavailable (contract: not an object)`
4. each of the five keys present with the right type → else `unavailable (contract: <key> missing)` / `(contract: <key> not an array)`
5. **Row-level** problems never fail the section: a `ci_red` row without `repo`/`workflow`/`branch`/`scope`, or a `lanes` row without `repo`/`number`/`title`/`owner`/`stale`, or `owner` outside `human|alpha|unknown`, or `stale` not boolean, is excluded from the lists and counted in the header as `malformed rows N` (printed only when N > 0). Rows are never dropped without that count.

Counts in the header are computed from the **validated** arrays: `repos` = `roster.repos | length`; `ci red` = number of `ci_red` rows with `scope == "main"` (all scopes are in the raw file); `human-owned lanes` = lanes with `owner == "human"`; `stale lanes` = lanes with `stale == true`; `errors` / `truncated` = array lengths.

`since` is printed verbatim (the reporter's own timestamp string, may carry a `≥` prefix); the digest does not re-parse it.

## 5. Execution model and isolation (D-1)

`digest_lane_status_run "$LANE_STATUS_CMD" "$LANE_STATUS_TIMEOUT_SEC" "$night_dir"`:

- Working set: `night_dir = $STATE_DIR/digests/$NIGHT_ID` created `0700` (sibling of the existing `$NIGHT_ID.md`), with `work/` (cwd for the command) and `tmp/` (its `TMPDIR`); both removed after the run. Outputs: `lane-status.json.tmp` (stdout), `lane-status.stderr` (stderr, kept, `0600`).
- Launch: `( cd "$night_dir/work" && exec env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin HOME="$HOME" TMPDIR="$night_dir/tmp" LANG="$LANG" TERM=dumb NIGHT_ID="$NIGHT_ID" /bin/bash -c "$LANE_STATUS_CMD" ) </dev/null >stdout.tmp 2>stderr &` — the same `env -i` allow-list shape as `lane_exec`, **except `HOME`**, which stays the operator's: the reporter authenticates to GitHub through `gh`, whose credential store `LANE_HOME_LINKS` refuses by design for night lanes; the digest is a daytime, foreground, operator-owned process like `verdict-sync` (`VERDICT_GH_BIN`), so the night-lane HOME quarantine does not apply. This is a recorded design limit (§12 D-3), not an oversight.
- Deadline: the `budget_check` pattern — background subshell, launch-window tick sampling, `nightshift_process_tree_alive` loop at 0.1 s, `nightshift_stop_process_tree` on the deadline, then `wait` for the rc. A timeout is `unavailable (timeout after <N>s)`; survivors after the sweep are logged WARN and do not change the verdict. `rc == 127` renders `unavailable (command not found)`; any other non-zero rc renders `unavailable (exit <rc>)`; process-inspection failure renders `unavailable (process inspection unavailable)`.
- "No network beyond `gh`, no write outside the state dir" is the **reporter's contract**, stated in `docs/reference.md` next to the JSON shape and in `nightshift.conf.example`; v1 does not wrap the command in `sandbox-exec` (the publisher guard's profile is bound to publisher paths and would need its own review). The cwd and `TMPDIR` under the night dir make accidental writes land in state, and `GIT_CEILING_DIRECTORIES="$night_dir"` keeps a stray `git` from discovering this repository.
- Only after validation (§4) is `lane-status.json.tmp` moved to `lane-status.json` and chmod'ed `0600`; on any failure the tmp file is removed and the stderr file is kept for diagnosis. The first three stderr lines (each cut at 200 bytes, control characters stripped) are logged as `nightshift_log WARN "lane-status stderr: …"`; the digest body never includes them.

## 6. Configuration (`LANE_STATUS_*`, daytime scope, not exported into lanes)

| Key | Default | Meaning |
|---|---|---|
| `LANE_STATUS_CMD` | unset | Shell command string run by `/bin/bash -c` in the isolated environment of §5; it must print the §4 object to stdout. Unset or empty = not configured. |
| `LANE_STATUS_TIMEOUT_SEC` | `120` | Positive integer (≤ 7 digits). Fail closed when malformed (invariant 6). |
| `LANE_STATUS_MAX_ROWS` | `10` | Positive integer (≤ 7 digits). Rows per list before the overflow line. Fail closed when malformed. |

Like `OC_FRESHNESS_*`, these are read by the dispatcher outside `env -i`, so top-level assignments in `nightshift.conf` work. `nightshift.conf.example` ships them commented out with a placeholder absolute path; the example never names a real host, user, or repository.

## 7. Rendering

Template: `templates/digest.md` gains one placeholder `{{LANE_STATUS}}` between the `## 観測結果` block and `## Footer`; `digest_render_template` gains one positional argument (11th). Three renderings:

1. Not configured → the single line `lane status: not configured` (no heading).
2. Configured, acquisition or contract failed →
   ```
   ## Lane status

   lane status: unavailable (<reason>)
   ```
3. Configured and valid →
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

   raw: <absolute path to lane-status.json>
   ```
   Each list prints `none` when empty. Ordering is deterministic: CI red by `repo`, then `workflow`, then `branch`; lanes by `repo`, then `number` (numeric). The overflow line appears only when the list exceeds the cap and states the exact remainder.

Sanitization of every printed string field: `\r\n\t` → space, other control characters removed, then cut at 120 bytes with `…`. Numbers print as-is. Nothing from `errors[].message` or `truncated[]` is printed (counts only; the raw file has them) so a reporter-side error string can never inject digest content.

## 8. Fail-visible paths (Done when 3) and what each looks like

| # | Path | Digest line | Log line | Digest exit |
|---|---|---|---|---|
| 1 | `LANE_STATUS_CMD` unset/empty | `lane status: not configured` | none | unchanged |
| 2 | command not found (`rc = 127`) | `unavailable (command not found)` | WARN + stderr excerpt | unchanged |
| 3 | timeout | `unavailable (timeout after <N>s)` | WARN | unchanged |
| 4 | non-zero exit | `unavailable (exit <rc>)` | WARN + stderr excerpt | unchanged |
| 5 | non-JSON stdout / empty / too large | `unavailable (contract: not JSON)` / `(empty output)` / `(output too large)` | WARN | unchanged |
| 6 | JSON missing `lanes` (or any required key / wrong type) | `unavailable (contract: lanes missing)` | WARN | unchanged |

In paths 2–6 the raw file is **not** written (a half-valid file would be mistaken for a good night); the stderr file is kept. `state/digests/<night>/` may therefore exist without `lane-status.json` — the `raw:` link is printed only on success.

## 9. State layout and retention

```
state/digests/<night>.md                 (existing)
state/digests/<night>/                   0700
state/digests/<night>/lane-status.json   0600  — written only on success, byte-identical to the reporter's stdout
state/digests/<night>/lane-status.stderr 0600  — always written (may be empty)
```

Retention: identical to the digest itself (no automatic pruning in this repository). A re-run of the digest for the same night overwrites both files (same "last render wins" rule the digest already has).

## 10. Tests (`tests/test_digest_lane_status.sh`, counted suite; `tests/expected_suite_count` 42 → 43; `tests/run_tests.sh` `suite_contracts` gets the same contract as `test_digest.sh`)

Fake reporters are tiny scripts written into the test's temp dir (no network, no real tool). Fixtures under `tests/fixtures/lane-status/`: `happy.json` (2 main reds + 1 pr red, 3 human lanes, 2 stale lanes incl. one `alpha`, 1 error, 1 truncated, 1 malformed lane row), `overflow.json` (12 main reds, 12 human lanes, 12 stale lanes), `missing-lanes.json`, `not-object.json` (a JSON array). All repository names are synthetic (`example/alpha` …).

- Happy path: heading, header counts (`repos 3 · ci red 2 · human-owned lanes 3 · stale lanes 2 · errors 1 · truncated 1 · malformed rows 1`), one row per list in the stated format and order, pr-scope red absent from the list, `raw:` line, file exists with mode `0600` and `cmp`-equal to the fixture, stderr file exists, digest exit 0, `digest_written` record unchanged in shape.
- Cap: with `LANE_STATUS_MAX_ROWS=10` each list shows 10 rows and `… +2 more (see lane-status.json)`; with `=1`, `… +11 more`.
- Each of §8 paths 1–6 (timeout uses `LANE_STATUS_TIMEOUT_SEC=1` and a reporter that sleeps 5): the exact digest line, digest exit 0, no `lane-status.json`, stderr excerpt present in `state/logs/digest-<night>.log` and absent from the digest.
- stderr isolation: a reporter that prints a sentinel to stderr and valid JSON to stdout → sentinel in the log, not in the digest.
- Sanitization: a title containing a newline and a 300-byte title → single line, cut at 120 bytes with `…`.
- Config fail-closed: `LANE_STATUS_TIMEOUT_SEC=abc` / `LANE_STATUS_MAX_ROWS=0` → `run_digest` fails (non-zero), ERROR logged.
- Isolation: the fake reporter prints `$HOME`, `$PWD`, `$TMPDIR` to stderr → `PWD` and `TMPDIR` are under the night dir, `HOME` equals the operator HOME (documented limit), and a stray env var set by the test (`SENTINEL_ENV`) is not visible.
- **Mutation checks (reviewer sweep, each must turn a test red)**: remove the cap → the overflow test; make a non-zero exit fall through to rendering → the `exit <rc>` test; delete the `unavailable` line → every §8 test; skip `chmod 0600` → the mode test; write the raw file before validation → the missing-`lanes` "no raw file" test.

## 11. Files to touch (WIP declaration must match)

New: `lib/digest.sh` functions (`digest_lane_status_validate_config`, `digest_lane_status_run`, `digest_lane_status_check`, `digest_lane_status_render`, `digest_lane_status_block`) · `docs/digest-lane-status.md` (this) · `tests/test_digest_lane_status.sh` · `tests/fixtures/lane-status/*.json`

Changed: `bin/nightshift-dispatch` (`digest_command`: one call + one template argument) · `templates/digest.md` (`{{LANE_STATUS}}`) · `config/nightshift.conf.example` · `docs/reference.md` + `docs/reference.ja.md` (settings table + contract) · `docs/engineering.md` ("Manual operation": try the section by hand) · `tests/expected_suite_count` · `tests/run_tests.sh` (`suite_contracts` entry)

Not changed: `lib/ledger.sh`, `lib/verdict.sh`, `lib/lock.sh`, `lib/lane-env.sh`, `bin/morning-triage`, `lanes/**`, `guard/**`, `launchd/**`, README files (the digest is described in `DESIGN.md` §9; a one-line pointer there is optional and non-normative).

## 12. Decision log

| # | Question | Decision | Why |
|---|---|---|---|
| D-1 (owner) | acquisition | configured CLI command (`LANE_STATUS_CMD`) | no dependency on a running dashboard; the night stack already runs configured commands |
| D-2 (owner) | content | counts + three capped lists; raw JSON to state | the digest is a one-page morning read; drill-down has a file |
| D-3 | `HOME` in the isolated environment | operator `HOME` (not a quarantined HOME) | `gh` auth lives in `~/.config/gh`, which `LANE_HOME_LINKS` refuses by design; daytime precedent = `verdict-sync` |
| D-4 | malformed `LANE_STATUS_*` values | fail closed (digest returns 1) | same as `OC_REPORT_MAX_AGE_DAYS`; config bugs must surface before the first morning |
| D-5 | CI red list scope | `scope == "main"` rows only; all scopes stay in the raw file | the morning headline is "is a default branch red"; PR/branch reds belong to the lane owner |
| D-6 | raw file on failure | never written | a half-valid file would be mistaken for a good night; the stderr file carries the diagnosis |
| D-7 | not-configured rendering | single footer-style line, no heading | Done when (3) wording; the gap stays visible without pretending a section exists |
| D-8 | row-level contract problems | count as `malformed rows N`, never fatal, never silent | the reporter may add owners/states later; the digest must not go dark on a new enum value |
| D-9 | sanitization | control chars stripped, 120-byte cut, only whitelisted fields printed | reporter output is data, not template |

## 13. Design review record (L1-9)

_Filled after round 1: seat · requested → actual model · verdict · adopted / rejected findings with reasons. Substitutions record `requested → actual` and the substitute reviews the whole design._
