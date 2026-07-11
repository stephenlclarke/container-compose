# Pull Request

## Summary

- Add a direct image healthcheck metadata API to the Compose image manager.
- Map Dockerfile-inherited image healthchecks to the plugin-owned healthcheck projection.
- Merge timing-only Compose healthcheck overrides over image defaults.
- Keep explicit `healthcheck.test` and `disable: true` behavior unchanged.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose inherits image-level Dockerfile `HEALTHCHECK` metadata when a service does not declare a replacement probe. It also allows services to tune image probes by setting timing fields such as `interval`, `timeout`, `start_period`, `start_interval`, or `retries` without repeating the probe command.

The current `stephenlclarke/container` fork exposes image healthcheck metadata through `ImageResource.Variant.healthCheck` in `feat(api): expose image healthcheck metadata` (`831a013`). The matching handoffs are `docs/upstream/apple-container/ISSUE-image-healthcheck-metadata.md` and `docs/upstream/apple-container/PR-image-healthcheck-metadata.md`, with upstream context in [apple/container#440](https://github.com/apple/container/issues/440), [apple/container#1502](https://github.com/apple/container/issues/1502), and [apple/container#1504](https://github.com/apple/container/pull/1504).

With that fork primitive available, this plugin can implement Compose inheritance and override semantics without adding Compose-specific code to `apple/container`.

## Commit Tracking

- Compose code commit: `3f1f442` (`feat(health): inherit image healthchecks`)
- Container code commit: `831a013` in `stephenlclarke/container` (`feat(api): expose image healthcheck metadata`)
- Related healthcheck API commits: `d995767`, `f41c817`, `fa97154`, and `a4fb99e` in `stephenlclarke/container`
- Lower runtime code commit: not required

## Implementation Details

- Added `ComposeImageHealthCheck` as the plugin-side model for image healthcheck metadata.
- Extended `ContainerImageAPIClienting` and `ContainerImageManaging` with `imageHealthCheck(reference:platform:)`.
- Implemented `ContainerImageLiveAPIClient.imageHealthCheck(reference:platform:)` by resolving an image to `ImageResource`, selecting the requested or default platform variant, and projecting `ImageResource.Variant.healthCheck`.
- Made service run/create argument construction async so it can resolve image metadata while building healthcheck flags.
- Added a per-command `ComposeImageHealthCheckCache` actor so preflight validation and replica creation do not repeatedly inspect the same image/platform pair.
- Added preflight validation after image preparation and before resource creation for image-backed `up`, `create`, and one-off `run`.
- Kept Docker-compatible precedence:
  - `healthcheck.disable: true` maps to `--no-healthcheck`.
  - Explicit `healthcheck.test` maps exactly as before.
  - Missing service `healthcheck.test` inherits the image command when metadata is available.
  - Timing-only overrides replace corresponding image defaults.
- The current live execution path still renders `--health-*` flags through the command-vector bridge while typed service creation is being wired; typed execution should pass `ContainerConfiguration.healthCheck` directly.
- Plain image inheritance is best-effort when metadata lookup fails and the service did not explicitly tune healthcheck fields; timing-only overrides still fail clearly because a command is required.

## Docker Compose Compatibility Notes

- Supported with the current fork-backed runtime: Dockerfile `HEALTHCHECK` command inheritance, `interval`, `timeout`, `start_period`, `start_interval`, and `retries` defaults, plus Compose timing overrides.
- Remaining released-upstream gap: equivalent image config parsing and `ImageResource` healthcheck metadata must be accepted in `apple/container`.
- Compose-specific merge semantics, disable behavior, and early validation remain in this plugin.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter 'ComposeOrchestratorTests/upMapsInheritedImageHealthchecksToContainerFlags|ComposeOrchestratorTests/upMergesTimingOnlyHealthcheckOverridesWithImageMetadata|ComposeOrchestratorTests/upRejectsTimingOnlyHealthchecksWithoutImageMetadataBeforeCreatingResources|ComposeOrchestratorTests/runRejectsDependencyTimingOnlyHealthchecksBeforeCreatingResources|ComposeOrchestratorTests/imageManagerReturnsImageHealthchecksThroughDirectAPI|ComposeOrchestratorTests/imageAPIClientForwardsConfiguredOperations|ComposeOrchestratorTests/imageAPIClientWrapsInjectedLowerLevelClient'
swift test --filter ComposeOrchestratorTests
make check
make swift-test
make coverage-check
make cli-smoke-built
```

## container-compose Checks

- [x] I updated `STATUS.md` for runtime primitive changes, or no update is needed.
- [x] I updated `STATUS.md` or relevant upstream docs for newly discovered gaps, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I signed my commits with a GitHub-supported signature method.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
