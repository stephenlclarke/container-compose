# Support `container compose publish` OCI Project Artifacts

## Summary

`container compose publish` should publish Docker Compose OCI project artifacts for image-backed Compose projects.

## Docker Compose References

- [Docker Compose OCI artifact docs](https://docs.docker.com/compose/how-tos/oci-artifact/) define `docker compose publish REPOSITORY[:TAG]` and loading the result with `-f oci://...`.
- [Docker Compose publish CLI reference](https://docs.docker.com/reference/cli/docker/compose/publish/) lists `--app`, `--oci-version`, `--resolve-image-digests`, `--with-env`, and `--yes`.
- [docker/compose#13257](https://github.com/docker/compose/pull/13257) adds Compose application publishing with Compose YAML and `image-digests.yaml` artifact layers for [docker/compose#13238](https://github.com/docker/compose/issues/13238).
- [docker/compose#13428](https://github.com/docker/compose/issues/13428) records the current Docker Compose referrers-API compatibility behavior for application indexes.
- [docker/compose#13849](https://github.com/docker/compose/pull/13849) fixes `publish` short-form port handling.
- [docker/compose#13672](https://github.com/docker/compose/issues/13672) reports the short-form port regression fixed by `docker/compose#13849`.
- [docker/compose#13722](https://github.com/docker/compose/issues/13722) tracks noninteractive `--yes` behavior around publish preflight prompts.
- [docker/compose#13394](https://github.com/docker/compose/issues/13394) tracks publish safety checks for sensitive-looking environment variables.
- [docker/compose@eb4b1cc](https://github.com/docker/compose/commit/eb4b1cc3f6ee5c0aee590ccb2c8d8b4a590f5780) adds the upstream sensitive-looking environment variable prompt.
- [docker/compose@9cd8442](https://github.com/docker/compose/commit/9cd844243f34e0a0bc5837da5bb5cee72330da9f) keeps optional missing `env_file` entries from failing publish preflight.

## Required Behavior

- Parse `container compose publish [OPTIONS] REPOSITORY[:TAG]`.
- Preserve Docker-compatible project loading, profiles, env files, Git resources, and OCI remote resources.
- Push service images before publishing the Compose project artifact.
- Publish Compose YAML layers with Docker Compose OCI project media types.
- Support OCI 1.1 artifacts and OCI 1.0 fallback manifests through `--oci-version`.
- Support `--dry-run` without registry mutation.
- Support `--resolve-image-digests` by adding a Compose override layer that pins service images to resolved digests.
- Support `--app` by forcing image digest resolution, copying service image descriptor chains into the target repository, and pushing an OCI image index whose subject is the Compose project artifact.
- Support `--with-env` by adding existing env-file layers.
- Prompt before publishing bind mounts, sensitive-looking data, env-file or literal env declarations, and literal config content.
- Support `--with-env` by suppressing env-related prompts while still prompting for literal config content.
- Support `--yes` for deterministic preflight prompt acceptance.
- Reject build-only services before registry mutation.
- Reject local include files before registry mutation.
- Accept short-form ports such as `${DASHBOARD_PORT:-3000}:3000`.

## Runtime Boundary

This is a Compose-owned normalizer and CLI feature. It does not require new `apple/container`, `apple/containerization`, or builder-shim APIs.

## Acceptance

```sh
cd Tools/compose-normalizer && go test ./...
swift test --disable-automatic-resolution --filter ComposeNormalizerTests
swift test --disable-automatic-resolution --filter ComposeCLIHelpTests
make cli-smoke-built
```
