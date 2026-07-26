# Unconfigured image-volume discovery must fail closed

## Problem

`ComposeUnconfiguredRuntime` reports an explicit missing-provider error for
runtime operations, but its declared image-volume lookup returned an empty
array. The orchestrator treated that empty result as authoritative.

A library consumer could therefore construct runtime-backed image-volume
plans without installing a runtime provider. Dockerfile `VOLUME` targets,
implicit anonymous volumes, and eligible copy-up work were silently omitted
instead of producing a configuration error.

The protocol default was already safe because it delegates declared-volume
lookup to image metadata. The concrete public default provider was the sole
fail-open exception.

## Resolution

Signed commit
[`5d5327904ee38d0db7ad8faddbbd8fd448750abc`](https://github.com/stephenlclarke/container-compose/commit/5d5327904ee38d0db7ad8faddbbd8fd448750abc)
changes both image-volume metadata preparation and declared-volume lookup to
throw:

```text
unsupported compose feature: image metadata lookup requires an installed Compose runtime provider
```

The planner now stops before creating a network, volume, or container.
Configured providers retain their existing metadata and copy-up behavior.

## Apple-shaped boundary

| Layer | Responsibility |
| --- | --- |
| `ComposeRuntimeSPI` | Define runtime-neutral image metadata contracts. |
| `ComposeCore` | Fail explicitly when a required provider is absent. |
| Apple runtime forks | Supply generic image metadata and volume primitives. |

This is a Compose-only default-provider correction. It adds no Docker policy
to an Apple repository, no Windows behavior, and no new lower-runtime API.

## Source map

- `Sources/ComposeCore/ComposeUnconfiguredRuntime.swift` removes the two
  image-volume fail-open paths.
- `Tests/ComposeCoreTests/ComposeRuntimeProviderDefaultsTests.swift` covers
  all 38 concrete unconfigured-provider operations and the direct planner.
- `Tests/ComposeCoreTests/ComposeOrchestratorTestRuntime.swift` makes tests
  that intentionally model an image with no declared volumes say so
  explicitly.
- `Tests/ComposeCoreTests/ExternalConfigOrchestratorTests.swift` injects that
  explicit test provider into its configured runtime fixture.

## Acceptance

- Every concrete unconfigured provider operation has contract coverage.
- Declared-volume planning fails before resource creation without a provider.
- Existing configured image-volume behavior remains green against Docker
  Compose V2 and the source-matched Apple runtime stack.
- The complete coverage floor remains above 90% Swift and 85% Go.

## Compatibility and deletion

There is no supported caller that should depend on missing image metadata
being interpreted as an empty declaration. Callers that deliberately model
an image with no declared volumes must provide a configured provider returning
that result.

The Compose correction remains necessary even if Apple accepts every current
runtime primitive: absence of a provider is a Compose library configuration
state, not an Apple runtime behavior.
