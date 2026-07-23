# Pull request handoff: refresh the Phase 3 exact-main stack

## Proposed pull request

`build(deps): consume stable formula ownership fix`

This handoff covers the signed Compose source commit
[`b99fd82f9e357a45c3c40bb70a6ad72228f1950e`](https://github.com/stephenlclarke/container-compose/commit/b99fd82f9e357a45c3c40bb70a6ad72228f1950e).

## Summary

Advance the final Phase 3 prerelease graph to the latest reviewed Apple
Containerization sync and all Homebrew packaging reliability fixes, including
stable-formula ownership. No Compose policy or executable source changes.

## Minimal integration boundary

- Changes only existing immutable Container and Containerization revisions.
- Keeps the builder-shim revision and Compose abstraction boundary unchanged.
- Preserves the published stable `0.8.0` assets.
- Sources the next Current package and formula pair from one exact graph.
- Keeps runtime-specific mechanics below the Compose-owned provider seam.

## Code map

- `Package.swift`
  - resolves Container at `ffe5819d`;
  - resolves Containerization at `6aa6e803`.
- `Package.resolved`
  - records the same immutable dependency revisions.
- `Tools/release/stack-refs.json`
  - binds release packaging to both reviewed tips.
- `README.md`
  - records the current zero-behind support-fork snapshot.
- `docs/upstream/container-compose/ISSUE-phase3-exact-main-refresh-20260723.md`
  - records the refresh contract and validation.
- `docs/upstream/container-compose/PR-phase3-exact-main-refresh-20260723.md`
  - provides this handoff.

## Validation on macOS

```console
swift package resolve
make stack-consistency coverage-tools-test check
make coverage-check
```

Results:

- Direct, transitive, and release-manifest revisions aligned.
- Release tooling: 156 tests passed.
- CI tooling: 14 tests passed.
- Coverage tooling: 4 tests passed.
- Compose: 1,117 Swift tests in 26 suites passed.
- Swift coverage: 91.39%.
- Go coverage: 90.06%.
- Container: 1,134 normal and 1,135 instrumented tests passed.
- Containerization: 647 tests in 85 suites passed.

## Compatibility and risks

The Containerization dependency changes only internal EXT4 child indexing and
retains insertion order. The fork's subtree-export conflict was resolved at
the traversal initialization boundary and passed its full coverage suite.

The Container changes after the stable runtime commit are dependency,
Homebrew-test, workflow, and handoff updates. Main prerelease packages remain
available, but only Compose stable promotion can change the shared stable
formula pair. Compose behavior and the published stable executable assets are
unchanged.

## PR template

### Type of change

- [x] Dependency provenance
- [x] Upstream synchronization
- [x] Packaging reliability
- [x] Documentation update
- [ ] Compose behavior
- [ ] Breaking change

### Motivation and context

Publish Current only after the matched stack contains Apple's latest
macOS-usable runtime fix and the packaging checks distinguish source defects
from environmental service state, artifact retention, and cross-workflow
formula ownership.

### Testing

- [x] Exact SwiftPM resolution passed
- [x] Stack consistency passed
- [x] Release and CI tooling passed
- [x] Compose unit and coverage gates passed
- [x] Container full unit and coverage gates passed
- [x] Containerization full coverage passed
- [ ] Exact-main CI, SonarQube, CodeQL, Current package, and VHS publication

Related issue handoff:
`docs/upstream/container-compose/ISSUE-phase3-exact-main-refresh-20260723.md`.
