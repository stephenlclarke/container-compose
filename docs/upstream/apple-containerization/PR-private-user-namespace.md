# Pull request: add private guest user namespaces

## Summary

Adds an opt-in generic OCI user-namespace primitive to the macOS Linux guest.
The container receives an identity mapping for the guest UID/GID range; it does
not join, expose, or emulate a macOS user namespace.

## Constructible commit

- `943f95fb7a338a04a4831d98a845a5a90d07f864`
  `feat(runtime): add private guest user namespaces`

## Implementation

- `Sources/Containerization/LinuxContainer.swift` adds the default-false
  `privateUserNamespace` setting and emits an OCI `user` namespace with
  UID/GID map `0 0 4294967295`.
- `vminitd/Sources/vmexec/RunCommand.swift` keeps rootfs setup in the initial
  guest user namespace, then coordinates a parent-process mapping handshake.
- `vminitd/Sources/vmexec/ExecCommand.swift` joins the target user and IPC
  namespaces as well as the existing process namespaces.
- `Sources/Integration/ContainerTests.swift` and
  `Sources/ContainerizationTests/LinuxContainerTests.swift` cover projection
  and a guest-visible identity map.

## Apple-shaped boundary

This is a small, defaulted OCI/guest-runtime primitive. It has no Docker or
Compose types, no CLI surface, no Windows implementation, no host-Linux path,
no custom mapping policy, and no macOS host namespace access.

## Verification

```sh
swift test --filter LinuxContainerTests.runtimeSpecCanUsePrivateGuestUserNamespace
./bin/containerization-integration --kernel ./bin/vmlinux-arm64 \
  --filter 'container private user namespace' --max-concurrency 1
make -C vminitd
```

All passed locally. The integration read `0 0 4294967295` from both maps.

## Release note

This guest-side protocol requires a `vminitd` image built from the same runtime
revision. A release containing this commit must publish and select its matching
init image; an older guest image cannot safely create this namespace.

## Review checklist

- [ ] Replay the listed commit without downstream consumers.
- [ ] Verify the default spec is unchanged and private adds only the user
  namespace and identity mappings.
- [ ] Keep custom maps, host namespaces, Docker/Compose concerns, Windows,
  and cross-container sharing out of scope.
