# Persistent Non-Secret Config Store

## Summary

Add a small generic `container config` resource API for immutable, non-secret
bytes. It lets higher-level tools retrieve an externally managed Compose config
without reaching into a private on-disk layout.

## Motivation

The Compose specification defines `configs.<name>.external` as a resource that
already exists on the platform. `container-compose` can materialize local config
sources into read-only bind mounts, but it cannot resolve an external config
without a user-addressable backend primitive.

External configuration is not an OCI runtime feature and needs no VM, image,
network, or mount-layer change. A narrow API keeps this capability at the
`container` boundary while Compose retains Docker-compatible file placement and
service orchestration.

## Proposed API

- `ClientConfig.create(name:contents:labels:)`
- `ClientConfig.inspect(_:)` and `ClientConfig.list()` return metadata only.
- `ClientConfig.read(name:)` returns immutable bytes through an explicit call.
- `ClientConfig.delete(name:)` removes a config.
- `container config create|list|inspect|read|delete` exposes the same resource
  for administrators.

Metadata contains name, creation date, labels, and byte count. Content is
stored separately and never appears in list or inspect output.

## Semantics And Security Boundary

- Config names use existing resource-name safety rules; paths cannot traverse
  or contain nested components.
- Content is immutable: a duplicate create fails; replacement is delete then
  create.
- Empty content is valid.
- This is not a secret store: it makes no encrypted-at-rest, read-authorization,
  or masking claim.
- Compose remains responsible for staging a private read-only bind-mount source
  at the requested service target.

## Deliberately Out Of Scope

- Docker Swarm config API emulation or remote distribution.
- Secret storage, which requires an independent key-management, permission, and
  redaction design.
- Live in-place updates of a config already consumed by a service.
- New `containerization` APIs.

## Upstream Context

On 2026-07-16, targeted searches found no existing `apple/container`
config-store or external-config implementation.
[apple/container#1736](https://github.com/apple/container/pull/1736) is an
unrelated Python Compose example and makes no Swift/runtime changes.

## Validation

```sh
swift test --filter 'ConfigValidationTests|ConfigsServiceTests|StoragePathTests'
swift build --target ContainerCommands --target container-apiserver
```
