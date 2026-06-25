<!-- markdownlint-disable MD013 -->

# feat(api): expose image healthcheck metadata

## Template

This PR draft follows `.github/pull_request_template.md`.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker image config can contain Dockerfile `HEALTHCHECK` metadata under `config.Healthcheck`. `apple/container` already reads OCI config content while building `ImageResource` values for `container image inspect`, but the typed resource model drops Docker healthcheck metadata because `ContainerizationOCI.ImageConfig` does not currently expose that extension field.

This slice exposes the metadata at the `ImageResource.Variant` boundary so API consumers can make correct decisions without reparsing raw OCI blobs themselves. `container-compose` needs this to support Docker Compose healthchecks that tune an image-provided command with timing-only fields.

Related work:

- [apple/container#440](https://github.com/apple/container/issues/440): native builder parser support for Dockerfile `HEALTHCHECK`.
- [apple/container#1502](https://github.com/apple/container/issues/1502): health status request.
- [apple/container#1504](https://github.com/apple/container/pull/1504): health status data shape.
- Local fork handoffs: `ISSUE-healthcheck-configuration.md` and `ISSUE-healthcheck-observer.md`. Docker/Compose healthcheck parsing and typed create projection now live in `container-compose`.

## What Changed

- Adds `ImageResource.HealthCheck`, a typed Codable representation of Docker image config `Healthcheck`.
- Adds optional `healthCheck` metadata to `ImageResource.Variant`.
- Populates `healthCheck` while building image resources from OCI config content.
- Adds an internal `ClientImage` content-store injection seam for deterministic client tests.
- Keeps healthcheck projection best-effort so malformed Docker extension metadata does not hide an otherwise valid OCI image variant.
- Adds focused unit tests for the public resource Codable shape and the client projection from index / manifest / config fixture content.

## Commit Tracking

- Container code commit: `831a013` in `stephenlclarke/container` (`feat(api): expose image healthcheck metadata`).
- Lower runtime code commit: not required.
- Compose mapping code commit: `3f1f442` in `stephenlclarke/container-compose` (`feat(health): inherit image healthchecks`), not part of this Apple PR.

## Non-Goals

- This does not implement Dockerfile `HEALTHCHECK` parsing in the native builder. That remains tracked by [apple/container#440](https://github.com/apple/container/issues/440).
- This does not add Compose-specific orchestration to `apple/container`.
- This does not create or run health probes by itself; it only exposes image metadata that existing healthcheck configuration/runtime slices can consume.
- This does not move Docker healthcheck metadata into `apple/containerization`; maintainers may choose to follow up there later if the OCI model should own this field directly.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Local verification:

```bash
swift test --filter 'ImageResourceTests|ClientImageImageResourceTests'
```

Result:

- `ImageResourceTests.roundTripsVariantHealthCheckMetadata`: passed.
- `ClientImageImageResourceTests.imageResourceIncludesImageConfigHealthCheck`: passed.

## Compatibility Notes

The JSON field names inside `ImageResource.HealthCheck` match Docker image config keys (`Test`, `Interval`, `Timeout`, `StartPeriod`, `StartInterval`, and `Retries`). Durations are stored as nanoseconds, matching Docker image config encoding.

Existing image resources without healthcheck metadata continue to encode with `healthCheck: null` or omit the value depending on the consumer's encoder settings. Existing callers that use `ImageResource.Variant` initializer do not need to change because the new parameter defaults to `nil`.

## Remaining Risks

- Maintainers may prefer to add `Healthcheck` directly to `ContainerizationOCI.ImageConfig` in `apple/containerization`; this PR keeps the change local to `apple/container` to avoid introducing a dependency-version bump into this slice.
- `container-compose` still needs a follow-up change to consume the new `ImageResource.Variant.healthCheck` field when a Compose service declares timing-only healthcheck overrides.
