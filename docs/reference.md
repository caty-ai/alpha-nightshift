← [Back to README](../README.md) ｜ 🇯🇵 [日本語版](reference.ja.md)

## Guard modes and evidence schema

All guard commands report or inherit exactly one of these mode values in their output JSON.

| Mode | Meaning |
|---|---|
| `LOCAL_ONLY_REMOTE_UNPROVEN` | Phase 1a: local checks only. No key or network access attempted. |

All Phase 1a evidence documents include the schema version field:

```json
{
  "schema": "alpha-nightshift/text-policy-evidence/v1",
  "mode": "LOCAL_ONLY_REMOTE_UNPROVEN",
  "write_mode": false,
  ...
}
```

---

## Preflight fields and write_mode

The preflight response is always a JSON object with two key fields:

- `write_mode`: boolean, always `false` in Phase 1a. Reports whether this configuration is permitted to mint write tokens or mutate remote state.
- `mode`: one of the guard mode values above.

Additional fields report each prerequisite status as `PROVEN`, `UNPROVEN`, or `UNSUPPORTED`:

- filesystem prerequisites (config paths, ownership, permissions)
- sandbox capability (macOS sandbox.sb renderability)
- identity and UID isolation
- remote GitHub App and installation readiness

In Phase 1a, `write_mode` is unconditionally false regardless of config content.

---

## Publisher policy shape and publication target

The publisher policy is a JSON file that specifies the GitHub App, repository, rulesets, and key material for publication.

### Inactive policy example

The checked-in `config/publisher-policy.example.json` is deliberately owner-incomplete:
- `mode`: "INACTIVE"
- `write_mode`: false
- App ID, installation ID, and account values: zero
- Key path, audit directory path, manifest path: null
- Rulesets: empty array
- Runtime seals: null

A live policy must be publisher-owned mode 0600 and bind the exact identity and paths:
- Publisher UID and repository numeric ID
- App ID and installation ID
- Ruleset IDs and effective rule baselines
- Key path (publisher-owned mode 0600)
- Audit directory (publisher-owned mode 0700)

Additionally seal:
- Scanner manifest path (publisher-owned mode 0600)
- SHA-256 digest, UID, and mode of fixed Bash, Git, jq, gitleaks, curl, openssl, and publisher program files

### Publish target branch pattern

The only allowed publish destination is a broker-generated branch matching this pattern:

```
refs/heads/night-bot/run-YYYYMMDD-NNNN-HEX8
```

Where:
- `YYYYMMDD` is the date
- `NNNN` is a four-digit sequence number
- `HEX8` is an eight-character hex string (e.g., `a1b2c3d4`)

Free-form publish, merge, mutation, and arbitrary command operations remain hard-disabled in both gateway and broker.

---

## Drift monitor verdict vocabulary

The drift-monitor reads an owner-sealed live config and verifies GitHub App permissions, webhook configuration, and installation identity. Terminal results are limited to:

| Verdict | Meaning |
|---|---|
| `MATCH` | All verified invariants match (App permissions, webhook state, installation identity, repository settings, tags, releases match policy baseline) |
| `DRIFT_DENY` | An exact mismatch was detected (policy/runtime/App/installation/ruleset/effective-rules/default-branch/private/tag/release invariants differ) |
| `MONITOR_UNVERIFIED` | Incomplete response, malformed data, pagination timeout, auth failure, revoke failure, or audit failure. Fail-closed. |

The residual value `rule_suite_result:"UNPROVEN_NO_ADMIN_READ"` is explicit because the App still lacks `Administration:read` permission. GitHub's public JWT API exposes webhook configuration, so URL-empty representation is machine-verified. The first live readback must still confirm GitHub's actual disabled-webhook representation.

The control "OAuth user authorization disabled" has no public read API and remains `UNPROVEN_MANUAL_OWNER_BASELINE` — must be checked manually by the owner.

---

## Scanner contract

The scanner accepts an absolute local Git repository path, exact base and candidate commit SHA, and an activation manifest. It performs:

- Clears Git configuration and network/credential mechanisms
- Reads canonical objects by ID from the local Git store
- Applies representation and gitleaks-stdin gates to candidate-introduced commit/tree/blob objects
- Records deterministic local aggregates: object ID, type, size, and raw SHA-256

### Pinned gitleaks version

The scanner uses pinned **gitleaks 8.30.1**. The binary hash is verified on every CI run via SHA-256 checksum comparison:

```
ba52fb1bfabbcde42f032afad3d6e0b19dff8ed105229a16e7caa338bbc0e84f
```

Input path: `/opt/homebrew/Cellar/gitleaks/8.30.1/bin/gitleaks`

### Git-object stdin scanning

The scanner invokes gitleaks on Git objects via stdin:

```sh
gitleaks stdin --policy <policy> < <git-object-bytes>
```

This accepts the object's raw bytes and applies gitleaks policy without requiring file system access.

### MIME allowlist

The MIME allowlist is deliberately narrow. Only these types are accepted:

- `text/plain`
- `application/json`
- Recognized empty content

Denied types (fail-closed in Phase 1a):

- Binary archives (tar, zip, gzip, bzip2, xz)
- Executables (ELF, Mach-O, PE, shell scripts)
- Media (image, audio, video, font)
- Documents (PDF, Office, compressed)
- Opaque or alternate-charset encodings

Common source file types such as `text/x-shellscript` or `text/x-c` will be classified by the `file` command and denied, even if their bytes are valid UTF-8.

### Wrapper and checksum shapes

Whole-payload wrapper content is fail-closed:

- Base64-shaped content
- Hex-shaped content
- Percent-encoded content
- Base64url-shaped content (including sufficiently long kebab-case or underscore-separated tokens)
- Normalization-ambiguous content

Otherwise innocent encoded text, checksums, or wrapper-shaped source data can therefore false-deny in Phase 1a. Supporting those classes requires a separately reviewed representation policy.

### Text validation

Text validation (commit messages, titles, bodies, comments) applies structural checks:

- Valid NFC UTF-8 with no BOM, NUL, CR/CRLF
- No C0/C1 control characters or Unicode line separators
- No noncharacters or unassigned ambiguity
- No bidi controls or default-ignorable code points
- No Unicode format characters (`Cf`) or private-use characters (`Co`)

Conservative byte limits by kind:

| Kind | Maximum bytes | Line rule |
|---|---:|---|
| `title` | 512 | exactly one nonempty line; no LF |
| `commit_message` | 16,384 | nonempty; exactly one terminal LF |
| `body` | 65,536 | nonempty; exactly one terminal LF |
| `comment` | 32,768 | nonempty; exactly one terminal LF |

Text also passes the same pinned gitleaks 8.30.1 stdin policy as Git objects, preserving the same runner behavior (empty-ignore, inline-allow denial, full-byte diagnostic, redacted report, fail-closed).

---

## Revocation runbook

See [night-bot-revocation.md](night-bot-revocation.md) for the complete owner-driven containment procedure.

The runbook provides:
- Dry-run renderer (validates case metadata, prints exact action order without expanding tokens)
- Ordered owner actions (disable services, quarantine spool, revoke tokens, suspend App, revoke keys)
- Readback verification to confirm mutation is blocked
- Recovery procedure requiring fresh owner review and independent approval

---

## Text validation verdict schema

Text validation success emits:

```json
{
  "schema": "alpha-nightshift/text-policy-evidence/v1",
  "mode": "LOCAL_ONLY_REMOTE_UNPROVEN",
  "write_mode": false,
  "verdict": "PASS_LOCAL_ONLY",
  "kind": "body",
  "bytes": 123,
  "accepted_sha256": "...",
  "scanner_policy_sha256": "...",
  "gitleaks_version": "8.30.1",
  "gitleaks_sha256": "ba52fb1bfabbcde42f032afad3d6e0b19dff8ed105229a16e7caa338bbc0e84f"
}
```

Neither success nor denial emits the proposed text itself.

---

<a id="org-consistency-settings"></a>

## Org-consistency settings

The public operator surface below is synchronized with `config/nightshift.conf.example`. Positive-integer settings fail closed when malformed; `OC_L3_WEEKDAY` additionally accepts only ISO weekdays `1` through `7`.

| Setting | Scope and example value | Meaning |
|---|---|---|
| `OC_FRESHNESS_ENFORCE` | daytime digest; `0` | Set to `1` when the lane is enabled to report a missing or stale org-consistency report in the morning digest. |
| `OC_REPORT_DIR` | daytime digest / `oc-suggest`; unset | Report directory override. When unset, it follows the org-consistency directory under the Nightshift state directory. |
| `OC_REPORT_MAX_AGE_DAYS` | daytime digest / `oc-suggest`; `3` | Maximum report age before the freshness sensor warns. |
| `OC_SUGGEST_REPO` | lane and `oc-suggest`; `caty-ai/alpha-nightshift-dev` | Repository used for daytime issue filing and for lane-level self-health attribution. |
| `OC_STATE_DIR` | lane; required absolute path | Non-symlink state root containing mirrors, plans, reports, journals, and the findings ledger. |
| `OC_L2_MAX_REPOS` | lane; `3` | Per-night repository cap for the combined `OC-E`/`OC-F`/`OC-G` queue. |
| `OC_H_MAX_REPOS` | lane; `2` | Independent per-night repository cap for `OC-H`. |
| `OC_L3_MAX_REPOS` | lane; `3` | Repository cap for a scheduled `OC-I`/`OC-J` run; selection rotates by least recent attempt. |
| `OC_L3_WEEKDAY` | lane; `7` | ISO weekday on which L3 is planned (`1` is Monday and `7` is Sunday), derived from `NIGHT_ID`. |
| `OC_EXCLUDE_REPOS` | lane; empty | Comma-separated repository names or `owner/name` values excluded from the target set. |
| `OC_LANG_POLICY` | lane; `4` | Fallback README language policy when the registry does not declare one. `4` means English, Japanese, Simplified Chinese, and Thai; comma lists and semicolon-separated repository overrides are also accepted. |
| `OC_AGENT_DOC_GLOBS` | lane; empty | Comma-separated additional globs for agent-instruction documents beyond the built-in names. |
| `OC_LEFT_SCOPE_WINDOW_NIGHTS` | lane; `30` | Number of nights a finding may remain outside the current target set before it becomes left-scope-expired. |
| `OC_ZERO_STREAK_NIGHTS` | lane; `5` | Consecutive zero-extraction nights that trigger an informational self-health finding. |
| `OC_STALE_ESCALATE_NIGHTS` | lane; `3` | Consecutive stale-target or stale-mirror nights that trigger self-health. |
| `OC_PROMPT_MAX_BYTES` | lane; `262144` | Maximum encoded prompt size per model-seat invocation. Oversized work is recorded as `NOT-RUN` with reason `prompt-too-large`. |
| `OC_SEAT_TIMEOUT_SEC` | lane; `900` | Positive per-invocation timeout for each read-only model seat. |
| `OC_SEAT_CMD` | lane; required for L2/L3 | Full command used by `seat.sh`; it receives the prompt on stdin and runs from a scratch working directory. |

Lane commands are intentionally launched under `env -i`. A top-level assignment in `nightshift.conf` is therefore **not inherited by the lane**: every lane-scoped `OC_*` value must be embedded inside the `LANE_CMD_3` command string, as shown in `config/nightshift.conf.example`. The daytime freshness settings are the exception because the dispatcher and `oc-suggest` read them outside the isolated lane process. Keep `LANE_CMD_n` entries contiguous; dispatch stops at the first missing number.

---

## Local gateway interface

The gateway accepts only these operations:

- `status`: report current configuration state
- `inspect`: examine objects without mutation
- `preflight`: verify prerequisites (local only)
- `scan`: run Git-object scanner
- `validate_text`: check commit message or text locally
- `publish_status`: report publication attempt status
- `publish_branch`: invoke broker (only after all safety gates pass)

Free-form publish, merge, mutation, and arbitrary command operations are hard-disabled.
