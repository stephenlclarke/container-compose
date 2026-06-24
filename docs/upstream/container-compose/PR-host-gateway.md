# Pull Request

## Summary

- Map Compose `extra_hosts` `host-gateway` entries to the plugin-owned host-entry projection.
- Reuse the runtime `ContainerConfiguration.HostEntry.hostGatewayAddress` sentinel.
- Document the fork-backed runtime dependency and remaining link/domain gaps.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose commonly uses `extra_hosts: ["host.docker.internal:host-gateway"]` so local-development containers can connect to services running on the host. The plugin previously rejected that value because released upstream `apple/container` did not resolve Docker's `host-gateway` magic address.

The local container fork now has a runtime host-gateway primitive that resolves against the first runtime network gateway. This plugin change keeps Compose string parsing in `container-compose` and projects the value to that generic runtime primitive. The current live execution path still renders `--add-host host:host-gateway` through the command-vector bridge while typed service creation is being wired.

References:

- Compose service `extra_hosts`: <https://docs.docker.com/reference/compose-file/services/#extra_hosts>
- Docker `container run --add-host` and `host-gateway`: <https://docs.docker.com/reference/cli/docker/container/run/#add-entries-to-container-hosts-file---add-host>
- Runtime handoff files: `docs/upstream/apple-container/ISSUE-host-gateway.md` and `docs/upstream/apple-container/PR-host-gateway.md`

## Commit Tracking

- Compose code commit: `04d144e` (`feat(network): map compose host gateway`)
- Container code commit: `ebbd611` in `stephenlclarke/container` (`feat(network): resolve host gateway entries`)
- Lower runtime code commit: not required

## Implementation Details

- Replaced the `host-gateway` unsupported error in `runtimeExtraHostArgument(_:service:)` with a pass-through mapping.
- Reused `ContainerConfiguration.HostEntry.hostGatewayAddress` so the plugin and runtime agree on the sentinel.
- Added orchestration coverage proving `up` projects `host.docker.internal:host-gateway` and currently emits `--add-host host.docker.internal:host-gateway` through the command-vector bridge.
- Removed `host-gateway` from generic unsupported-project fixtures.
- Updated `COMPATIBILITY.md`, `PLAN.md`, and `STATUS.md`.

## Docker Compose Compatibility Notes

- Supported now on the fork-backed integration branch: service `extra_hosts` entries using `host-gateway`.
- Remaining gap: released upstream `apple/container` still needs accepted static host entries plus host-gateway resolution before non-fork branches can use this.
- Remaining gap: service `domainname` and legacy `links` / `external_links` are separate host identity surfaces.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter 'ComposeOrchestratorTests/upMapsHostGatewayExtraHostsToRuntimeHostEntries|ComposeOrchestratorTests/upMapsExtraHostsToRuntimeHostEntries'
```

Additional local checks:

```sh
make check
make coverage-check
git diff --check
```

## container-compose Checks

- [x] I updated `COMPATIBILITY.md` for runtime primitive changes, or no update is needed.
- [x] I updated `PLAN.md` for newly discovered gaps, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I signed my commits with a GitHub-supported signature method.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
