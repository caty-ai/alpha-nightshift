# Phase 1a local guard

This directory is an opt-in, credential-free enforcement package. It is not
called by the Phase 0 dispatcher and cannot publish. Every command reports or
inherits `LOCAL_ONLY_REMOTE_UNPROVEN`.

The lane-facing gateway accepts only `status`, `inspect`, local `preflight`,
local `scan`, local `validate_text`, and validation of a strict proposal
containing no destination ref. The future destination grammar
`refs/heads/night/YYYYMMDD-NNNN` is broker-generated only; it is deliberately
absent from the lane proposal schema. Publication, merge, mutation, and
free-form command operations are hard-disabled in both gateway and broker.

## Local publication-text validation

`validate_text` validates a file snapshot locally; it does not publish or make
the bytes eligible for publication:

```sh
guard/gateway.sh validate_text \
  --kind commit_message \
  --input /absolute/canonical/path/message.txt
```

The only kinds are `commit_message`, `title`, `body`, and `comment`. The input
must be one absolute canonical ASCII path to one regular, non-symlinked,
single-link file. Inline text, repo/destination identifiers, URLs, credentials,
hostnames, API paths, and command fields are not part of this grammar.

The conservative byte limits are:

| Kind | Maximum accepted bytes | Line/trailing-LF rule |
| --- | ---: | --- |
| `title` | 512 | exactly one nonempty line; no LF |
| `commit_message` | 16,384 | nonempty; exactly one terminal LF |
| `body` | 65,536 | nonempty; exactly one terminal LF |
| `comment` | 32,768 | nonempty; exactly one terminal LF |

Internal LF is allowed for every non-title kind. A second terminal LF and
whitespace-only content deny. Tabs are not allowed in Phase 1a. Accepted bytes
must be valid NFC UTF-8 with no BOM, NUL, CR/CRLF, C0/C1 controls, Unicode line
separators, noncharacters, unassigned ambiguity, bidi controls, default-
ignorable code points, any Unicode format character (`Cf`), or any private-use
character (`Co`). Format and private-use characters are rejected structurally
because their presentation is not portable or trustworthy. No normalization or
newline rewrite occurs; the digest binds the exact snapshotted bytes.

One no-side-effect predicate applies identically to all four kinds after those
structural checks. It rejects URLs and domains, `www.`, autolinks, raw HTML,
Markdown links/images/reference definitions, mentions and GitHub references,
7–40 hex commit references, closing-reference forms, task lists, and escaped,
percent/entity-encoded, compatibility-normalized, or Unicode-confusable forms.
It also fail-closes before scanning on a closed, conservative assignment rule.
Any compatibility/confusable fold that has scanner-shaped API-key, secret, or
token syntax denies. Independently, one lexical state machine carries
identifier evidence forward until a qualifying delimiter, then carries the
completed assignment until a scanner-shaped value or document end. A
fixed-size forward matcher keeps a bounded bitset of reachable prefix lengths
for each letter skeleton `apikey`, `secret`, and `token`; it never builds
suffix strings or rescans prior text. Its closed alphabet embeds the direct
one-code-point lowercase and uppercase ASCII targets for the twelve letters
used by those keys from Unicode 17.0.0 UTS #39 `confusables.txt` (2025-07-22,
approved SHA-256
`091c7f82fc39ef208faf8f94d29c244de99254675e09de163160c810d13ef22a`),
plus narrowly retained threat-specific mappings for intermediate prototypes
and Greek/Cyrillic key disguises. During fixed table construction, every
approved direct `o` source whose compatibility decomposition and case fold is
Greek sigma or final sigma keeps its `o` alternative while also receiving the
threat-specific `s` alternative; the expected fixed-pattern unit selects
between them. Direct `c` sources such as Greek lunate sigma retain only their
intended `c` behavior. The original code point is then mapped before
fixed-key-only compatibility/canonical decomposition, combining marks are
removed, and the resulting units are mapped again. This composes supported
sources into only the three exact key skeletons; it does not normalize or
rewrite the input bytes.

Before a skeleton completes, every original separator-category character
preserves the prior bitsets as its whole-character skip path. If its complete
two-stage skeleton is nonempty, a second path atomically consumes every unit
in that skeleton; the matcher never branches between individual decomposed
units or retains an intermediate non-complete consume alternative. Completion
at any unit is intentionally sticky and fail-closed even when later units
remain. This covers both the thirteen separator-category sources in the
direct table and separator characters that acquire mapped units only after
fixed-key-only decomposition. Non-separator characters are consume-only.
Unmapped LF, Unicode whitespace, Braille blank, Japanese
Han/Hiragana/Katakana, punctuation, every Unicode symbol category, and
modifier letters therefore remain effective skip-only soft separators. This
covers repeated `_`/`-`, comma, slash, middle dot, currency and other symbols,
and split ASCII or Greek/Cyrillic forms without allowing either role of a
separator character to erase progress. Other identifier characters slide the
fixed matcher so prefix noise cannot hide a later known key. Once a skeleton
completes,
identifier suffix letters, marks, numbers, connector punctuation, `_`, and `-`
cannot erase its sticky evidence. Supported script alternatives may mix, but
unrelated pure or mixed Greek/Cyrillic labels and arbitrary
Latin-plus-Japanese labels do not arm unless the fixed known-key skeleton
actually completes.

An ASCII period or Unicode period that folds to it directly after completion
or after preserved suffix evidence enters the same bounded tentative
sentence/dotted-key state. Same-sentence filler and identifiers do not erase
the completed key: a scanner-class run or qualifying delimiter still closes
it as an assignment. If the fixed matcher completes another known key inside
that tentative state, it clears stale line-break state and reactivates sticky
candidate counting; soft line breaks may split that second key, and later
line breaks cannot erase its completion. An unrelated multi-character label
followed by a label colon after a line break may terminate the tentative state,
while another completed fixed key cannot. If that label ends in an active
fixed-key prefix, the colon defers termination using only the three bounded
prefix lengths: soft separators may lead to completion and sticky evidence,
while the first substantive mismatch terminates the old sentence evidence and
is processed normally without retroactive candidate attribution. Thus direct
`token.` and `token。` sentence endings followed by ordinary `Notes:` prose
remain accepted, but dotted keys, spaced one-letter suffixes, mapped Unicode
periods, and same-sentence Japanese suffixes remain closed. Other ASCII and
non-ASCII punctuation, every Unicode symbol category, and modifier letters
qualify after identifier evidence. Outside that tentative sentence boundary,
arbitrary same-line filler, newlines, blank/Unicode-whitespace lines, leading
junk, and substantive intervening prose do not clear sticky identifier or
delimiter evidence.
Candidates that occur before completed assignment evidence remain accepted.
Pure Japanese labels and Japanese prose containing ASCII technical terms
remain outside generic mixed-script evidence when their only non-ASCII
identifier characters are Han, Hiragana, or Katakana.
After delimiter evidence, any 16-character Unicode scanner-class run denies.
This preserves the earlier fullwidth delimiters, modifier-letter colon,
ratio/short-equals lookalikes, and Greek kappa protections.
Percent signs, backslashes, ampersands, angle brackets, and default-ignorable
characters are conservatively denied rather than interpreted by a broad
Markdown parser. Only the fixed-key skeleton comparison performs its two-stage
confusable mapping, compatibility/canonical decomposition, and combining-mark
removal. Structural NFC validation remains unchanged, and the original bytes
are never normalized or rewritten. Ordinary Unicode
prose without an assignment-shaped long value remains accepted, but compact
Unicode text
immediately preceding a long scanner-shaped token, mixed-script keys,
Unicode-spaced assignments, and benign assignment-like examples can
intentionally false-deny.

The exact accepted snapshot then passes the same pinned gitleaks 8.30.1 stdin
policy and exact runner as outgoing Git objects. The runner preserves the
empty-ignore, inline-allow denial, full-byte diagnostic, redacted report,
canary, stdout/report grammar, and fail-closed behavior used by the object
scanner. Outgoing commit messages are extracted from canonical commit objects
and passed through this same `commit_message` route; commit framing, headers,
and fixed identity checks remain separate and unchanged.

Success emits only this hash/count/tool evidence shape:

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
  "gitleaks_sha256": "..."
}
```

Neither success nor denial emits the proposed text.

The example activation manifest is intentionally incomplete. Preflight reads
it without creating identities, changing permissions, accessing credentials,
or contacting a host. It reports each local, filesystem, sandbox, identity,
and remote prerequisite as `PROVEN`, `UNPROVEN`, or `UNSUPPORTED`, but write
mode is unconditionally false in Phase 1a.

The scanner accepts an absolute local Git repository, exact base and candidate
commit, and activation manifest. It clears Git configuration and network/
credential mechanisms, reads canonical objects by ID, and applies
representation plus gitleaks-stdin gates to candidate-introduced
commit/tree/blob objects. The caller-supplied local base is not a protected-tip
or remote-provenance claim: Phase 1a records deterministic local aggregates of
object ID/type/size/raw SHA-256 records only. Protected-tip equality and
same-invocation remote refetch remain unavailable Phase 1b requirements.

The MIME allowlist is intentionally narrow:
`text/plain`, `application/json`, and recognized empty content. Binary,
archive, media, document, executable, opaque, alternate-charset, and ambiguous
encodings deny. Common source files can be classified by `file` as
`text/x-shellscript`, `text/x-c`, or another class outside this allowlist and
therefore deny in Phase 1a even when their bytes are valid UTF-8. Evidence
contains hashes and counts only, never object content.

Whole-payload Base64, hex, percent, Base64url-shaped, and normalization-
ambiguous wrapper content is intentionally fail-closed. Innocent encoded text,
checksums, or wrapper-shaped source data can therefore false-deny in Phase 1a;
supporting those classes requires a separately reviewed representation policy.
Base64url-shaped denial can include otherwise ordinary sufficiently long
single-token kebab-case or underscore content. For this ambiguity check only,
ASCII space/tab/LF, Unicode separators, format/default-ignorable characters,
private-use and unassigned characters, all Unicode marks, U+2800 BRAILLE
PATTERN BLANK, and U+FFFC/U+FFFD representation placeholders are removed from
a comparison copy. Original object bytes are never normalized or rewritten,
and ordinary non-wrapper blobs containing those characters are not denied by
this comparison alone. Visible punctuation and symbols are not generically
removed; the comparison is a conservative render-transparent/representation-
placeholder rule, not a lenient decoder for arbitrary garbage.

`sandbox.sb` is a measurement template. Render it only with
`render-sandbox.sh`; the default has no network access, while `--fixture`
accepts one exact `127.0.0.1:PORT`. Deprecated or inexpressible macOS sandbox
cells are residuals, never positive containment claims. Preflight reports
fixed-profile execution separately as `sandbox_runtime_capability`; when that
probe is unavailable, each named fixture proof remains `UNSUPPORTED`.

Phase 1b still requires six distinct UIDs, a protected private-repository
plan/host, the night-bot account and fine-grained PAT, and explicit owner
authorization for potentially mutating remote proof. It also requires the
broker-owned final transform snapshot, publication of only that immutable
snapshot, and remote readback whose bytes/digest equal the scanned snapshot.
None of those activation conditions is implemented or implied by a local text
PASS. Issue #6 cannot close from this package alone.
