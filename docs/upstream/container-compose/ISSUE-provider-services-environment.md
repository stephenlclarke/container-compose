# Complete provider-service environment parity

## Problem

Compose provider services use a line-oriented external-process protocol.
`container-compose` already supported provider `setenv` messages, but it did
not support Docker Compose V2's `rawsetenv` form and did not pass the resolved
project environment to provider metadata or lifecycle commands.

That creates two observable compatibility gaps:

- providers cannot publish an exact dependent-service variable name; and
- providers cannot consume values resolved from the Compose project
  environment, including `.env`.

## Reproduction

Given a provider that emits:

```text
setenv | API_URL=https://provider.example
rawsetenv | SHARED_TOKEN=from-provider
```

and a dependent service that already defines `SHARED_TOKEN`, Docker Compose V2
injects both:

- `<PROVIDER>_API_URL=https://provider.example`; and
- `SHARED_TOKEN=from-provider`.

Docker Compose also emits a visible diagnostic when the raw value replaces the
dependent service's existing value. Provider commands receive the resolved
project environment, but not service-only environment values.

Before this slice, `container-compose` accepted only `setenv`, rejected the
`rawsetenv` line as malformed, and launched provider commands without the
project environment.

## Ownership

This is a Compose adapter concern. Provider services and their wire protocol
are Compose concepts. Apple Containerization, Apple Container, and the builder
shim require no Docker-shaped API or stored state.

The implementation should extend the existing provider abstraction and keep
prefixed and raw values separate until dependency injection:

| Provider message | Dependent value |
| --- | --- |
| `setenv` | Provider-service-name prefix plus normalized key |
| `rawsetenv` | Exact key |

## Expected behavior

- Parse valid `setenv` and `rawsetenv` protocol messages.
- Reject either form when the key/value separator or key is missing.
- Inject provider results only into direct dependents.
- Preserve the existing `setenv` prefix behavior.
- Allow an empty raw value.
- Emit a diagnostic only when a raw value changes an existing dependent value.
- Pass the normalized project environment to metadata and lifecycle commands.
- Do not expose dependent service-only environment values to the provider.

## Acceptance criteria

- [x] The implementation is confined to `container-compose`.
- [x] Focused unit tests cover valid, empty, identical, replacement, and
  malformed values.
- [x] A Compose YAML fixture exercises a real external provider.
- [x] Docker Compose V2 5.3.1 and the matching macOS runtime fixture agree.
- [x] Full Swift and Go coverage thresholds pass.
- [x] The signed implementation commit is identified in the PR handoff.
