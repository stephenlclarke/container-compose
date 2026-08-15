# Upstream Handoffs

This directory is the durable handoff area for Apple-facing work that affects `container-compose`. [HANDOFF-REGISTRY.json](HANDOFF-REGISTRY.json) is the maintained source of truth; [HANDOFF-REGISTRY.md](HANDOFF-REGISTRY.md) is its generated reader view. Current installation, release, support, and build instructions remain at the repository root.

For the coherent parity programme, the [Container-family parity development cycle](../architecture/container-family-development-cycle.md) is normative: Apple repositories and their issues, pull requests, discussions, and comments remain read-only throughout every development wave. New generic work stops at an Apple-shaped signed commit series plus an `active-draft` or `unsubmitted` handoff. Existing submitted records remain tracked historically. New or refreshed Apple submissions are deferred to one programme-wide publication step after all planned development and integrated gates are complete, and still require explicit authorisation.

## Programme-Wide Publication Gate

Completing one capability, repository, design, or implementation wave never authorises an Apple write. During development, every upstream-applicable defect fix is:

1. reproduced against the relevant current Apple repository;
2. isolated from Docker-, Compose-, Stephen-, and programme-specific policy;
3. committed as the narrowest Apple-shaped source and test series;
4. documented and registered as `active-draft` or `unsubmitted`; and
5. kept local or in the supported forks with Apple push URLs disabled.

The accumulated queue is reviewed for publication only after all planned Container-family development is complete and the programme-wide compatibility, fault, security, migration, performance, documentation, and repository-hygiene gates pass. Publication then requires explicit authorisation and a fresh upstream review; no earlier wave can partially drain the queue.

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

## Fork Commit Classification

[FORK-COMMIT-CLASSIFICATIONS.json](FORK-COMMIT-CLASSIFICATIONS.json) is the
reviewed source of truth for every patch-unique non-merge commit carried by
the three support forks. Its generated
[reader view](FORK-COMMIT-CLASSIFICATIONS.md) records the owner, reason, and
upstream disposition for each commit.

After either an Apple or supported-fork head changes, review every added or
obsolete entry explicitly and run:

```sh
make fork-classifications-check
```

The gate rejects unclassified, duplicate, stale, or structurally invalid
entries; it never assigns a disposition automatically.

## Handoff Lifecycle

1. Re-check current Apple issues and pull requests before selecting a slice and record overlaps. During development, do not open or comment on an Apple issue, discussion, branch, or pull request.
2. Add or update the structured registry row first. Keep a detailed Markdown document only while it contains current review, construction, testing, or submission information that does not fit the row.
3. Keep one coherent Apple-shaped handoff series per repository. Split a cross-repository capability into independently reviewable lower-runtime and API/CLI slices.
4. Keep Compose-specific parsing, formatting, filtering, orchestration, and Docker compatibility in `container-compose`. Apple-facing work should expose generic typed primitives and tests.
5. Keep new programme work in `active-draft` or `unsubmitted`. For already submitted historical work, continue recording its canonical URL, exact published head, `submitted` state, and verification date without interacting with the Apple repository.
6. When a document is retired, publish the commit that still contains it, remove its active `path`, and retain a canonical immutable `archive` URL to that commit.
7. Keep recoverable upstream code heads separately in [PR-ARCHIVE.json](PR-ARCHIVE.json). Never force-push, delete, or retarget an `upstream-pr-NUMBER-SHORTSHA` archive branch; add a new snapshot when a head changes.

An unsubmitted candidate is not automatically handoff-ready. Rebase the smallest independent change on current stock Apple `main`, review it as an Apple maintainer, run focused and repository-level validation, capture the information required by the current Apple issue and pull-request templates in the local handoff, and keep Stephen-only compatibility behaviour out of the patch.

## Apple-Shaped Handoff Review Gate

Before marking a local Apple-shaped handoff reviewed:

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
