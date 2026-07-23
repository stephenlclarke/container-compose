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

## Release gate

The final matched-stack results and Current publication evidence are recorded
in the paired pull-request handoff. Publication starts a new seven-day Phase 3
soak; Phase 4 must not start until the complete interval and all stable and
SonarQube gates have passed.
