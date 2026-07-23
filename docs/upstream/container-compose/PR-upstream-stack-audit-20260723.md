# Pull request: refresh and validate the 23 July upstream stack

<!-- markdownlint-disable MD013 -->

## Summary

- Consume current Apple Container history through `9af6e0e` with signed merge
  commits that retain Apple parentage.
- Add focused coverage for Apple's new OCI system-path override API.
- Adopt Apple's asynchronous integration fixture helpers while preserving only
  the fork's matched-runtime arguments and known vmnet-route annotation.
- Pin SwiftPM, release provenance, and README stack metadata to one immutable
  Container revision.
- Re-audit bot changes, upstream bugs, Stephen Clarke's open pull requests,
  Phase 3 scope, and the live VHS recording contract.

## Apple-shaped runtime commits

- `43efb98d07642a619ea2a8b6ef6024cb3dd2c24e` —
  `chore(upstream): sync ContainerTestSupport dependencies`
- `f7612ab5a4018086f8daee70d6d11f45cee286ed` —
  `chore(upstream): sync OCI system path API`
- `bfe4d8306b927ae2594704d94701060a39b3dc6d` —
  `test(runtime): cover OCI system path overrides`
- `271ba58e88844f3d3708d25eb584e6b4ae441ed5` —
  `chore(upstream): sync integration fixture refinements`

The merge commits retain Apple parents `9be73ed`, `72431b0`, and `9af6e0e`.
The only manual integration uses Apple's new async helpers while retaining
fork-only arguments needed to test the source-matched guest.

## Compose commit

`d2464978e156d4ab30db104f3e0abf878fb10a0b`
(`chore(deps): consume current Apple Container fixes`) updates `Package.swift`,
`Package.resolved`, `Tools/release/stack-refs.json`, and README provenance as
one dependency slice. Docker-shaped behavior remains in the Compose layer.

## Scope and upstream disposition

- No Windows functionality is included.
- Linux guest behavior is included only through Apple's macOS runtime.
- No new bot change requires action.
- `apple/container#1965`, `#1934`, `#1935`, and
  `apple/containerization#799` require Apple review but no author changes.
- `apple/container#1986` still has no responsible reproducer; no speculative
  change is included.

## Final validation

The source-matched local release gate passed on the designated Apple silicon
MacBook Pro against the revisions in this handoff:

- Builder: complete unit suite, 44.4% Go statement coverage.
- Containerization: 646 unit tests in 85 suites; 175 of 177 integration tests
  passed, with the two virtio GPU render-node cases skipped as expected on this
  host.
- Container: 1,135 unit tests in 131 suites plus 381 integration tests in 41
  suites; 51.57% combined line coverage.
- Compose: 1,113 Swift tests in 26 suites, 91.38% Swift line coverage, and
  90.06% Go statement coverage.
- Live Compose runtime: 25 of 25 scenarios passed.
- Docker Compose V2: 56 of 56 strict parity contracts passed against
  `docker compose` 5.3.1.

Exact-main hosted CI, SonarQube, Current asset, Homebrew, and rendered-GIF
checks are post-merge publication gates. Their immutable commit, workflow,
asset hashes, publication time, and seven-day soak deadline belong in the
generated Current release evidence so this source commit does not claim a
release that cannot exist until after it is merged.

```sh
CONTAINER_BUILDER_SHIM_STACK_REPO=/path/to/container-builder-shim \
CONTAINERIZATION_STACK_REPO=/path/to/containerization \
CONTAINER_STACK_REPO=/path/to/container \
HOMEBREW_TAP_REPO=/path/to/homebrew-tap \
make release-gate
```

## Checklist

- [x] Signed Conventional Commits
- [x] Current Apple history merged without rewriting it
- [x] Immutable stack pin and provenance consistency
- [x] User worktrees untouched
- [x] README stack snapshot current
- [x] VHS tape types commands and displays live output
- [x] Final matched-stack release gate
- [ ] Post-merge exact-main hosted CI and SonarQube publication gate
- [ ] Post-merge Current assets, Homebrew, and rendered GIF publication gate
