# Upstream Handoffs

This directory is the durable handoff area for Apple-facing work that affects `container-compose`. [HANDOFF-REGISTRY.json](HANDOFF-REGISTRY.json) is the maintained source of truth; [HANDOFF-REGISTRY.md](HANDOFF-REGISTRY.md) is its generated reader view. Current installation, release, support, and build instructions remain at the repository root.

## Registry

The registry keeps one row per capability or pull request with its owner, state, last verification date, referenced commits, upstream pull request, and supporting documents. The initial migration retained immutable links to all 616 retired or current handoff documents at published Compose commit `3d77ec228c7f55a04f689d5e1453752fc0c27f72`.

Use these state values consistently:

| State | Meaning |
| --- | --- |
| `active-draft` | A current proposal is still being shaped and has no submitted upstream pull request. |
| `unsubmitted` | A reviewed candidate remains useful, but no upstream pull request has been submitted. |
| `submitted` | Stephen submitted the linked upstream pull request and it remains open. |
| `tracked-upstream` | A relevant open pull request is owned by someone else. |
| `merged` | The upstream pull request merged. |
| `closed` | The upstream pull request closed without merge. |
| `archived` | The proposal or record is retired and is not current upstream work. |

A current supporting document has a repository-relative `path`. A retired document has an immutable `archive` URL. A document can have both while it is current. A new active document does not need an archive until the commit containing it has been published.

After changing the JSON registry or a current handoff document, run:

```sh
make upstream-handoff-registry-update
make upstream-handoff-registry-check
```

The check validates the schema, states, full commit IDs, canonical GitHub pull-request URLs, active document registration, immutable archive objects, links to retired handoffs, and generated Markdown freshness. The `import-legacy` subcommand was used for the one-time migration and is not the normal update path.

## Handoff Lifecycle

1. Re-check current Apple issues and pull requests before selecting a slice. Do not open a duplicate.
2. Add or update the structured registry row first. Keep a detailed Markdown document only while it contains current review, construction, testing, or submission information that does not fit the row.
3. Keep one future Apple pull request per repository. Split a cross-repository capability into independently reviewable lower-runtime and API/CLI slices.
4. Keep Compose-specific parsing, formatting, filtering, orchestration, and Docker compatibility in `container-compose`. Apple-facing work should expose generic typed primitives and tests.
5. When a pull request is submitted, record its canonical URL, exact published head, `submitted` state, and verification date.
6. When a document is retired, publish the commit that still contains it, remove its active `path`, and retain a canonical immutable `archive` URL to that commit.
7. Keep recoverable upstream code heads separately in [PR-ARCHIVE.json](PR-ARCHIVE.json). Never force-push, delete, or retarget an `upstream-pr-NUMBER-SHORTSHA` archive branch; add a new snapshot when a head changes.

An unsubmitted candidate is not automatically submission-ready. Rebase the smallest independent change on current stock Apple `main`, review it as an Apple maintainer, run focused and repository-level validation, fill the current Apple issue and pull-request templates, and keep Stephen-only compatibility behaviour out of the patch.

## Final Review Gate

Before raising or refreshing an Apple pull request:

- Confirm the slice is the narrowest independently useful Apple-facing change.
- Re-check overlapping Apple issues and pull requests and record the stacking or replacement decision.
- Verify the referenced commits construct only the intended delta.
- Review correctness, regressions, API compatibility, security, maintainability, documentation, release impact, and unnecessary fork divergence.
- Run focused tests and repository hygiene checks on current stock Apple code. Keep optional Docker parity work out of Apple CI.
- Update the registry, [APPLE-UPSTREAM-REVIEW.md](APPLE-UPSTREAM-REVIEW.md), and relevant status records with the exact published head and residual blockers.

## Fork Documentation Audit

Handoff documentation belongs here, not in the sibling runtime forks. These commands should print nothing:

```sh
find /Users/sclarke/github/container \( -name .build -o -name .git \) -prune -o \( -name 'ISSUE-*.md' -o -name 'ISSUES-*.md' -o -name 'PR-*.md' \) -print
find /Users/sclarke/github/containerization \( -name .build -o -name .git \) -prune -o \( -name 'ISSUE-*.md' -o -name 'ISSUES-*.md' -o -name 'PR-*.md' \) -print
find /Users/sclarke/github/container-builder-shim \( -name .build -o -name .git -o -path '*/vendor/*' \) -prune -o \( -name 'ISSUE-*.md' -o -name 'ISSUES-*.md' -o -name 'PR-*.md' \) -print
```
