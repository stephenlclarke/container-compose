# Phase 5 gap: external Dockerfile paths are rejected by the Builder bridge

## Problem

Docker Compose V2 permits `build.dockerfile` to point at an existing file
outside the local `build.context`. The matched macOS Builder path instead
transfers that file through `BuildFSSync` as though it were a child of the
context. The transfer is rejected with `path is not a child of context`.

On macOS, `/tmp` resolves through the `/private/tmp` alias, so the same failure
can show the two spelling variants. The alias is evidence of the path boundary;
the underlying gap is that the Dockerfile is external to the context.

## Scope

- This is Phase 5 build/runtime work, not Phase 1 process, resource,
  namespace, or security work.
- It applies to local macOS Builder-backed builds. Windows behavior is out of
  scope.
- `build.dockerfile` within the effective local context and remote-context
  pass-through remain supported.

## Required Apple-shaped change

Extend the generic Builder file-sync boundary so it can transfer a declared,
existing Dockerfile from outside the context without broadening context access
for arbitrary `ADD`/`COPY` inputs. The implementation must canonicalise the
two paths consistently, including macOS `/tmp` and `/private/tmp` aliases, and
keep the context-child restriction for normal build-context requests.

The likely code and test starting points are:

- `Sources/ContainerBuild/BuildFSSync.swift`
- `Sources/ContainerBuild/URL+Extensions.swift`
- `Tests/ContainerBuildTests/BuilderExtensionsTests.swift`
- `Tests/IntegrationTests/Build/TestCLIBuilderSerial.swift`

Compose should remain an adapter: once the generic Builder accepts the declared
Dockerfile input, its existing `build.dockerfile` projection should require no
Compose-specific filesystem escape.

## Evidence

The 0.7.0 release candidate ran the complete matched Container suite. The
primary non-serial partition passed 233 tests in 26 suites. The global serial
partition recorded 37 issues in `TestCLIBuilderSerial`; the failing cases share
the external-Dockerfile path rejection. The local release exception excludes
only that suite, requires an explicit 0.7.0 milestone reason, and is rejected
by hosted validation. It does not mark this functionality as supported.
