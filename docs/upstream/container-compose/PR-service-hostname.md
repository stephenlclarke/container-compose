# Pull Request

## Summary

- Map Compose service `hostname` to the plugin-owned runtime hostname projection.
- Validate hostnames with RFC1123 label rules before side effects.
- Keep Compose `domainname` as an explicit upstream/runtime gap.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose supports service-level `hostname` for setting the hostname visible inside created service containers. The plugin previously rejected this field because released upstream `apple/container` did not expose an explicit hostname primitive.

The local container fork now adds `ContainerConfiguration.hostname`. This plugin change keeps Compose-specific validation in `container-compose` and projects the value to the runtime. The current live execution path still passes `-h, --hostname` through the command-vector bridge while typed service creation is being wired.

References:

- Compose service `hostname`: <https://docs.docker.com/reference/compose-file/services/#hostname>
- Docker `container run --hostname`: <https://docs.docker.com/reference/cli/docker/container/run/>
- Runtime handoff files: `docs/upstream/apple-container/ISSUE-hostname.md` and `docs/upstream/apple-container/PR-hostname.md`

## Commit Tracking

- Compose code commit: `78398e2` (`feat(network): map compose hostnames`)
- Container code commit: `819eeda` in `stephenlclarke/container` (`feat(api): add container hostname option`)
- Lower runtime code commit: not required

## Implementation Details

- Replaced the blanket `hostname` rejection with `runtimeHostnameArgument(service:)`.
- Added RFC1123 hostname validation in the shared service validation path.
- Built a deterministic hostname projection for `up`, `create`, and one-off `run`.
- Appended `--hostname` in the shared command-vector bridge while typed service creation is being wired.
- Left `domainname` rejected with a precise upstream/runtime gap message.
- Updated `STATUS.md` and relevant project docs.

## Docker Compose Compatibility Notes

- Supported now on the fork-backed integration branch: service `hostname` for service containers and one-off `run` containers, currently through the command-vector bridge.
- Remaining gap: service `domainname` needs a lower runtime and `apple/container` API surface.
- Remaining gap: Docker `host-gateway` and legacy `links` / `external_links` are separate networking identity surfaces.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter 'ComposeOrchestratorTests/createCreatesResourcesAndServiceContainersWithoutStartingThem|ComposeOrchestratorTests/upMapsHostnamesToRuntimeArguments|ComposeOrchestratorTests/upRejectsInvalidHostnamesBeforeCreatingResources|ComposeOrchestratorTests/runSupportsOneOffContainersAndOptionFlags|ComposeOrchestratorTests/runMapsHostnamesToRuntimeArguments|ComposeOrchestratorTests/runRejectsUnsupportedDomainNamesBeforeCreatingResources'
```

Additional local checks:

```sh
make check
make coverage-check
git diff --check
```

## container-compose Checks

- [x] I updated `STATUS.md` for runtime primitive changes, or no update is needed.
- [x] I updated `STATUS.md` or relevant upstream docs for newly discovered gaps, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I signed my commits with a GitHub-supported signature method.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
