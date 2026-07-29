# Phase 1a local guard

This directory is an opt-in, credential-free enforcement package. It is not
called by the Phase 0 dispatcher and cannot publish. Every command reports or
inherits `LOCAL_ONLY_REMOTE_UNPROVEN`.

The lane-facing gateway accepts only `status`, `inspect`, local `preflight`,
local `scan`, and validation of a strict proposal containing no destination
ref. The future destination grammar
`refs/heads/night/YYYYMMDD-NNNN` is broker-generated only; it is deliberately
absent from the lane proposal schema. Publication, merge, mutation, and
free-form command operations are hard-disabled in both gateway and broker.

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
single-token kebab-case or underscore content.

`sandbox.sb` is a measurement template. Render it only with
`render-sandbox.sh`; the default has no network access, while `--fixture`
accepts one exact `127.0.0.1:PORT`. Deprecated or inexpressible macOS sandbox
cells are residuals, never positive containment claims. Preflight reports
fixed-profile execution separately as `sandbox_runtime_capability`; when that
probe is unavailable, each named fixture proof remains `UNSUPPORTED`.

Phase 1b still requires six distinct UIDs, a protected private-repository
plan/host, the night-bot account and fine-grained PAT, and explicit owner
authorization for potentially mutating remote proof. Issue #6 cannot close
from this package alone.
