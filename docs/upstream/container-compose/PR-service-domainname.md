# Pull Request

## Summary

- Map Compose service `domainname` to the plugin-owned runtime domain-name projection.
- Validate domain names with the same RFC1123 label rules used for hostname-like Compose fields.
- Keep released upstream support clearly marked as blocked until `apple/container` accepts the matching primitive.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose supports service-level `domainname` for setting the NIS domain name visible inside created service containers. The plugin previously rejected this field because released upstream `apple/container` did not expose an explicit domain-name primitive.

The local container fork now adds `ContainerConfiguration.domainname`. This plugin change keeps Compose-specific validation in `container-compose` and projects the value to the runtime. The current live execution path still passes `--domainname` through the command-vector bridge while typed service creation is being wired.

References:

- Compose service `domainname`: <https://docs.docker.com/reference/compose-file/services/#domainname>
- Docker `container run --domainname`: <https://docs.docker.com/reference/cli/docker/container/run/>
- Runtime handoff files: `docs/upstream/apple-container/ISSUE-domainname.md` and `docs/upstream/apple-container/PR-domainname.md`

## Commit Tracking

- Compose code commit: `bcbfb3f` (`feat(runtime): map compose domain names`)
- Container code commit: `183ac5b` in `stephenlclarke/container` (`feat(runtime): add container domain names`)
- Lower runtime code commit: not required

## Implementation Details

- Replaced the blanket `domainname` rejection with `runtimeDomainnameArgument(service:)`.
- Reused the existing RFC1123 validation helper for hostname-like values.
- Built a deterministic domain-name projection for `up`, `create`, and one-off `run`.
- Appended `--domainname` in the shared command-vector bridge while typed service creation is being wired.
- Updated `STATUS.md` and relevant project docs.

## Docker Compose Compatibility Notes

- Supported with the current fork-backed runtime: service `domainname` for service containers and one-off `run` containers, currently through the command-vector bridge.
- Remaining upstream gap: released `apple/container` needs accepted domain-name support before stock upstream builds can enable this.
- Remaining networking gaps: `external_links`, implicit default-network links, multi-network link projection, and Docker-compatible shared aliases are still separate runtime/DNS surfaces.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter 'ComposeOrchestratorTests/createCreatesResourcesAndServiceContainersWithoutStartingThem|ComposeOrchestratorTests/upMapsDomainNamesToRuntimeArguments|ComposeOrchestratorTests/upRejectsInvalidDomainNamesBeforeCreatingResources|ComposeOrchestratorTests/runMapsDomainNamesToRuntimeArguments|ComposeOrchestratorTests/runRejectsInvalidDomainNamesBeforeCreatingResources'
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
