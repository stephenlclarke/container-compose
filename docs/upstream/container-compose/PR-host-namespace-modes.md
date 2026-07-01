# Support Host Namespace Modes

## Summary

This change adds the host-only namespace subset for Compose services:

- `network_mode: host`
- `pid: host`

It keeps service/container namespace-sharing values blocked as the next namespace-mode gap because those require Docker-compatible runtime namespace joining.

## Rationale

Docker Compose accepts both host and sharing namespace modes. The Stephen fork-backed runtime stack now has the host PID primitive:

- `containerization` commit `93b6e729e95a3e81cf94f662b4e5716fa9d3068d` adds `LinuxContainer.Configuration.hostPIDNamespace`.
- `container` commit `110f340456d2a25cb0256094bd671c6b91c949e4` adds `ContainerConfiguration.hostPIDNamespace`, `ContainerConfiguration.hostNetwork`, `container run/create --pid host`, and `container run/create --network host`.

`container-compose` can therefore map the host subset locally while keeping Compose-specific policy in this repo.

## Implementation Details

- Added `isSupportedNetworkMode(_:)` so `network_mode: none` and `network_mode: host` pass validation.
- Rendered `network_mode: host` as `container run/create --network host` while keeping Compose project network attachment out of the command.
- Moved `pid` out of the generic unsupported string-field table.
- Added `runtimePIDArgument(service:)`, accepting only `host` and rendering `--pid host`.
- Added focused unit coverage for `up` and one-off `run` positive/negative paths.
- Added `Tools/parity/check-compose-host-namespaces.sh` and `make docker-compose-host-namespaces-parity`.
- Updated README, BUILD, STATUS, PLAN, parity docs, and upstream handoff drafts.
- Refreshed `Package.resolved` and `APPLE_CONTAINER_REF` to the matching Stephen fork commits.

## Docker Compose Parity

Local Docker Compose 5.2.0 probe results:

- `network_mode: host` normalizes to `network_mode: "host"` and Docker inspect reports `HostConfig.NetworkMode="host"` with empty `PidMode`; container-compose dry-run verifies `--network host` is emitted and the Compose project network is not attached.
- `pid: host` normalizes to `pid: "host"` while retaining the default service network; Docker inspect reports `HostConfig.PidMode="host"` and `HostConfig.NetworkMode="<project>_default"`.
- Docker Compose accepts service/container namespace sharing forms, but `container-compose` intentionally still rejects them until a runtime namespace-join primitive exists.

The Docker Compose e2e fixture checkout was checked before adding the local parity fixture. It contains service-network fixtures for `network_mode: service:db` and `network_mode: bridge`, but no reusable `network_mode: host` / `pid: host` fixture, so this slice uses a minimal generated compose.yml in the parity script.

## Verification

Focused local validation:

```sh
swift test --filter ComposeOrchestratorTests/upMapsNetworkModeHostToRuntimeHostNetworking
swift test --filter ComposeOrchestratorTests/createMapsNetworkModeHostToRuntimeHostNetworking
swift test --filter ComposeOrchestratorTests/runMapsNetworkModeHostToRuntimeHostNetworking
swift test --filter ComposeOrchestratorTests/upMapsPIDHostToContainerPIDArgument
swift test --filter ComposeOrchestratorTests/createMapsPIDHostToContainerPIDArgument
swift test --filter ComposeOrchestratorTests/runMapsPIDHostToContainerPIDArgument
swift test --filter ComposeOrchestratorTests/upRejectsUnsupportedPIDModeBeforeCreatingResources
swift test --filter ComposeOrchestratorTests/runRejectsUnsupportedPIDModeBeforeCreatingResources
swift test --filter ComposeOrchestratorTests/upRejectsUnsupportedNamespaceAndCgroupFieldsBeforeCreatingResources
bash -n Tools/parity/check-compose-host-namespaces.sh
make docker-compose-host-namespaces-parity
git diff --check
```

Fork-side validation:

```sh
cd ../containerization
swift test --filter LinuxContainerTests/runtimeSpecCanUseHostPIDNamespace
git diff --check

cd ../container
swift test --filter ParserTest/testManagementFlagsAcceptsNetworkHost
swift test --filter ParserTest/testHostNetworkParserAcceptsHost
swift test --filter ParserTest/testHostNetworkParserRejectsAttachmentProperties
swift test --filter UtilityTests/networkSelection
swift test --filter NetworksServiceTests
swift test --filter ContainerRunCreateCommandTests/runParsesNetworkHostFlag
swift test --filter ContainerRunCreateCommandTests/createParsesNetworkHostFlag
swift test --filter ContainerConfigurationHostNetworkTests
swift test --filter RuntimeServiceHostsTests/hostNetworkSuppressesSocketForwarders
swift test --filter ContainerRunCreateCommandTests/runParsesPIDHostFlag
swift test --filter ContainerRunCreateCommandTests/createParsesPIDHostFlag
swift test --filter ContainerConfigurationPIDNamespaceTests
swift test --filter ParserTest/testManagementFlagsAcceptsPIDHost
swift test --filter ParserTest/testHostPIDNamespaceParserAcceptsHost
swift test --filter ParserTest/testHostPIDNamespaceParserRejectsUnsupportedValue
git diff --check
```

Before release promotion, run the broader local gate:

```sh
make check
make coverage-check
make cli-smoke-built
npx --yes markdownlint-cli2 README.md BUILD.md STATUS.md docs/parity/compose-cli-surface.md docs/upstream/apple-containerization/ISSUE-host-pid-namespace.md docs/upstream/apple-containerization/PR-host-pid-namespace.md docs/upstream/apple-container/ISSUE-host-pid-namespace.md docs/upstream/apple-container/PR-host-pid-namespace.md docs/upstream/apple-container/ISSUE-host-network-mode.md docs/upstream/apple-container/PR-host-network-mode.md docs/upstream/container-compose/ISSUE-host-namespace-modes.md docs/upstream/container-compose/PR-host-namespace-modes.md
```

## Follow-Ups

- Implement or document the remaining `network_mode` / `pid` service/container namespace-sharing values.
- Complete the requested `devices` slice before returning to network `driver_opts`.
