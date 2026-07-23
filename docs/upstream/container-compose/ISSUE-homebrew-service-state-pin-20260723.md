# Consume the service-independent Container formula smoke

## Context

The Phase 3 stable release `0.8.0` passed its complete local, hosted,
SonarQube, package, checksum, provenance, Homebrew, and Docker Compose v2 gates.
An installed-package validation then ran `brew test` after starting the
documented stable Container service.

The Container formula incorrectly required `container list` to fail with an
unavailable-daemon error. A healthy running service made the command succeed,
so Homebrew reported `Expected: 1, Actual: 0` even though the stable runtime
and Compose plugin were operating correctly.

Container commit
[`701c1c4ef991ee3b1cb147c3a777f7d3d566d497`](https://github.com/stephenlclarke/container/commit/701c1c4ef991ee3b1cb147c3a777f7d3d566d497)
changes the maintained formula smoke to `container list --help`, and commit
[`5de53c9bbcff3d3c4e8072728cb77f6061b2fdd4`](https://github.com/stephenlclarke/container/commit/5de53c9bbcff3d3c4e8072728cb77f6061b2fdd4)
adds its issue and pull-request handoff.

## Required behavior

- Pin Compose package resolution and release metadata to the reviewed
  Container documentation tip.
- Keep the runtime and Containerization executable refs otherwise unchanged.
- Regenerate stable and Current formulae from the corrected maintained
  template.
- Preserve the already-published immutable `0.8.0` runtime and plugin assets.
- Revalidate the stable installed pair and publish the next Current prerelease
  from the final documentation commit.

## Resolution

The signed Compose commit
[`cf9aa1b75292645736a06ccef7f1a786a923d67d`](https://github.com/stephenlclarke/container-compose/commit/cf9aa1b75292645736a06ccef7f1a786a923d67d)
updates `Package.swift`, `Package.resolved`, and the release stack manifest to
`5de53c9b`.

Homebrew tap commit
[`abff3f3894d5140179a33a48d5ecbff32bbbba5b`](https://github.com/stephenlclarke/homebrew-tap/commit/abff3f3894d5140179a33a48d5ecbff32bbbba5b)
repairs both active Container formula lanes without changing either package
URL, version, or checksum.

## Validation

```console
swift package resolve
make stack-consistency coverage-tools-test check
brew update
brew test stephenlclarke/tap/container
brew test stephenlclarke/tap/container-compose
container compose --project-name phase3-stable-080-smoke \
  --file Tests/ComposeRuntimeTests/Fixtures/volume-reuse/compose.yml up --detach
container compose --project-name phase3-stable-080-smoke \
  --file Tests/ComposeRuntimeTests/Fixtures/volume-reuse/compose.yml \
  exec --no-tty writer cat /data/marker
container compose --project-name phase3-stable-080-smoke \
  --file Tests/ComposeRuntimeTests/Fixtures/volume-reuse/compose.yml \
  down --volumes
```

Observed on Apple silicon macOS:

- SwiftPM resolved only the intended Container revision.
- Stack consistency and release tooling passed 174 Python tests plus shell
  policy fixtures.
- The corrected stable Container and Compose formula tests passed.
- The installed stable pair reported Compose `0.8.0`, Container
  `d028c825c819`, and Containerization `9097a24d60de`.
- The live named-volume smoke started the service, reported it as running,
  read `volume-reuse-ok`, removed the project and volume, then reported no
  remaining project containers.
- Container's full validation passed 1,134 normal tests and 1,135 instrumented
  tests in 131 suites, with 38.82% line unit coverage.

The automatic Current workflow is the authoritative exact-main prerelease
evidence. It must bind CI, SonarQube, CodeQL, package metadata, checksum
sidecars, attestations, the atomic Homebrew pair, and the direct typed-command
VHS recording to the final documentation commit.

## Commit tracking

- Container formula correction:
  `701c1c4ef991ee3b1cb147c3a777f7d3d566d497`.
- Container handoff:
  `5de53c9bbcff3d3c4e8072728cb77f6061b2fdd4`.
- Compose pin:
  `cf9aa1b75292645736a06ccef7f1a786a923d67d`.
- Homebrew active-lane repair:
  `abff3f3894d5140179a33a48d5ecbff32bbbba5b`.
