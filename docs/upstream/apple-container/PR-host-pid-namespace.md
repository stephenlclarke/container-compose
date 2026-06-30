# Pull Request

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

This change exposes the lower-runtime host PID namespace primitive through `container run` and `container create`.

The Apple-facing shape stays narrow and runtime-native:

- `ContainerConfiguration.hostPIDNamespace` records the requested behavior.
- `--pid host` is parsed at the CLI/API client boundary.
- The Linux runtime service passes the boolean into `LinuxContainer.Configuration.hostPIDNamespace`.

Docker/Compose service namespace joining (`pid: service:NAME`, `pid: container:ID`) is not part of this slice because it requires a separate runtime primitive for joining another container's PID namespace.

References:

- Docker run `--pid`: <https://docs.docker.com/reference/cli/docker/container/run/#pid-settings---pid>
- Docker Compose service `pid`: <https://docs.docker.com/reference/compose-file/services/#pid>
- Lower-runtime handoff draft: [PR-host-pid-namespace.md](../apple-containerization/PR-host-pid-namespace.md)

## Commit Tracking

- Initial PID container code commit: `727ed4e75245f6ac1499fcd4a8330982bf0cbb6d` in `stephenlclarke/container` (`feat(runtime): add host PID namespace option`).
- Host-namespace slice container pin: `110f340456d2a25cb0256094bd671c6b91c949e4`, which added the separate host-network runtime path used by that `container-compose` namespace-mode slice.
- Required `containerization` fork commit: `93b6e729e95a3e81cf94f662b4e5716fa9d3068d` (`feat(runtime): allow host PID namespace specs`).
- Compose integration code is tracked in `docs/upstream/container-compose/PR-host-namespace-modes.md`.

## Implementation Details

- Added `ContainerConfiguration.hostPIDNamespace`, including a backward-compatible decode default of `false`.
- Added `--pid <pid>` to the shared management option group used by `container run` and `container create`.
- Added `Parser.hostPIDNamespace(_:)`, accepting `host` and rejecting other values with an explicit error.
- Passed the parsed value through `Utility.containerConfigFromFlags`.
- Passed `ContainerConfiguration.hostPIDNamespace` into `LinuxContainer.Configuration.hostPIDNamespace` in the Linux runtime service.
- Updated the command reference for `run` and `create`.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift package update containerization
swift test --filter ContainerRunCreateCommandTests/runParsesPIDHostFlag
swift test --filter ContainerRunCreateCommandTests/createParsesPIDHostFlag
swift test --filter ContainerConfigurationPIDNamespaceTests
swift test --filter ParserTest/testManagementFlagsAcceptsPIDHost
swift test --filter ParserTest/testHostPIDNamespaceParserAcceptsHost
swift test --filter ParserTest/testHostPIDNamespaceParserRejectsUnsupportedValue
git diff --check
```

## Dependency Notes

This requires the matching `containerization` revision that exposes `LinuxContainer.Configuration.hostPIDNamespace`. The local fork pin was refreshed from `cada6d31310761c7e7bf9be87a29fe4820ff628d` to `93b6e729e95a3e81cf94f662b4e5716fa9d3068d`.

## Remaining Risks

- Only `--pid host` is supported. Docker-compatible service/container PID namespace sharing remains blocked.
- Upstream may prefer a future generalized namespace-mode type if more namespace modes are added.
