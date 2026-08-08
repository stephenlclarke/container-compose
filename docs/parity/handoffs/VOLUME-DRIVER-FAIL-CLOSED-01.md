# VOLUME-DRIVER-FAIL-CLOSED-01 Handoff

## State

`Implemented` — the generic Container component now fails closed before local
volume allocation, with a signed local source checkpoint and focused proof.
This is not yet `Verified`: the current source graph has no Engine-volume
adapter, so an exact-fingerprint public Docker Engine REST/CLI candidate cannot
be assembled truthfully yet.

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

- `container-compose` `main` is at
  `3e16c8ea74953a531d03f3b59aa02e45641e543c`; this handoff is its parity
  evidence record and does not move a package pin.
- `container` is the local Apple-shaped branch
  `upstream/volume-driver-fail-closed-01` at signed commit
  `fcec20e20a34b9e8b9a8cf2b23823ce8a065cdb4`.
- The tested Container `Package.resolved` SHA-256 is
  `61cee1f284cca13e99a042c8cb716e1d962b2e826c64ef6541f07c168f64ebc5`.
- No Containerization or Engine API source/pin changes are part of this
  implementation checkpoint.
- This Container package manifest has no `container-engine-api` dependency or
  `container-engine` product. The retained public-socket branch has 207 unique
  commits beyond this source base and its Engine route ledger declares
  `VolumeCreate` but defaults it to unimplemented; it contains no volume
  backend/handler.

## Focused proof

```sh
swift format lint --strict \
  Sources/Services/ContainerAPIService/Server/Volumes/VolumesService.swift \
  Tests/ContainerAPIServiceTests/VolumeDriverResolutionTests.swift
swift test --filter VolumeDriverResolutionTests
swift test --enable-code-coverage --filter VolumeDriverResolutionTests
```

The focused suite passed four tests. It proves built-in local-driver
normalization, unavailable-driver rejection, zero local volume-directory
allocation even with an otherwise-invalid size option, and a successful
ext4-backed local volume. The instrumented run covers every changed production
line in `VolumesService.swift`; the wider existing file is below the global
coverage target and remains visible rather than being inflated with low-value
tests.

The Engine prerequisite was inspected without starting a candidate: the route
ledger declares `/volumes/create`, but the current public controller has no
`VolumeCreate` implementation or volume backend protocol. That is a concrete
missing integration capability, not a failed runtime result or a performance
finding.

## Completion criteria

- A fresh marker-protected Docker oracle retains the failure phase, absence of
  the volume, and raw duration.
- A coherent Engine-volume adapter advertises `VolumeCreate`, calls the same
  `VolumesService` authority, and maps driver-resolution errors at the Docker
  provider-resolution phase before a candidate is assembled.
- An isolated candidate then binds its source SHA, dependency revisions, built
  binary, guest/init image, and disposable root into one exact fingerprint.
- The same unmodified Docker CLI and Engine REST path fails before local
  allocation, exposes no inspectable volume, leaves no residue, and completes
  within the explicit liveness bound.
- The candidate error is mapped at the Docker-compatible provider-resolution
  phase and the Container and Compose evidence checkpoints are clean and
  signed.

## Blocker criteria and next safe action

An unexpected hang, timeout, or liveness-bound breach is an immediate blocker.
The missing Engine-volume adapter is the current prerequisite: do not build a
candidate from this graph and call the resulting unimplemented route a volume
test. First land the coherent adapter against a dependency-compatible public
socket stack. If a later exact candidate does not expose the underlying
driver-resolution error, add a narrow typed diagnostic at that mapping boundary
before a second runtime attempt. Do not retry after two evidence-based
corrections without new causal evidence.

The next safe action is the `ENGINE-VOLUME-CREATE-ROUTE-01` implementation:
land one Engine-volume backend/route through the selected Container authority,
then build a fresh candidate in a marker-protected root, write its complete
fingerprint before start, and run the unavailable-driver Docker CLI/REST
fixture once. Do not call this contract `Verified` before that evidence exists.

## Safe handoff

Preserve the signed Container commit, the upstream handoff pair
`docs/upstream/ISSUE-90.md` and `docs/upstream/PR-90.md`, and the issue #90
comment. No candidate root has been assembled yet, so a later runtime attempt
must create a new marker-protected disposable root rather than reuse an
untracked directory. Keep issue #90 open until the public-boundary acceptance
evidence exists.

## Documentation disposition

The gap-only `STATUS.md` is intentionally unchanged. This record distinguishes
an implemented fail-closed provider boundary from full non-local-volume or
Docker Engine runtime support, and records performance only as later design
and evidence work.
