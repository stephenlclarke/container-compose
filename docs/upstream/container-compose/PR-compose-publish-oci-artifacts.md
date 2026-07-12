# Support `container compose publish` OCI Project Artifacts

## Summary

- Implements `container compose publish` for image-backed Compose projects.
- Pushes service images before publishing Compose YAML, optional env-file layers, optional image digest override layers, and optional application image indexes with Docker Compose OCI project media types.
- Supports `--dry-run`, `--app`, `--oci-version`, `--resolve-image-digests`, `--with-env`, and `--yes`.
- Prompts before publishing bind mounts, sensitive-looking data, env-file or literal env declarations, and literal config content.
- Rejects build-only services and local includes before registry mutation.
- Keeps upstream short-form port and optional missing `env_file` behavior valid during publish preflight.

## Upstream Alignment

The publish layer follows Docker Compose's OCI artifact workflow and media types. Image digest override layers and `--app` application image indexes follow [docker/compose#13257](https://github.com/docker/compose/pull/13257), which adds the bundled OCI distribution behavior requested in [docker/compose#13238](https://github.com/docker/compose/issues/13238). The local implementation matches Docker Compose's current referrers-API behavior tracked in [docker/compose#13428](https://github.com/docker/compose/issues/13428) without adding a non-upstream fallback. The short-form port handling incorporates the behavior from [docker/compose#13849](https://github.com/docker/compose/pull/13849), which fixes [docker/compose#13672](https://github.com/docker/compose/issues/13672). The deterministic `--yes` path is shaped by [docker/compose#13722](https://github.com/docker/compose/issues/13722). The sensitive-data, env-declaration, literal config-content, and optional missing `env_file` preflights incorporate [docker/compose#13394](https://github.com/docker/compose/issues/13394), [docker/compose@eb4b1cc](https://github.com/docker/compose/commit/eb4b1cc3f6ee5c0aee590ccb2c8d8b4a590f5780), and [docker/compose@9cd8442](https://github.com/docker/compose/commit/9cd844243f34e0a0bc5837da5bb5cee72330da9f).

## User-Facing Behavior

```sh
container compose publish registry.example.com/team/app:latest
container compose --dry-run publish --app --with-env --yes registry.example.com/team/app:latest
container compose -f oci://registry.example.com/team/app:latest config
```

`--dry-run` reports the service images and OCI layers that would be published. Live publish pushes service images through the matched runtime first, then uses Docker-compatible registry credentials through the helper resolver for the Compose project artifact, optional image digest override layer, and optional application image index. `--app` implies image digest resolution, matching Docker Compose. Interactive preflights share one stdin reader across all prompts, and `--yes` accepts every publish prompt noninteractively.

## Validation Boundary

- Live registry publish/fetch parity requires an environment with deterministic credentials and cleanup.

## Commit Tracking

- `29e3eea5 feat(publish): support Compose OCI project artifacts`
- `2344ba5c feat(publish): pin image digests in OCI artifacts`
- `325ed189 feat(publish): support application image indexes`

## Validation

```sh
cd Tools/compose-normalizer && go test ./...
swift test --disable-automatic-resolution --filter ComposeNormalizerTests
swift test --disable-automatic-resolution --filter ComposeCLIHelpTests
make cli-smoke-built
```

## Release Highlight

`container compose publish` now supports Docker-compatible interactive safety prompts for bind mounts, sensitive-looking data, env declarations, and literal config content, with `--yes` accepting all publish prompts for CI. Upstream references: [docker/compose#13257](https://github.com/docker/compose/pull/13257), [docker/compose#13238](https://github.com/docker/compose/issues/13238), [docker/compose#13428](https://github.com/docker/compose/issues/13428), [docker/compose#13849](https://github.com/docker/compose/pull/13849), [docker/compose#13672](https://github.com/docker/compose/issues/13672), [docker/compose#13722](https://github.com/docker/compose/issues/13722), [docker/compose#13394](https://github.com/docker/compose/issues/13394), [docker/compose@eb4b1cc](https://github.com/docker/compose/commit/eb4b1cc3f6ee5c0aee590ccb2c8d8b4a590f5780), and [docker/compose@9cd8442](https://github.com/docker/compose/commit/9cd844243f34e0a0bc5837da5bb5cee72330da9f).
