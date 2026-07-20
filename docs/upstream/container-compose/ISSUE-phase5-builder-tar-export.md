# Phase 5 gap: Builder tar exports do not reach all requested macOS destinations

## Problem

The generic `container build -o type=tar,dest=...` path accepts a tar exporter,
but its macOS handoff is incomplete:

- a direct, non-existing destination such as `export.tar` exits with status 1
  and does not create the archive;
- the first and second exports to an existing directory both fail to produce
  the required `out.tar` and `out.tar.1` files; and
- one export to an existing directory succeeds and produces `out.tar`, while
  validation without `dest` correctly fails.

This is not a Compose-file field gap: Compose's normal image output continues
to use the default image lane. It is a generic macOS Builder capability gap
that blocks Docker BuildKit-compatible tar output semantics and must be fixed
below the Compose adapter.

## Evidence

The 0.7.0 matched local gate reached the global serial Container partition with
all other selected suites passing, then recorded failures in
`TestCLIBuilderTarExportSerial`. The isolated repeat confirms eight assertion
failures across these two tests:

- `testBuildExportTar` — direct file destination;
- `testBuildExportTarMultipleRuns` — first and second directory exports.

`testBuildExportTarToDirectory` and `testBuildExportTarInvalidDest` pass in the
same isolated run. The failure therefore is not parser acceptance: it is the
post-build archive delivery contract.

## Required Apple-shaped change

Implement a narrow generic output-transfer abstraction that owns the lifecycle
of a Builder tar result and delivers it to the exact host destination. It must:

1. retain the existing direct-file destination semantics;
2. make the existing-directory form select `out.tar`, then `out.tar.1`, without
   losing the first result;
3. keep all destination resolution and host file writes in generic Builder
   code, not in `container compose`; and
4. preserve structured errors for missing `dest` and unsupported exporters.

The likely implementation and test starting points are:

- `container/Sources/ContainerBuild/Builder.swift` — `BuildExport` destination
  normalization and the build metadata boundary;
- `container/Sources/ContainerCommands/BuildCommand.swift` — the current
  post-build staging and move step;
- `container/Sources/ContainerBuild/BuildPipelineHandler.swift` — add the
  explicit output-transfer handler instead of assuming a staging file exists;
- `container-builder-shim/pkg/build/build.go` — preserve the generic Builder
  output stream/staging contract without teaching it Compose paths;
- `container/Tests/ContainerBuildTests/BuilderMetadataTests.swift`; and
- `container/Tests/IntegrationTests/Build/TestCLIBuilderTarExportSerial.swift`.

The change should be split into Apple-reviewable commits: first the generic
destination/transfer abstraction with unit tests, then the matched VM-backed
integration coverage. No Compose-layer workaround should move archives or
special-case paths.

## Release boundary

Until the generic implementation and its full suite pass, the 0.7.0 Phase 1
local release gate may exclude only `TestCLIBuilderTarExportSerial` together
with the two separately documented external-Dockerfile suites
`TestCLIBuilderSerial` and `TestCLIBuilderLocalOutputSerial`. The exception is
milestone-only, version-bound, local-only, and rejected by hosted validation;
it is not a parity claim.
