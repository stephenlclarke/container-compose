# Feature request: a constrained runtime-configuration extension point

## Summary

Expose one versioned, allowlisted extension point between Container's persisted
runtime configuration and a selected runtime's configuration builder. This is
not a request for method swizzling, a general-purpose plugin proxy, or a
Compose-specific API.

`ContainerClient.create` already transports opaque runtime data, but the stock
Linux runtime decodes a fixed `LinuxRuntimeData` shape inside its private
configuration path. Consequently, each new runtime primitive currently needs
a coordinated `container` transport patch and a `containerization` projection
patch even when Compose can otherwise supply the feature through its runtime
provider contracts.

## Proposed minimal behavior

- Keep the existing typed runtime configuration as the normal path.
- Let a selected runtime declare a finite set of extension identifiers and
  supported payload versions at registration time.
- Persist an extension as an identifier, version, and opaque payload alongside
  the normal runtime configuration.
- Before OCI specification generation, dispatch only an allowlisted extension
  to its registered runtime handler. The handler must validate its own version
  and produce a constrained, typed runtime configuration mutation.
- Return the negotiated extension identifiers and versions through runtime
  capability discovery, so callers can fail early rather than relying on an
  ignored opaque payload.
- Preserve current behavior when no extension is present, unknown, or not
  negotiated; unknown extensions must be rejected explicitly rather than
  silently ignored.

The handler must not receive arbitrary command text, mutable process state, or
an unconstrained XPC proxy. Its mutation surface should remain auditable and
limited to the runtime configuration model.

## Why this is the smallest useful hook

`container-compose` now owns a zero-dependency `ComposeRuntimeSPI` package
target. Discovery, lifecycle, execution, copy/export, observability,
config/secret, image, and resource providers can be substituted without
modifying Apple repositories; the default providers remain ContainerClient-
or CLI-backed. A new runtime-only feature is different: no Compose-side
decorator can make the stock Linux runtime apply an operating-system primitive
it does not expose.

Replacing the runtime plugin is not a practical alternative: it would require
proxying the complete runtime XPC surface and owning the current Linux runtime
implementation. A generic interception framework would be broader, less safe,
and harder to support than one explicit configuration-extension chain.

The hook therefore reduces repeated cross-repository patches while keeping
Compose parsing, validation, selection, output, and orchestration outside
Apple's codebase.

## Upstream overlap review

- [apple/container#1376](https://github.com/apple/container/issues/1376)
  requests a runtime-agnostic API server and is the natural architectural
  parent for this work.
- [apple/container#1923](https://github.com/apple/container/issues/1923)
  requests runtime registration for network-plugin strategy configuration; it
  is a concrete sibling use case for capability negotiation and an allowlist.
- A review of open Apple issues and pull requests for “runtime configuration”
  and “runtime plugin” on 2026-07-17 found no narrower proposal for a
  versioned runtime-configuration extension chain.

This is a planning-only handoff. It is not constructible yet and deliberately
does not correspond to a fork commit or an Apple pull request. It should be
revisited only when a specific missing runtime primitive cannot be provided by
the Compose-side provider boundary.
