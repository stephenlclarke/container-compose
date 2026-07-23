# Refresh and validate the 23 July upstream stack

<!-- markdownlint-disable MD013 -->

## Context

Before the next Phase 3 slice, refresh every Apple-facing fork, automated
dependency update, reproducible upstream bug, and Stephen Clarke upstream pull
request. Perform the audit and validation on the designated Apple silicon
MacBook Pro without modifying user worktrees.

## Upstream result

- `apple/container-builder-shim` remains at `267b5ab9`; the fork remains
  `5939a91` (0 behind, 31 ahead).
- `apple/containerization` remains at `4f8dc6b5`; the fork remains `8d4c408`
  (0 behind, 121 ahead).
- `apple/container` advanced through three merged pull requests during the
  slice: [#1994](https://github.com/apple/container/pull/1994),
  [#1996](https://github.com/apple/container/pull/1996), and
  [#1993](https://github.com/apple/container/pull/1993). The fork ends at
  `271ba58e88844f3d3708d25eb584e6b4ae441ed5` (0 behind, 262 ahead).
- The three support forks are 414 commits ahead and zero behind Apple.
- Compose consumes the exact Container tip in signed commit
  `d2464978e156d4ab30db104f3e0abf878fb10a0b`.

## 23 July maintenance follow-up

Apple Container subsequently advanced to
`78e2cb4417640ff2d630c407a1d00ef09c9d3334` with pull request
[#1889](https://github.com/apple/container/pull/1889), which routes the
`system start` status messages through structured logging. The fork already
contained the same behavior in signed commit `0fe78339`; its signed
`d24be8a9` merge therefore retains Apple's parentage without changing the
source tree. Signed handoff commit `248f8e0b` documents that disposition.

The refreshed fork tips are:

- `apple/container-builder-shim`: fork `5939a91`, 0 behind and 31 ahead.
- `apple/containerization`: fork `8d4c408`, 0 behind and 121 ahead.
- `apple/container`: fork `248f8e0`, 0 behind and 264 ahead.

The support forks were then 416 commits ahead and zero behind Apple. Compose
consumed that refreshed Container tip in signed commit `2d973e43`
(`chore(deps): consume latest Apple Container maintenance`).

## Automation and pull-request result

- No new open Dependabot or other bot-authored pull request requires action in
  the four-repository stack. The already-merged Homebrew Actions update remains
  present, and its remote branch deletion required no code change.
- `apple/container#1965`, `#1934`, and `#1935` remain open and await Apple
  review; they have no new comments or actionable review requests.
- `apple/containerization#799` remains open and awaits Apple review. Its only
  follow-up still confirms the copy-lifecycle fix; no maintainer request is
  outstanding.

## Upstream bug disposition

- `apple/container#1985` remains reproducible upstream and is already fixed and
  integration-tested in the fork's signed `71cdae6b` networking primitive.
- `apple/container#1986` still lacks environment data and a deterministic
  reproducer. Compose's custom-network DNS and route reconciliation tests stay
  green, so no speculative runtime change is justified.
- `apple/container#1991` is an enhancement request for machine login-shell
  semantics and is outside Compose Phase 3.
- Previously audited reports for labels containing `=`, long log lines,
  non-root hard links, and XPC lifecycle recovery remain covered by fork tests.

## Phase 3 and recording boundary

The implemented volume/mount matrix remains complete for the local macOS
runtime: named, anonymous, bind, tmpfs, image, config, secret, inherited,
read-only, subpath, copy-up, `nocopy`, reuse, labels, and cleanup behavior.
Driver/plugin semantics, recursive bind modes, and consistency/cache hints
remain explicit non-local or unsupported gaps; Windows named pipes, SELinux,
Swarm, and CSI behavior are out of macOS scope.

`docs/container-compose-demo.tape` types real commands and shows their live
output. It contains no `Replay`, marker, or transcript-helper instruction.
The maintenance follow-up does not change the tape or relax this contract.

## Release gate

The final matched-stack results and Current publication evidence are recorded
in the paired pull-request handoff. The original plan included a seven-day
Phase 3 soak. The repository owner explicitly waived that time gate on 23 July
2026. Stable promotion still requires every source, hosted CI, SonarQube,
release-asset, Homebrew, install-smoke, and rendered-GIF evidence gate; Phase 4
may start after those evidence gates pass.

## 23 July Containerization and automation follow-up

This section supersedes the earlier point-in-time stack and automation
snapshots.

- `apple/container-builder-shim` remains at `267b5ab9`; the fork remains
  `5939a91` (0 behind, 31 ahead).
- `apple/containerization` advanced to
  `2563ed5736cf57bef2bd4efb507572ad3d494206` with
  [#809](https://github.com/apple/containerization/pull/809). Signed merge
  `75bdc3dddaf1f8943c49514d68a40cf4fd3fa846` retains Apple's virtiofs rootfs
  hotplug work while preserving the fork's source-subpath extension.
- The upstream
  [LinuxContainer.create cleanup bug](https://github.com/apple/containerization/issues/804)
  reproduces in the fork: a failed `vm.start()` escaped before the existing
  cleanup path. Signed commit
  `766318bb7d33494838c1896adde1490d8e34c0a4` moves startup into that cleanup
  boundary and proves that the original error is returned after exactly one VM
  stop. Signed handoff commit
  `9097a24d60deddaaa394f73c2ec5f8276ab5867b` is the final Containerization tip
  (0 behind, 124 ahead).
- `apple/container` remains at
  `78e2cb4417640ff2d630c407a1d00ef09c9d3334`. Signed dependency commit
  `8cf9468b861306a801c56924e591e98f39f771e8` consumes the exact validated
  Containerization tip, and signed handoff commit
  `d028c825c8198eca370346f832c8d04d80f12181` is the final Container tip
  (0 behind, 266 ahead).
- Signed Compose commit
  `59482006d8f80f996a38c8d25fe688c27c0b5d4b` updates SwiftPM,
  `Tools/release/stack-refs.json`, and README provenance to those exact tips.
  The three support forks are now 421 commits ahead and zero behind Apple.
- Dependabot pull request
  [#136](https://github.com/stephenlclarke/container-compose/pull/136) contains
  49 action-SHA replacements across nine workflows. Signed commit
  `2f3002d47226c5922bc30f77548c74c0a415dd48` applies the byte-for-byte
  equivalent workflow change so the bot branch can be closed after `main`
  receives it.
- `apple/container#1965`, `#1934`, `#1935`, and
  `apple/containerization#799` remain mergeable, have no actionable author
  feedback, and await Apple review.

The complete source-matched release gate passed on the designated Apple
silicon MacBook Pro:

- Containerization: 647 unit tests in 85 suites; 175 of 177 integration tests
  passed, with two virtio GPU render-node cases skipped on the selected kernel.
- Container: 1,135 unit tests in 131 suites, a warm-up image pass, 238
  concurrent live tests in 27 suites, and 91 global live tests in 11 suites;
  combined line coverage is 51.10%.
- Compose: 1,117 Swift tests in 26 suites, 91.38% Swift line coverage, and
  90.06% Go statement coverage.
- Live Compose runtime: 25 of 25 scenarios passed.
- Docker Compose V2: 56 of 56 strict parity contracts passed against
  `docker compose` 5.3.1.

`docs/container-compose-demo.tape` remains a live recording source: it types
commands, waits for their real on-screen results, and contains no `Replay` or
marker instruction.
