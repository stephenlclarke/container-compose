# Local Opaque Secret Store

## Summary

Add a user-scoped `container secret` resource backed by the macOS Keychain.
It provides immutable opaque bytes and metadata-only management operations.

## Motivation

Applications need a first-class local secret boundary for tokens, certificates,
and other opaque values. A filesystem-backed config store is intentionally not
appropriate because it makes no encrypted-at-rest or read-authorization claim.

## Proposed API

- `ClientSecret.create(name:contents:)`
- `ClientSecret.read(name:)`
- `ClientSecret.list()` and `ClientSecret.inspect(_:)` for metadata only
- `ClientSecret.delete(name:)`
- `container secret create|list|inspect|delete` for provisioning and lifecycle
  management

Names are safe resource identifiers, values are immutable, and replacement is
an explicit delete followed by create. The CLI intentionally has no `read`
subcommand so routine terminal output cannot disclose a secret value.

## Security And Architecture

Keychain access must stay in the client process. `apple/container` processes
some operations through XPC helpers, but Keychain item access controls are
evaluated for the calling process; moving reads to a helper fails for items the
interactive caller owns. This resource therefore uses the generic Keychain
primitive in the API client and does not add a server route or VM-facing secret
payload.

Metadata output never contains value bytes. `inspect` may read internally only
to calculate byte count, while `list` remains metadata-only.

## Out Of Scope

- Remote distribution, Swarm secret emulation, or VM-wide secret injection.
- In-place mutation of a secret already consumed by a running container.
- A value-bearing CLI command or log output.
