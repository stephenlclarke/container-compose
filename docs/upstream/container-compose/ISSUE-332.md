# Issue 332: prepare and publish the 0.14.0 stable stack

## Problem description

The Container family has accumulated user-facing runtime and Compose changes
since 0.13.0, including live memory updates, adaptive memory reclamation,
shared-VM isolation and networking, bounded bootstrap concurrency, and Compose
resource projection. Those changes require one immutable matched-stack release,
rather than independent component snapshots.

The release must also be reproducible and auditable. Previous-release and
Docker reference measurements need retained raw evidence, Homebrew must be
validated before publication, all user-facing documentation must describe the
shipped behavior, and release-only quality authorities must complete against
the exact candidate. Documentation publication remains last so it cannot hide
a source, package, or runtime defect.

The early Homebrew rehearsal found that the stable Container and Compose
formulae declare a version already derived from their semantic release URLs.
Current Homebrew rejects that redundant stanza under strict audit. Mutable
`current` formulae still need an explicit monotonic version because their URLs
do not contain one.

## Requested outcome

- Release an exact, clean Container-family stack as 0.14.0.
- Remove the redundant explicit version from stable Homebrew formulae while
  preserving explicit mutable-Current versioning.
- Complete repeated critical candidate reviews and fix every surfaced defect.
- Run the full matched-stack, Docker parity, and previous-release benchmark
  gates with immutable fingerprints and retained raw evidence.
- Bring every user-facing document and release note up to date with the shipped
  functionality.
- Require clean SonarQube and CodeQL evidence for the exact release candidate.
- Verify signed packages, Homebrew install, upgrade, rollback, and release
  provenance before rebuilding and publishing every DocC site last.
- Retain a timestamped job ledger and analyze avoidable or serial work after
  the release builds complete.

## Acceptance evidence

- All family repositories and release worktrees are clean at recorded exact
  revisions, with no unresolved dependency or upstream state.
- Stable and Current formula renderer tests pass; generated stable formulae
  pass Ruby syntax, `brew style`, and strict supported-name audit while Homebrew
  resolves version 0.14.0.
- Full source, package, integration, Docker parity, and benchmark evidence is
  retained in the repository with the 0.13.0 and Docker reference fingerprints.
- Documentation, release notes, status, backlog, help, examples, and package
  metadata match the exact shipped behavior.
- SonarQube and GitHub-authoritative CodeQL are clean for the exact candidate.
- The stable tag, release assets, checksums, attestations, signatures, formulae,
  installation, upgrade, and rollback all verify.
- Container, Containerization, Compose, and Kubernetes DocC sites rebuild and
  publish only after the stable release is otherwise complete.
- A final build-job analysis distinguishes required, cached, repeated,
  one-time, and deferrable work and records concrete optimization follow-ups.

## Scope

This issue owns release readiness, evidence, documentation, packaging, and
publication for 0.14.0. It does not add unrelated functional parity work or
weaken signing, review, quality, parity, performance, or release authorities.

Refs [#332](https://github.com/stephenlclarke/container-compose/issues/332).
