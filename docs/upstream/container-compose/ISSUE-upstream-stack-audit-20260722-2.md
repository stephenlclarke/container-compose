# Refresh and validate the complete upstream stack

<!-- markdownlint-disable MD013 -->

## Context

The Phase 3 stack must consume current upstream maintenance before additional
volume and mount work can begin. The audit covered every repository used by the
matched macOS package, automated dependency updates, reproducible Apple issues,
and Stephen Clarke's open upstream pull requests.

The audit snapshot was taken on 22 July 2026 from a physical Apple silicon
MacBook Pro. User worktrees were not modified; every validation used isolated
worktrees.

## Upstream result

- `apple/container-builder-shim` was at `267b5ab9`; the fork tip remains
  `5939a91` (0 behind, 31 ahead).
- `apple/containerization` was at `4f8dc6b5`; the fork tip remains `8d4c408`
  (0 behind, 121 ahead).
- `apple/container` advanced to `f0b2b96`. The fork merged that history and
  now ends at `cb87e7d5b67203548fb970ce2e551494b79a77c7` (0 behind, 258 ahead).
- The three Apple-facing support forks are therefore 410 commits ahead and
  zero commits behind their respective Apple upstreams.
- Dependabot pull request `stephenlclarke/homebrew-tap#1` upgraded
  `actions/checkout` from 6.0.3 to 7.0.0 and was merged as signed commit
  `7a242c690420223b98b34bc33416aee06b651a4a`.

## Reproducible upstream bugs

- `apple/container#1985` reproduced locally: an explicit `127.0.0.1` binding
  below port 1024 failed while an equivalent wildcard binding succeeded.
  Commit `71cdae6b695508086cef81b94e9ad77a633635f6` fixes the reusable macOS
  runtime primitive and adds a real integration regression test.
- `apple/container#1986` did not provide enough context or a runnable
  reproducer for a responsible code change.
- `apple/container#1992` is a CI fixture refinement rather than a product bug.
- The long-line `logs -n` report in `apple/container#1967` is already covered
  by the fork and its tests pass.
- The XPC race described by `apple/container#1987` overlaps the fork's single
  endpoint-resolution fix and remains covered by its tests.

## Pull-request audit

- `apple/container#1933` was superseded by merged upstream work in
  `apple/container#1981` and `apple/containerization#808`; the supersession was
  explained and the pull request was closed.
- `apple/container#1965` was revalidated and marked ready for review. The
  competing `#1987` remains open and unmerged.
- `apple/container#1934` and `#1935` remain mergeable and require only Apple
  review, so no code churn was added.
- `apple/containerization#799` remains mergeable; its reporter confirmed the
  behavior and no maintainer review action is outstanding.
- Fork pull request `stephenlclarke/container#6` was superseded after retaining
  its useful stdout health-test reliability fix and excluding its obsolete
  Makefile changes.

## Implementation boundary

The runtime changes are isolated, reusable, and independently reviewable:

- `3cab3a085a472057f3dd54c391cc4fd5c41fe36a` merges Apple's test-fixture
  maintenance while preserving explicit dependency provenance.
- `71cdae6b695508086cef81b94e9ad77a633635f6` corrects privileged loopback port
  binding in the macOS networking primitive.
- `659a01733ac03c07624b545fb552f1536f80b203` removes an unread stdout pipe from
  health-test support.
- `cb87e7d5b67203548fb970ce2e551494b79a77c7` keeps all upstream handoff
  material centralized in this Compose repository.

Docker-shaped policy remains in the Compose layer. The matched runtime revision
is consumed by signed Compose commit
`b59c33d406e8a19c1dbb6ee74c8457cc64960ab7`; three separate documentation
commits record the fixture sync, health-test reliability fix, and loopback
binding fix (`f8eeefa0`, `4d624e8b`, and `cf4325ad`).

## Validation

The full `make release-gate` passed on the MacBook Pro using isolated source
worktrees for all four repositories:

- builder shim checks, tests, build, and license validation passed; aggregate
  line coverage was 44.4%.
- Containerization passed 646 unit tests in 85 suites and 175 of 177 integration
  tests. The two skips require a virtio-GPU render node that this Mac does not
  expose and are expected.
- Container passed 1,131 unit tests in 131 suites, 3 warmup tests, 238 concurrent
  integration tests in 27 suites, and 143 serial integration tests in 14
  suites. Combined line coverage was 51.61%.
- Compose passed 1,113 Swift tests in 26 suites at 91.39% line coverage, Go
  tests at 90.06% coverage, 25 live runtime tests, and 161 release/CI/coverage
  tool tests.
- All 56 strict parity targets passed against Docker Compose V2 5.3.1 and
  Docker Engine 29.2.1.
- `make check`, Markdown lint, license checks, stack consistency, and
  `git diff --check` passed.

## Recording and release contract

`docs/container-compose-demo.tape` types real commands and displays their live
output. It contains no `Replay`, marker, or transcript helper instructions.
`Tools/release/record-vhs-live-demo.sh` invokes VHS against the matched Current
runtime and permits only a bounded terminal-transport readiness retry; it does
not replay or retry a failed demonstration.

After exact-main hosted CI and SonarQube pass, the signed tree is published as
the mutable [Current prerelease](https://github.com/stephenlclarke/container-compose/releases/tag/current).
That publication starts a new seven-day Phase 3 soak. Phase 4 work must not
begin until the complete interval has elapsed and the Phase 3 stable and
SonarQube gates have passed.
