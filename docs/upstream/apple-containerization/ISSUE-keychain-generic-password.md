# Generic Local Keychain Password Store

## Summary

Add a small `ContainerizationOS` primitive for opaque bytes stored as generic
password Keychain items. It is deliberately resource-agnostic: consumers own
their service identifier, account naming, and public resource model.

## Motivation

Some local, user-scoped features need encrypted-at-rest storage without
teaching the VM or an API server about credentials. The Keychain is the native
macOS boundary for this use case, but the existing wrapper only covered
certificate-oriented queries.

## Proposed API

- `saveGenericPassword(service:account:data:)`
- `getGenericPassword(service:account:)`
- `listGenericPasswords(service:)` returning metadata only
- `genericPasswordExists(service:account:)`
- `deleteGenericPassword(service:account:)`

Items use `kSecClassGenericPassword`, are scoped by service and account, and
remain available only after the user has unlocked the device. Listing must not
request secret data.

## Scope

- Keep this a Foundation/Security wrapper with no resource model, CLI, XPC, or
  application-specific naming policy.
- Return binary `Data` unchanged, including empty and non-UTF-8 values.
- Preserve Keychain error information for the caller to map into its own typed
  errors.

## Out Of Scope

- Secret management commands, Compose behavior, and server-side Keychain
  access.
- Cross-user sharing, synchronizable Keychain items, or cloud replication.
- Value-bearing list or inspect APIs.
