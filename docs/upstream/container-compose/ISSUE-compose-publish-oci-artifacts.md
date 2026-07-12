# Support `container compose publish` OCI Project Artifacts

## Summary

`container compose publish` should publish Docker Compose OCI project artifacts for image-backed Compose projects.

## Docker Compose References

- [Docker Compose OCI artifact docs](https://docs.docker.com/compose/how-tos/oci-artifact/) define `docker compose publish REPOSITORY[:TAG]` and loading the result with `-f oci://...`.
- [Docker Compose publish CLI reference](https://docs.docker.com/reference/cli/docker/compose/publish/) lists `--app`, `--oci-version`, `--resolve-image-digests`, `--with-env`, and `--yes`.
- [docker/compose#13257](https://github.com/docker/compose/pull/13257) adds Compose application publishing with Compose YAML and `image-digests.yaml` artifact layers for [docker/compose#13238](https://github.com/docker/compose/issues/13238).
- [docker/compose#13849](https://github.com/docker/compose/pull/13849) fixes `publish` short-form port handling.
- [docker/compose#13672](https://github.com/docker/compose/issues/13672) reports the short-form port regression fixed by `docker/compose#13849`.
- [docker/compose#13722](https://github.com/docker/compose/issues/13722) tracks noninteractive `--yes` behavior around publish preflight prompts.

## Required Behavior

- Parse `container compose publish [OPTIONS] REPOSITORY[:TAG]`.
- Preserve Docker-compatible project loading, profiles, env files, Git resources, and OCI remote resources.
- Push service images before publishing the Compose project artifact.
- Publish Compose YAML layers with Docker Compose OCI project media types.
- Support OCI 1.1 artifacts and OCI 1.0 fallback manifests through `--oci-version`.
- Support `--dry-run` without registry mutation.
- Support `--resolve-image-digests` by adding a Compose override layer that pins service images to resolved digests.
- Support `--with-env` by adding existing env-file layers.
- Support `--yes` for deterministic bind-mount preflight acceptance.
- Reject build-only services before registry mutation.
- Reject local include files before registry mutation.
- Accept short-form ports such as `${DASHBOARD_PORT:-3000}:3000`.

## Current Gaps

- `--app` image index publishing is not implemented.
- Docker's interactive sensitive-data, env-declaration, and literal config-content prompts are not implemented.
- Live registry parity needs explicit credentials and cleanup outside the default local test lane.

## Runtime Boundary

This is a Compose-owned normalizer and CLI feature. It does not require new `apple/container`, `apple/containerization`, or builder-shim APIs.

## Acceptance

```sh
cd Tools/compose-normalizer && go test ./...
swift test --disable-automatic-resolution --filter ComposeNormalizerTests
swift test --disable-automatic-resolution --filter ComposeCLIHelpTests
make cli-smoke-built
```
