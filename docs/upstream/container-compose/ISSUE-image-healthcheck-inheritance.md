# Compose compatibility gap: Dockerfile-inherited healthchecks

## Compose Surface

Compose services inherit Dockerfile `HEALTHCHECK` metadata from their image unless the service overrides or disables the healthcheck:

```yaml
services:
  api:
    image: example/api
```

Compose services can also tune image-provided probes without restating the command:

```yaml
services:
  api:
    image: example/api
    healthcheck:
      interval: 5s
      retries: 2
```

## Docker Compose v2 Behavior

Docker Compose v2 creates containers with the image healthcheck by default. Service-level `healthcheck.test` replaces the image probe, `healthcheck.disable: true` disables it, and timing fields such as `interval`, `timeout`, `start_period`, `start_interval`, and `retries` can override image defaults.

Reference surfaces:

- Dockerfile reference: [HEALTHCHECK](https://docs.docker.com/reference/dockerfile/#healthcheck)
- Compose services reference: [healthcheck](https://docs.docker.com/reference/compose-file/services/#healthcheck)

## Current container-compose Behavior

Before this change, `container-compose` could map explicit service `healthcheck.test` definitions to fork-backed `apple/container` `--health-*` flags, but it rejected timing-only service healthchecks because `apple/container` did not expose image-level Dockerfile healthcheck metadata.

With the fork-backed image metadata slice present, `container-compose` can now read image `HEALTHCHECK` metadata through the direct image API and merge Compose service overrides over those image defaults.

## Likely Owner

Both:

- `apple/container` owns image config parsing and the direct image resource model that exposes Dockerfile `HEALTHCHECK` metadata.
- `container-compose` owns Compose merge semantics, timing-only override behavior, and mapping inherited probes to runtime create flags.

## Minimal Example

```dockerfile
FROM alpine:3.20
HEALTHCHECK --interval=30s --timeout=3s --retries=4 \
  CMD test -f /tmp/ready
CMD ["sh", "-c", "sleep 3600"]
```

```yaml
name: inherited-healthcheck-demo

services:
  api:
    image: example/api
    healthcheck:
      interval: 5s
      retries: 2
```

Expected runtime invocation on the fork-backed integration branch:

```text
container run --health-cmd "test -f /tmp/ready" --health-interval 5s --health-timeout 3s --health-retries 2 ...
```

## References

- apple/container issue: [apple/container#440](https://github.com/apple/container/issues/440)
- apple/container health status issue: [apple/container#1502](https://github.com/apple/container/issues/1502)
- apple/container health status PR: [apple/container#1504](https://github.com/apple/container/pull/1504)
- Fork handoff: `ISSUE-image-healthcheck-metadata.md` and `PR-image-healthcheck-metadata.md` in `stephenlclarke/container`
- Previous plugin handoff: `ISSUE-service-restart-policy.md` and `PR-service-restart-policy.md`

## Code Of Conduct And Documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `COMPATIBILITY.md`.
- [x] I checked `PLAN.md`.
