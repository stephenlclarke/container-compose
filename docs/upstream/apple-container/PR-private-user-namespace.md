# Pull request: add private guest user namespace mode

## Summary

Exposes the generic private guest user-namespace primitive through Container's
configuration, CLI parser, and runtime projection.

## Constructible commits

- Containerization prerequisite:
  `943f95fb7a338a04a4831d98a845a5a90d07f864`
  `feat(runtime): add private guest user namespaces`
- Container implementation:
  `1081cb565b41918fa8f7c26c7c9559b31014a211`
  `feat(runtime): add private guest user namespace mode`

## Implementation

- `Sources/ContainerResource/Container/ContainerConfiguration.swift` persists
  default-false `privateUserNamespace` and preserves old data.
- `Sources/Services/ContainerAPIService/Client/{Flags,Parser,Utility}.swift`
  add `--userns <host|private>`, exact validation, and configuration mapping.
- `Sources/Services/RuntimeLinux/Server/RuntimeService.swift` forwards the
  setting to `LinuxContainer.Configuration`.
- Focused configuration/parser tests and
  `Tests/IntegrationTests/Run/TestCLIRunCommand.swift` cover persistence,
  validation, help, startup, and `exec` namespace entry.

## Apple-shaped boundary

This is a minimal generic Container option over an OCI primitive. It contains
no Compose file parsing, Docker types, Windows behavior, host-Linux behavior,
macOS host namespace access, or custom mapping policy.

## Verification

```sh
swift test --filter ContainerConfigurationUserNamespaceTests
swift test --filter ParserTest
CONTAINER_CLI_PATH=/absolute/path/to/container/bin/container \
  swift test --filter TestCLIRunCommand.testRunCommandPrivateUserNamespace
container run --help
```

The focused unit tests and private-container-plus-`exec` integration passed
locally. Help reports `--userns <userns> Set the guest user namespace mode
(host or private)`.

## Compatibility and release note

Omission and `host` retain the sandbox VM user namespace. `private` selects an
identity-mapped namespace in that guest; neither reaches a macOS host
namespace. The option requires a matching Containerization guest `vminitd`
image containing the map handshake.

## Review checklist

- [ ] Replay the prerequisite before the Container commit.
- [ ] Verify omission/`host` do not request an OCI user namespace.
- [ ] Verify `private` does, including a later `exec`.
- [ ] Keep Docker/Compose types, custom maps, Windows, and host namespaces out
  of scope.
