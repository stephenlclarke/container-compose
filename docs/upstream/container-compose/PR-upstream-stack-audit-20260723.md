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

## 23 July Apple Container maintenance follow-up

Apple Container advanced once more to
`78e2cb4417640ff2d630c407a1d00ef09c9d3334` with the structured startup-log
change from [#1889](https://github.com/apple/container/pull/1889). The fork had
already implemented that behavior in signed commit
`0fe78339ac28d6fca33eeaa94bfd1f09aa772529`. Signed, source-empty merge
`d24be8a91ea82baa27f9546e82897e52dcc6862b` retains Apple's new ancestry, and
signed commit `248f8e0b0f12179835d7902f4922d3c652421ff3` provides the focused
Apple handoff.

Compose commit `2d973e4380f3e8583d4197ee199de2cde7e4253d`
(`chore(deps): consume latest Apple Container maintenance`) updates only the
SwiftPM pins, immutable stack reference, and README provenance. The resulting
support stack is 416 commits ahead and zero behind Apple:

- Builder `5939a91`: 31 ahead.
- Containerization `8d4c408`: 121 ahead.
- Container `248f8e0`: 264 ahead.

The follow-up audit found no open bot pull request, no newly updated Apple bug
requiring a reproducible fork fix, and no author action on
`apple/container#1965`, `#1934`, `#1935`, or
`apple/containerization#799`. All four Stephen Clarke pull requests are
mergeable and await only Apple review. The Docker-shaped implementation and
the live, typed-command VHS tape are unchanged.

The complete matched-stack release gate was rerun on the designated Apple
silicon MacBook Pro after the maintenance sync:

- Builder: complete unit suite, 44.4% Go statement coverage.
- Containerization: 646 unit tests in 85 suites; 175 of 177 integration tests
  passed, with the two virtio GPU render-node cases skipped as expected.
- Container: 1,135 unit tests in 131 suites plus 381 integration tests in 41
  suites; 51.58% combined line coverage.
- Compose: 1,114 Swift tests in 26 suites, 91.39% Swift line coverage, and
  90.06% Go statement coverage.
- Live Compose runtime: 25 of 25 scenarios passed.
- Docker Compose V2: 56 of 56 strict parity contracts passed against
  `docker compose` 5.3.1.

Exact-main CI, SonarQube, Current assets, signed Homebrew pair, install smoke,
and rendered-GIF verification remain post-push publication gates. The
repository owner explicitly waived the seven-day Phase 3 time gate on 23 July
2026; that waiver does not bypass any of these evidence gates.

## 23 July Containerization and automation follow-up

This follow-up supersedes the earlier point-in-time stack, automation, and
validation snapshots.

### Runtime follow-up commits

- Containerization merge
  `75bdc3dddaf1f8943c49514d68a40cf4fd3fa846`
  (`chore(upstream): merge apple containerization main`) retains Apple
  [#809](https://github.com/apple/containerization/pull/809) parentage and
  preserves the fork's narrow source-subpath extension.
- Containerization fix
  `766318bb7d33494838c1896adde1490d8e34c0a4`
  (`fix(runtime): stop VM when create startup fails`) fixes reproduced Apple
  [#804](https://github.com/apple/containerization/issues/804) by placing
  `vm.start()` inside the existing create cleanup boundary. The focused fake
  verifies the original startup error, exactly one stop, and terminal VM state.
- Containerization handoff
  `9097a24d60deddaaa394f73c2ec5f8276ab5867b`
  (`docs(upstream): hand off July runtime updates`) provides the matching issue
  and pull-request templates.
- Container dependency
  `8cf9468b861306a801c56924e591e98f39f771e8`
  (`build(deps): update Containerization runtime`) consumes that exact runtime.
- Container handoff
  `d028c825c8198eca370346f832c8d04d80f12181`
  (`docs(upstream): hand off runtime dependency sync`) provides the matching
  issue and pull-request templates.

The final support stack is zero commits behind Apple and 421 commits ahead:
Builder `5939a91` (31), Containerization `9097a24` (124), and Container
`d028c82` (266).

### Compose and automation commits

- `59482006d8f80f996a38c8d25fe688c27c0b5d4b`
  (`build(deps): update validated runtime stack`) pins SwiftPM, immutable
  release refs, and README provenance to the validated lower-fork commits.
- `2f3002d47226c5922bc30f77548c74c0a415dd48`
  (`build(actions): refresh GitHub Actions pins`) is byte-for-byte equivalent
  to Dependabot
  [#136](https://github.com/stephenlclarke/container-compose/pull/136): 49
  action-SHA replacements across nine workflows.

The bot pull request should be closed after the equivalent signed commit lands
on `main`. No author action is required on `apple/container#1965`, `#1934`,
`#1935`, or `apple/containerization#799`; all four remain mergeable and await
Apple review.

### Final local validation

- Builder: complete unit suite and enforced Go coverage.
- Containerization: 647 unit tests in 85 suites; 175 of 177 integration tests
  passed, with two virtio GPU render-node cases skipped on the selected kernel.
- Container: 1,135 unit tests in 131 suites, plus 238 concurrent and 91 global
  live tests; combined line coverage is 51.10%.
- Compose: 1,117 Swift tests in 26 suites, 91.38% Swift line coverage, and
  90.06% Go statement coverage.
- Live Compose runtime: 25 of 25 scenarios passed in 166.5 seconds.
- Docker Compose V2: all 56 strict parity contracts passed against
  `docker compose` 5.3.1.
- VHS: `docs/container-compose-demo.tape` types commands and asserts their live
  screen output; it contains no `Replay` or marker instruction.

The Phase 5 builder-gap exception remains bounded to the three documented
external Dockerfile/tar-output integration suites. It does not weaken the Phase
3 volume/mount stable gate and must be removed as part of Phase 5.

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
- [x] Containerization upstream and reproducible-bug follow-up
- [x] Dependabot change applied as an equivalent signed commit
- [x] Owner-authorized Phase 3 soak waiver recorded
- [ ] Post-merge exact-main hosted CI and SonarQube publication gate
- [ ] Post-merge Current assets, Homebrew, and rendered GIF publication gate
