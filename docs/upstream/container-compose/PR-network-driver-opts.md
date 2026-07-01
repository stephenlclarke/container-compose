# Pull Request

## Summary

- Preserve Compose top-level network `driver_opts` through the Go normalizer and Swift project model.
- Pass those options to Apple network creation through dry-run `container network create --option key=value` rendering and direct `NetworkConfiguration.options`.
- Add focused Swift and Go coverage plus a local-only Docker Compose V2 parity target.
- Document the remaining generic service endpoint `driver_opts` blocker.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose exposes two network driver option surfaces. Top-level `networks.<name>.driver_opts` are network creation options, and Apple already has a compatible plugin-option bag on network creation. `container-compose` normalized those values in Go but dropped them before Swift orchestration, so project networks were created without the requested options.

Service endpoint `driver_opts` are a different surface. Apple attachment options currently expose hostname, aliases, MAC address, and MTU. The existing MTU subset can be mapped to `container --network name,mtu=...`; arbitrary endpoint driver options still need a lower-runtime attachment option surface before they can be implemented correctly.

References:

- Compose networks `driver_opts`: <https://docs.docker.com/reference/compose-file/networks/#driver_opts>
- Compose services network attachment `driver_opts`: <https://docs.docker.com/reference/compose-file/services/#driver_opts>
- Docker bridge driver options: <https://docs.docker.com/engine/network/drivers/bridge/#options>
- Upstream hints reviewed for this slice: [apple/container#282](https://github.com/apple/container/issues/282), [apple/container#1463](https://github.com/apple/container/pull/1463), [apple/container#1151](https://github.com/apple/container/pull/1151), and [apple/container#194](https://github.com/apple/container/discussions/194).

## Commit Tracking

- Compose mapping code is the current `feat(network): support top-level driver options` slice in `stephenlclarke/container-compose`.
- No Apple fork changes are required for the top-level network option path because Apple network creation already has plugin options.

## Implementation Details

- Added `driverOpts` to `normalizedNetwork` in the Go normalizer.
- Added `driverOpts` to the Swift `ComposeNetwork` model.
- Added `driverOpts` to `ComposeNetworkCreateRequest`.
- `ensureNetwork` now emits sorted repeatable `--option key=value` arguments during dry-run and sends the same map through the direct resource manager path.
- `ContainerClientResourceManager` maps the request options into `NetworkConfiguration.options`.
- Updated the unsupported project-network message to list `driver_opts` as a mapped field.
- Added `Tools/parity/check-compose-network-driver-opts.sh` and `make docker-compose-network-driver-opts-parity`.

## Docker Compose Compatibility Notes

Supported:

- `networks.<name>.driver_opts` are preserved in normalized config.
- `compose up` project network creation passes options to the Apple network plugin option map.
- Docker bridge option examples such as `com.docker.network.bridge.host_binding_ipv4` and `com.docker.network.driver.mtu` are covered by local Docker Compose parity validation.

Known remaining network option gap:

- `services.<name>.networks.<network>.driver_opts` only supports Docker-compatible MTU keys today. Other endpoint driver options remain blocked until Apple exposes an arbitrary attachment option map or equivalent Docker-compatible endpoint option primitive.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```bash
swift test --disable-automatic-resolution --filter 'ComposeOrchestratorTests/upCreatesNetworkDriverOptionsThroughDirectAPI|ComposeOrchestratorTests/upDryRunRendersNetworkDriverOptions|ComposeOrchestratorTests/upRejectsUnsupportedProjectNetworkIPAMBeforeSideEffects|ComposeNormalizerTests/normalizesComposeFileThroughComposeGo'
cd Tools/compose-normalizer && go test ./...
bash -n Tools/parity/check-compose-network-driver-opts.sh
shellcheck Tools/parity/check-compose-network-driver-opts.sh
make docker-compose-network-driver-opts-parity
```

## container-compose Checks

- [x] I updated `STATUS.md` for runtime primitive changes, or no update is needed.
- [x] I updated `STATUS.md` or relevant upstream docs for newly discovered gaps, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I signed my commits with a GitHub-supported signature method.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
