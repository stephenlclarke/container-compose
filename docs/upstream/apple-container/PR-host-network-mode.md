# Pull Request

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

This change exposes a Docker-compatible `--network host` mode through `container run` and `container create` for the Apple container runtime shape.

Docker treats `host` as a reserved network mode, not as a network resource. The Apple runtime does not provide Docker Desktop's macOS host-network behavior, so this implementation keeps the scope narrow and Apple-shaped: it records the requested runtime host-network mode, uses the built-in host-facing attachment, and disables bridge-style socket forwarders for that container.

References:

- Docker run network settings: <https://docs.docker.com/reference/cli/docker/container/run/#network-settings>
- Docker Compose service `network_mode`: <https://docs.docker.com/reference/compose-file/services/#network_mode>
- Apple container host network request: <https://github.com/apple/container/issues/55>

## Commit Tracking

- Container code commit: `110f340456d2a25cb0256094bd671c6b91c949e4` in `stephenlclarke/container` (`feat(runtime): add host network mode`).
- Compose integration code is tracked in `docs/upstream/container-compose/PR-host-namespace-modes.md`.

## Implementation Details

- Added `NetworkClient.hostNetworkName` as a reserved runtime network mode name.
- Added `ContainerConfiguration.hostNetwork`, including a backward-compatible decode default of `false`.
- Added parser validation for `--network host`, rejecting attachment properties such as `host,alias=api`.
- Added network-selection validation so `host` cannot be mixed with `none` or ordinary network attachments.
- Reused the built-in network attachment for runtime startup while persisting `hostNetwork`.
- Rejected user-created networks named `host` or `none`.
- Skipped socket-forwarder startup when `hostNetwork` is enabled.
- Updated run/create command reference text for `--network none/host`.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter ParserTest/testManagementFlagsAcceptsNetworkHost
swift test --filter ParserTest/testHostNetworkParserAcceptsHost
swift test --filter ParserTest/testHostNetworkParserRejectsAttachmentProperties
swift test --filter UtilityTests/networkSelection
swift test --filter NetworksServiceTests
swift test --filter ContainerRunCreateCommandTests/runParsesNetworkHostFlag
swift test --filter ContainerRunCreateCommandTests/createParsesNetworkHostFlag
swift test --filter ContainerConfigurationHostNetworkTests
swift test --filter RuntimeServiceHostsTests/hostNetworkSuppressesSocketForwarders
swift test --filter RuntimeServiceHostsTests/attachedNetworkingStartsSocketForwardersWhenNeeded
swift test --filter ApplicationHealthTests/rootHelpProvenanceShowsCustomBuild
swift test --filter ContainerAPIClientTests --filter ContainerResourceTests --filter ContainerCommandsTests --filter ContainerRuntimeLinuxServerTests --filter ContainerAPIServiceTests
git diff --check
```

## Dependency Notes

No `containerization` network namespace change was required for this slice. The existing Linux runtime spec does not add an OCI network namespace in the same way the PID namespace code did; this change lives at the container CLI/API/runtime orchestration layer.

## Remaining Risks

- This does not implement Docker-compatible service/container network namespace joining.
- Stock Apple `container` still needs an accepted upstream equivalent before `container-compose` can use this behavior without the stephenlclarke fork runtime lane.
