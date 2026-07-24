# Resolved Phase 5 gap: external Dockerfile paths in the Builder bridge

> Resolved by Apple [`container@d1d7635`](https://github.com/apple/container/commit/d1d763530df3c6a326dbae7f0c0a59a335808045),
> synchronized into the signed fork as
> [`1bc3167`](https://github.com/stephenlclarke/container/commit/1bc31674629287f3386637db4c6d8652dc36602a)
> with the fixture-only reconciliation
> [`abed15f`](https://github.com/stephenlclarke/container/commit/abed15fdd0cafe340f8aceb65080e4a88d0ceb0a).
> The former release exception is removed by
> [the Phase 5 closure handoff](PR-phase5-builder-release-exception-closure.md).

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

## Required Apple-shaped change (completed upstream)

Extend the generic Builder file-sync boundary so it can transfer a declared,
existing Dockerfile from outside the context without broadening context access
for arbitrary `ADD`/`COPY` inputs. The implementation must canonicalise the
two paths consistently, including macOS `/tmp` and `/private/tmp` aliases, and
keep the context-child restriction for normal build-context requests.

The relevant generic code and test boundaries are:

- `Sources/ContainerBuild/BuildFSSync.swift`
- `Sources/ContainerBuild/URL+Extensions.swift`
- `Tests/ContainerBuildTests/BuilderExtensionsTests.swift`
- `Sources/ContainerCommands/Builder/BuilderStart.swift`
- `Tests/IntegrationTests/Build/TestCLIBuilder.swift`
- `Tests/IntegrationTests/Build/TestCLIBuilderLocalOutput.swift`

Compose should remain an adapter: once the generic Builder accepts the declared
Dockerfile input, its existing `build.dockerfile` projection should require no
Compose-specific filesystem escape.

## Original failure evidence

The first 0.7.0 release candidate ran the complete matched Container suite. The
primary non-serial partition passed 233 tests in 26 suites. Its global serial
partition recorded 37 issues in `TestCLIBuilderSerial`; a later isolated repeat
also recorded two issues in `TestCLIBuilderLocalOutputSerial`. Both suites pass
a declared Dockerfile outside the build context and share the external-path
rejection. A later complete local run also exposed the separate Phase 5
tar-export gap documented in
[the tar-export handoff](ISSUE-phase5-builder-tar-export.md). The local 0.7.0
exception excludes those two external-Dockerfile suites and the tar-export
suite, requires an explicit milestone reason, and is rejected by hosted
validation. It does not mark either functionality as supported.

## Closure evidence

Apple's synchronized suite now keeps the existing-Dockerfile-outside-context
case in `TestCLIBuilder` and the different Dockerfile/build-context case in
`TestCLIBuilderLocalOutput`. The exact matched fork passes both suites. The
Compose-owned
`make docker-compose-build-external-dockerfile-parity` target additionally
compares Docker Compose V2 and `container compose` config and bake paths, then
builds and runs the same fixture through both live engines. No Compose-specific
filesystem escape or `/tmp` alias workaround was added.
