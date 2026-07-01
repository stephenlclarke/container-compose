# Pull Request

## Summary

- Map Compose service `extra_hosts` to the plugin-owned host-entry projection.
- Accept compose-go normalized `HOST=IP`, `HOST:IP`, and bracketed IPv6 source forms.
- Validate static IP-literal entries before side effects.
- Keep `domainname`, `links`, and `external_links` as explicit remaining runtime gaps.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose `extra_hosts` is a common local-development feature for pinning service names to specific addresses inside a container. The plugin previously rejected all `extra_hosts` entries because released upstream `apple/container` did not expose a creation-time host-entry primitive.

The local container fork now carries a small host-entry slice that combines the API direction from [apple/container#1340](https://github.com/apple/container/pull/1340) and the CLI direction from [apple/container#1563](https://github.com/apple/container/pull/1563). This plugin owns Compose syntax handling and projects canonical host entries to the runtime. The current live execution path still uses the `container run/create --add-host` command-vector bridge while typed service creation is being wired.

This change keeps Compose syntax handling in `container-compose`, validates static entries before creating resources, and passes canonical runtime host entries to the fork. No Compose-specific service aliasing is added to `apple/container`.

## Commit Tracking

- Compose code commit: `7855a19` (`feat(network): map compose extra hosts`)
- Container code commit: `bf1d6b4` in `stephenlclarke/container` (`feat(api): add explicit host entries`)
- Lower runtime code commit: not required

## Implementation Details

- Replaced the blanket `extra_hosts` rejection with `runtimeExtraHostArguments(service:)`.
- Canonicalized `HOST=IP` and `HOST:IP` to `HOST:IP`.
- Removed IPv6 brackets accepted by Compose before passing arguments to the runtime.
- Validated IP literals with `IPAddress`.
- Added a precise unsupported error for Docker's `host-gateway` magic value before the runtime resolver existed.
- Built a deterministic host-entry projection shared by service containers and one-off `run` containers.
- Appended `--add-host` arguments in the command-vector bridge while typed service creation is being wired.
- Extended Swift and Go normalizer tests to cover compose-go canonical `extra_hosts` output.
- Updated `STATUS.md` and relevant project docs.

## Docker Compose Compatibility Notes

- Supported now on the fork-backed integration branch: static `extra_hosts` entries with IPv4, IPv6, and bracketed IPv6 source forms, currently through the command-vector bridge.
- Supported now: service `up`, `create`, and one-off `run` host entries.
- Separate slice: Docker `host-gateway` is handled by `docs/upstream/apple-container/ISSUE-host-gateway.md` / `docs/upstream/apple-container/PR-host-gateway.md`.
- Remaining gap: custom `domainname` and legacy `links` / `external_links` are still separate runtime or compatibility surfaces.
- Separate slice: service `hostname` is handled by `docs/upstream/container-compose/ISSUE-service-hostname.md` / `docs/upstream/container-compose/PR-service-hostname.md`.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
cd Tools/compose-normalizer && go test ./...
swift test --filter 'ComposeNormalizerTests/normalizesComposeFileThroughComposeGo|ComposeOrchestratorTests/createCreatesResourcesAndServiceContainersWithoutStartingThem|ComposeOrchestratorTests/upMapsExtraHostsToRuntimeHostEntries|ComposeOrchestratorTests/upRejectsHostGatewayExtraHostsBeforeCreatingResources|ComposeOrchestratorTests/runSupportsOneOffContainersAndOptionFlags|ComposeOrchestratorTests/invalidAndUnsupportedProjectsFailClearly'
```

Additional local checks:

```sh
make check
make coverage-check
```

Result: `make check` passed; `make coverage-check` passed with Swift coverage at 89.69% and Go coverage at 93.37%.

## container-compose Checks

- [x] I updated `STATUS.md` for runtime primitive changes, or no update is needed.
- [x] I updated `STATUS.md` or relevant upstream docs for newly discovered gaps, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I signed my commits with a GitHub-supported signature method.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
