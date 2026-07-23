# Full Quality dispatch exposes accumulated Swift style debt

## Problem

The `push` lane of the Quality workflow correctly limits strict Swift style
checks to changed files. A manual full `workflow_dispatch`, which is required
before a prerelease handoff, selects every non-legacy Swift source and test.
That full lane failed on files introduced or expanded by earlier parity slices:

- 37 SwiftLint findings across argument rewriting, labels, watch lifecycle,
  network creation, restart policy, process execution, and their tests.
- 17 additional non-legacy files that did not satisfy the repository's
  SwiftFormat policy.

The push CI, CodeQL, SonarQube, sanitizer, unit, integration, and parity paths
could all be green while the explicit release-quality workflow remained red.

## Expected behavior

- Every non-legacy file selected by a full Quality dispatch passes strict
  SwiftLint and SwiftFormat.
- Oversized or complex phase-work units are decomposed instead of hidden behind
  new file-wide exclusions.
- Process output continues to use lossy UTF-8 decoding so one invalid byte does
  not discard all captured output.
- Runtime behavior, public command spelling, and Docker Compose parity remain
  unchanged.
- The build documentation identifies the full Quality dispatch as a prerelease
  gate.

## Acceptance criteria

- A local reproduction of the workflow path selection passes strict SwiftLint
  and SwiftFormat for all selected files.
- The complete Swift suite and coverage gate pass.
- Swift line coverage remains at or above 90%; Go statement coverage remains at
  or above 85%.
- Exact-main hosted CI, CodeQL, Documentation, and a full Quality dispatch pass.
- SonarQube reports the exact revision, a passed quality gate, and zero
  unresolved issues.
- The automatic Current workflow packages the exact final revision and updates
  the Homebrew formula pair atomically.

## Implementation references

- `ac6d82e4a5b0a91cd222bc5e27372edde94cd6b1`
  `refactor(quality): clear full Swift lint gate`
- `f5605fbe242fcbddcb24cc1da057d34aa0edbadc`
  `style(swift): format full quality surface`

## Platform scope

This correction is implemented in the Compose layer and is platform-neutral
Swift maintenance. It adds no Windows behavior and changes no Apple runtime
primitive.
