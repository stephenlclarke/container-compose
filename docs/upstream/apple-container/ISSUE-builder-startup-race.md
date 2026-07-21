# Bug: concurrent build clients can race to create the shared BuildKit container

## Summary

Each `container build` client initializes the default builder named `buildkit`.
The prior inspect-then-create sequence was process-local only. Concurrent
clients, including Docker Compose v2 building multiple services, could both
observe no builder and then one received `container already exists: buildkit`.

## Reproduction on macOS

1. Start a matched Container runtime with no existing `buildkit` container.
2. Invoke two or more `container build` commands concurrently, or run a
   Compose project with multiple build services.
3. Before the correction, one build creates `buildkit`; competing clients can
   fail during their own create request instead of using that singleton.

This is a generic macOS CLI/runtime lifecycle race. It is not caused by a
Compose parser feature and must not be hidden by serializing Compose builds.

## Expected behavior

For one named builder, only inspect, compatibility checking, creation, and
bootstrap are serialized across CLI processes. Once running, all compatible
clients may dial BuildKit and execute builds concurrently.

## Ownership and boundary

`Application.BuilderStart` owns the existing builder lifecycle. The
correction adds a small macOS advisory lock scoped by application root and
builder ID at that boundary. Compose continues to invoke ordinary concurrent
build requests and contains no retry, mutex, or runtime-specific workaround.

## Commit tracking

- `7be83a26c220722f4186aa9fe7c14ff339141822` —
  `fix(build): serialize builder startup`.

## Validation expectations

- Unit coverage validates lock-file acquisition, release, and nonblocking
  reuse.
- The complete Container coverage suite validates the source distribution.
- The source-matched Compose image-volume fixture builds multiple services in
  parallel, then verifies volume-subpath teardown with Docker Compose v2.
