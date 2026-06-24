<!-- markdownlint-disable MD013 -->

# [Request]: Expose image healthcheck metadata through image resources

## Template

This issue draft follows `.github/ISSUE_TEMPLATE/02-feature.yml`.

## Feature or enhancement request details

Docker image config can contain Dockerfile `HEALTHCHECK` metadata under `config.Healthcheck`. That metadata is already present in pulled or built images that include a health probe, but `apple/container` does not currently surface it through `ImageResource` or `container image inspect`.

This leaves orchestration tools unable to distinguish two important cases:

- an image has an inherited healthcheck command and a Compose file only tunes timing fields such as `healthcheck.interval`, `timeout`, `start_period`, `start_interval`, or `retries`;
- an image has no inherited healthcheck, so timing-only Compose healthcheck fields should be rejected before creating a container.

Requested behavior:

- Preserve Docker image config healthcheck metadata on each `ImageResource.Variant`.
- Populate that metadata from the existing OCI config content that `ClientImage.toImageResource` already reads for each platform variant.
- Keep the metadata generic to image inspection and API consumers; do not add Compose-specific behavior to `apple/container`.
- Keep malformed Docker extension healthcheck metadata from hiding an otherwise valid OCI image variant.

Related work:

- [apple/container#440](https://github.com/apple/container/issues/440): native builder parser support for Dockerfile `HEALTHCHECK`.
- [apple/container#1502](https://github.com/apple/container/issues/1502): health status request.
- [apple/container#1504](https://github.com/apple/container/pull/1504): health status data shape.
- `ISSUE-healthcheck-configuration.md`: local fork handoff for `ContainerHealthCheck`.
- `ISSUE-healthcheck-observer.md`: local fork handoff for runtime probe observation.
- `container-compose` typed creation work: Compose owns Docker/Compose healthcheck parsing and projects it to `ContainerConfiguration.healthCheck`.

Related Docker references:

- [Dockerfile `HEALTHCHECK`](https://docs.docker.com/reference/dockerfile/#healthcheck)
- [Docker image inspect](https://docs.docker.com/reference/cli/docker/image/inspect/)
- [Docker Compose `healthcheck`](https://docs.docker.com/reference/compose-file/services/#healthcheck)

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
