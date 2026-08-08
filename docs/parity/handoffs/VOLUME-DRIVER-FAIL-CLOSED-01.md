# VOLUME-DRIVER-FAIL-CLOSED-01 Handoff

## State

`Blocked` — the generic Container component and its public Engine adapter are
implemented and focused-proofed, but the exact normal dependency graph cannot
assemble a full-service candidate. Container `8b7c0ef` requires
`WorkloadNetworkEndpoint`; its checked-in Containerization pin `77f06d4` does
not define that type. The clean `ecb2ac5` local overlay does, but substituting
it would not establish the required normal resolved graph.

## User-visible contract

When a user requests a named volume with an unavailable driver, the Container
provider must fail during driver resolution before it creates a volume record,
directory, ext4 image, or container mutation. An omitted driver and an explicit
`local` driver resolve to Container's built-in local volume provider.

## Explicit non-goals

This contract does not implement Docker volume-plugin discovery, plugin
lifecycle, remote mounts, NFS, cloud drivers, driver-option semantics, Compose
projection, devcontainer adoption, migration, or release publication. It
designs for a later typed provider registry but only prevents false success
today. Performance optimisation and comparable-or-better timing are deferred
until functional parity; a hang, timeout, or liveness-bound breach remains a
functional blocker.

## Pinned Docker oracle

On this MBP, Docker CLI `29.7.1` against Engine `29.2.1` (API `1.53`) attempted
to create a uniquely named volume using a uniquely named unavailable driver.
Docker failed during provider lookup with `plugin "<driver>" not found` and a
subsequent inspect returned `no such volume`. The oracle completed in about
twelve seconds with no volume record; it did not hang.

## Affected repositories and inputs

- `container` is the local Apple-shaped branch
  `upstream/volume-driver-fail-closed-01` at signed commit
  `fcec20e20a34b9e8b9a8cf2b23823ce8a065cdb4`.
- The public integration successor is signed Container
  `8b7c0ef8a911288783883b18b2519225829c4e21` and signed Engine API
  `987f05119c0fd6cc8e17c707ffd0c94fbd7d997e`, both on dedicated local
  `upstream/engine-volume-create-route-01` worktrees.
- The successor’s exact focused graph uses local Containerization
  `ecb2ac5099a8521f02c248870fa6dd7aa7518465`; the checked-in pin remains
  `77f06d4c44341e04241941072fb69e2b85a6f5c1`. No published pin moved.
- Marker-protected blocker evidence is retained at
  `/private/tmp/volume-normal-graph-blocker-01.kFETSt`.

## Focused proof

```sh
swift format lint --strict \
  Sources/Services/ContainerAPIService/Server/Volumes/VolumesService.swift \
  Tests/ContainerAPIServiceTests/VolumeDriverResolutionTests.swift
swift test --filter VolumeDriverResolutionTests
swift test --enable-code-coverage --filter VolumeDriverResolutionTests
```

The original four-test component suite proves built-in local-driver
normalization, unavailable-driver rejection, zero local volume-directory
allocation despite an invalid size option, and a successful ext4-backed local
volume. The successor adds seven native authority/route/CLI tests, two adapter
tests, three Engine volume tests, and five gateway tests. Its unmodified Docker
CLI test uses only a disposable candidate Unix socket and proves no allocation
or native residue; see the successor handoff for exact commands, fingerprints,
cleanup, and the coverage disposition.

## Completion criteria

- Make the normal Container dependency graph compatible, then build one fresh
  full `container-engine` candidate that fingerprints source, dependencies,
  binary/archive, guest/init images, fixture, and a marker-protected root.
- The public Docker CLI and REST path must fail before allocation, leave no
  inspectable/native residue, and complete within its liveness bound.
- Refresh a responsive Docker oracle before claiming any additional raw
  error-envelope detail. Keep source/evidence checkpoints clean and signed.

## Blocker criteria and next safe action

A candidate hang, timeout, liveness-bound breach, fingerprint mismatch, or
cleanup failure is an immediate blocker. The normal graph is already blocked:
the locked Containerization revision has no `WorkloadNetworkEndpoint`, while
the retained Container source requires it in the Engine authority/runtime
paths. The missing Engine-volume adapter is closed; do not repeat source-only
implementation work or alter a lockfile to mask this incompatibility. Resume
only after an independently verified dependency-alignment contract produces a
clean normal graph.

## Safe handoff

Preserve signed Container `fcec20e`, signed Container `8b7c0ef`, signed Engine
API `987f051`, the upstream handoff pair `docs/upstream/ISSUE-90.md` and
`docs/upstream/PR-90.md`, and issue #90. A later runtime attempt must create a
new marker-protected disposable root rather than reuse an untracked directory.
Keep issue #90 open until the full public-boundary acceptance evidence exists.
Retain `/private/tmp/volume-normal-graph-blocker-01.kFETSt` as the exact
no-mutation proof of the current dependency blocker.

## Documentation disposition

`STATUS.md`, the gap-only ledger, and the volume/socket design now link the
implemented public route to its remaining full-service gap. This record still
distinguishes an implemented fail-closed provider boundary from full
non-local-volume or Docker Engine runtime support, and treats performance as
later design/evidence work unless liveness fails.
