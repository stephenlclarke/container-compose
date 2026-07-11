# Accept Compose build secret metadata as ignored BuildKit fields

## Compose surface

`services.<name>.build.secrets[].uid`, `gid`, and `mode`

## Docker Compose v2 behavior

Docker Compose V2 accepts build-secret long syntax with `uid`, `gid`, and `mode`. It preserves those fields in `docker-compose config --format json`, but BuildKit does not implement build-secret ownership or permission metadata, so Docker Compose omits those fields from `docker-compose build --print` bake secret entries and accepts the build with only the effective secret ID plus file/env source.

Upstream references:

- `docker/compose#10704` reports that build-secret long-syntax `uid`, `gid`, and `mode` have no effect.
- `docker/compose#10709` merged the Docker Compose response: warn that build-secret `uid`, `gid`, and `mode` are not implemented and will be ignored.
- Docker Compose maintainer discussion in `docker/compose#10704` points at the BuildKit controller API shape and states that those fields are not supported.

## Current container-compose behavior

Before this slice, the Go normalizer converted file/env-backed build secrets into effective BuildKit secret arguments, but marked the whole build secret surface as unsupported whenever `uid`, `gid`, or `mode` was present. Swift orchestration then rejected `build`, `up`, `create`, or `run` before reaching a path that Docker Compose accepts.

Minimal rejected example:

```yaml
services:
  api:
    image: example/api:secretmeta
    build:
      context: ./api
      secrets:
        - source: app_secret
          target: runtime_secret
          uid: "1000"
          gid: "1000"
          mode: 0440
secrets:
  app_secret:
    file: ./secret.txt
```

## Likely owner

container-compose design gap.

This does not require a new Apple runtime primitive because Docker Compose itself cannot make BuildKit honor the metadata. `container-compose` should accept the metadata for parity, keep projecting the effective BuildKit secret ID plus file/env source, and keep genuinely unsupported build secret sources rejected.

## Expected behavior

- `container compose config --format json` no longer reports `unsupportedFields: ["secrets"]` solely because build-secret `uid`, `gid`, or `mode` is present.
- `container compose build --print api` renders Buildx-compatible secret entries without `uid`, `gid`, or `mode`, matching Docker Compose V2's BuildKit behavior.
- `container compose build api` / dry-run build emits `container build --secret id=...,src=...` or `env=...` without ownership metadata.
- External build secrets and definitions that are not file/env backed remain unsupported.
