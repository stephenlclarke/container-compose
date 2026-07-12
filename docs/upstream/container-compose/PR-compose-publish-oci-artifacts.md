# Support `container compose publish` OCI Project Artifacts

## Summary

- Implements `container compose publish` for image-backed Compose projects.
- Pushes service images before publishing Compose YAML and optional env-file layers with Docker Compose OCI project media types.
- Supports `--dry-run`, `--oci-version`, `--with-env`, and `--yes`.
- Rejects build-only services, local includes, `--app`, and `--resolve-image-digests` before registry mutation.
- Uses the upstream `LoadModelWithContext` publish path shape so short-form ports remain valid.

## Upstream Alignment

The publish layer follows Docker Compose's OCI artifact workflow and media types. The short-form port handling incorporates the behavior from [docker/compose#13849](https://github.com/docker/compose/pull/13849), which fixes [docker/compose#13672](https://github.com/docker/compose/issues/13672). The deterministic `--yes` bind-mount path is shaped by [docker/compose#13722](https://github.com/docker/compose/issues/13722).

## User-Facing Behavior

```sh
container compose publish registry.example.com/team/app:latest
container compose --dry-run publish --with-env --yes registry.example.com/team/app:latest
container compose -f oci://registry.example.com/team/app:latest config
```

`--dry-run` reports the service images and OCI layers that would be published. Live publish pushes service images through the matched runtime first, then uses Docker-compatible registry credentials through the helper resolver for the Compose project artifact.

## Current Gaps

- `--app` image index publishing remains unsupported.
- `--resolve-image-digests` remains unsupported.
- Docker's interactive sensitive-data, env-declaration, and literal config-content prompts remain unsupported; deterministic preflight currently covers build-only services, bind mounts, local includes, and unsupported options.
- Live registry publish/fetch parity requires an environment with deterministic credentials and cleanup.

## Validation

```sh
cd Tools/compose-normalizer && go test ./...
swift test --disable-automatic-resolution --filter ComposeNormalizerTests
swift test --disable-automatic-resolution --filter ComposeCLIHelpTests
make cli-smoke-built
```

## Release Highlight

`container compose publish` now pushes service images and creates Docker Compose OCI project artifacts for image-backed projects, including `--dry-run`, `--oci-version`, `--with-env`, `--yes`, and short-form ports such as `${DASHBOARD_PORT:-3000}:3000`. Upstream references: [docker/compose#13849](https://github.com/docker/compose/pull/13849), [docker/compose#13672](https://github.com/docker/compose/issues/13672), [docker/compose#13722](https://github.com/docker/compose/issues/13722).

## Commit Tracking

- Local implementation, tests, and documentation: pending commit.
