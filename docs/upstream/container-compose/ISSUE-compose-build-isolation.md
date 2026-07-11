# Accept Compose `build.isolation`

## Compose surface

`services.<name>.build.isolation`

## Docker Compose v2 behavior

Docker Compose V2 accepts `build.isolation` in Compose files, preserves the value in `docker-compose config --format json`, and on the local macOS/Linux-backed Buildx path omits the field from `docker-compose build --print` bake JSON while still accepting a real build.

Upstream references:

- `compose-spec/compose-spec#78` reintroduced Compose v2 attributes including `build.isolation`.
- `docker/compose#10056` tracked `build.isolation` being ignored when Compose used Buildx build options. The linked Docker Compose fix (`docker/compose@6c1f06e42032fe2eda9ece164d8caad37fa88526`) fixed classic-builder handling without adding an isolation field to the Buildx bake JSON emitted on this platform.

## Current container-compose behavior

Before this slice, the Go normalizer preserved the raw isolation string but also put every non-empty, non-`default` value into `unsupportedFields`. Swift orchestration then rejected the service before `build`, `up`, `create`, or `run` could proceed.

Minimal rejected example:

```yaml
services:
  api:
    image: example/api:isolation
    build:
      context: ./api
      isolation: hyperv
```

## Likely owner

container-compose design gap.

The current stephenlclarke fork-backed `container build` path is already BuildKit-oriented. Docker Compose V2's Buildx path accepts this Compose key without emitting a bake `isolation` field on macOS/Linux, so `container-compose` can match that behavior locally by preserving the field for config output and not rejecting or forwarding it.

## Expected behavior

- `container compose config --format json` preserves `services.api.build.isolation`.
- `container compose build --print api` omits `isolation` from the generated Buildx bake target, matching Docker Compose V2 on this platform.
- `container compose build api` does not fail with `unsupported compose feature` just because `build.isolation` is set.
- Service-level `isolation` remains a separate runtime gap; this issue covers only the build subsection.
