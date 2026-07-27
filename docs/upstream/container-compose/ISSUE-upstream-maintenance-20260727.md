# Upstream maintenance refresh for 27 July 2026

## Problem

The supported stack must prove that every Apple-backed fork contains the
complete current Apple `main` history before parity work continues. It must
also review current upstream bug reports, dependency-bot proposals,
Stephen-authored Apple pull requests, and actionable connector feedback.

That evidence becomes stale whenever one repository advances independently.
The consuming Compose revision can also remain pinned to an older runtime even
after a fork-side correction is ready, causing validation to exercise the
wrong source.

## Expected behavior

- Fetch every configured Apple and Stephen-owned remote with pruning.
- Prove there are zero Apple-only `main` commits in each supported fork.
- Import an Apple commit only when it is missing; never manufacture a
  redundant merge.
- Reproduce applicable upstream reports on macOS and keep each generic runtime
  correction in an independently reviewable signed commit.
- Preserve exact immutable references for open Stephen-authored Apple pull
  requests and answer every actionable connector review.
- Pin Compose manifests and release stack metadata to the exact reviewed
  runtime.
- Pass unit, coverage, full CI, SonarCloud, and Docker Compose v5.3.1 parity
  before publishing the slice.

Windows-only behavior and Linux-host implementation are outside this refresh.
Linux guest behavior that is exercised by the macOS runtime remains in scope.

## Reproduction and audit result

The refresh fetched the three Apple-backed repositories and compared their
Apple `main` history with the supported fork `main`:

| Repository | Apple `main` | Fork baseline | Apple-only |
| --- | --- | --- | ---: |
| `container` | `d1d763530df3c6a326dbae7f0c0a59a335808045` | `5796a79ee3e59c16098d086278c072740d519ee8` | 0 |
| `containerization` | `74ace148ded72f7bb3c878b142e4962ae668adf4` | `164088e02e16ed80e536d0c59822b09931d213df` | 0 |
| `container-builder-shim` | `267b5ab98e1d7db7d98af98bdc90578bf5fd3192` | `f97cddf5b3aae2426a094613793c11c41b1d2e53` | 0 |

No Apple commit was missing. The Compose and release-support repositories had
no open Dependabot or Renovate pull request. The four open Stephen-authored
Apple proposals were mergeable and had no requested author change.
Runtime PR
[stephenlclarke/container#30](https://github.com/stephenlclarke/container/pull/30)
then merged the reviewed maintenance tree as
`5796a79ee3e59c16098d086278c072740d519ee8`; the post-merge audit retained an
Apple-only count of zero.

The fork reproduced the four performance hot paths from
[apple/container#2022](https://github.com/apple/container/issues/2022).
The long-line log correctness case already passed. The disk-retention report
in [apple/container#2021](https://github.com/apple/container/issues/2021)
remains owned by the macOS Virtualization.framework virtio-fs primitive and
has no safe fork-side workaround.

## Ownership and boundary

Generic runtime corrections belong in `stephenlclarke/container` and are
documented as Apple-shaped handoffs. Exact dependency selection, release cache
policy, parity orchestration, and aggregate evidence belong in
`container-compose`. No Apple remote is modified by this work.

## Acceptance

- Re-fetch all upstreams immediately before publication and retain zero
  Apple-only commits.
- Run the Container unit and coverage gates plus focused bootstrap validation.
- Run complete Compose CI and release-policy coverage.
- Run live Docker Compose v5.3.1 parity against the exact supported stack.
- Obtain an exact-head connector review and answer every actionable thread.
- Publish a signed prerelease with current documentation and typed/live VHS
  evidence.
