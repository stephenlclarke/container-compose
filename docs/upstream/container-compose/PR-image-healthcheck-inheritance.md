# Pull Request

## Summary

- Add a direct image healthcheck metadata API to the Compose image manager.
- Map Dockerfile-inherited image healthchecks to `container run/create --health-*` flags.
- Merge timing-only Compose healthcheck overrides over image defaults.
- Keep explicit `healthcheck.test` and `disable: true` behavior unchanged.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose inherits image-level Dockerfile `HEALTHCHECK` metadata when a service does not declare a replacement probe. It also allows services to tune image probes by setting timing fields such as `interval`, `timeout`, `start_period`, `start_interval`, or `retries` without repeating the probe command.

The current `stephenlclarke/container` `develop` fork integration lane carries `feat(api): expose image healthcheck metadata` (`831a013`), documented by `ISSUE-image-healthcheck-metadata.md` / `PR-image-healthcheck-metadata.md`. That runtime slice references [apple/container#440](https://github.com/apple/container/issues/440), [apple/container#1502](https://github.com/apple/container/issues/1502), and [apple/container#1504](https://github.com/apple/container/pull/1504), and exposes Docker image config `Healthcheck` metadata through `ImageResource.Variant.healthCheck`.

With that fork primitive available, this plugin can implement Compose inheritance and override semantics without adding Compose-specific code to `apple/container`.

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
- Plain image inheritance is best-effort when metadata lookup fails and the service did not explicitly tune healthcheck fields; timing-only overrides still fail clearly because a command is required.

## Docker Compose Compatibility Notes

- Supported now on the fork-backed branch: Dockerfile `HEALTHCHECK` command inheritance, `interval`, `timeout`, `start_period`, `start_interval`, and `retries` defaults, plus Compose timing overrides.
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

Results: passed locally on 2026-06-22. The focused run executed 7 tests. The broader orchestrator run executed 459 tests. The full Makefile Swift suite executed 537 tests. Final coverage was Swift 89.73% and Go 93.37%.

## container-compose Checks

- [x] I updated `STATUS.md` for runtime primitive changes, or no update is needed.
- [x] I updated `PLAN.md` for newly discovered gaps, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I signed my commits with a GitHub-supported signature method.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
