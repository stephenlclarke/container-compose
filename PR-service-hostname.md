# Pull Request

## Summary

- Map Compose service `hostname` to fork-backed `container run/create --hostname`.
- Validate hostnames with RFC1123 label rules before side effects.
- Keep Compose `domainname` as an explicit upstream/runtime gap.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose supports service-level `hostname` for setting the hostname visible inside created service containers. The plugin previously rejected this field because released upstream `apple/container` did not expose an explicit hostname primitive.

The local container fork now adds `ContainerConfiguration.hostname` and `container run/create -h, --hostname`. This plugin change keeps Compose-specific validation in `container-compose` and passes a generic runtime argument to the fork.

References:

- Compose service `hostname`: <https://docs.docker.com/reference/compose-file/services/#hostname>
- Docker `container run --hostname`: <https://docs.docker.com/reference/cli/docker/container/run/>
- Runtime handoff files in the container fork: `ISSUE-hostname.md` and `PR-hostname.md`

## Implementation Details

- Replaced the blanket `hostname` rejection with `runtimeHostnameArgument(service:)`.
- Added RFC1123 hostname validation in the shared service validation path.
- Appended `--hostname` in the shared service create/run argument builder so `up`, `create`, and one-off `run` use the same mapping.
- Left `domainname` rejected with a precise upstream/runtime gap message.
- Updated `COMPATIBILITY.md`, `PLAN.md`, and `STATUS.md`.

## Docker Compose Compatibility Notes

- Supported now on the fork-backed integration branch: service `hostname` for service containers and one-off `run` containers.
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

- [x] I updated `COMPATIBILITY.md` for runtime primitive changes, or no update is needed.
- [x] I updated `PLAN.md` for newly discovered gaps, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I signed my commits with a GitHub-supported signature method.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
