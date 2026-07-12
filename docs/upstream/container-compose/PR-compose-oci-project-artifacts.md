# Support OCI Compose Project Artifacts

## Summary

- Registers a Docker Compose-compatible `oci://` resource loader in the Go normalizer helper.
- Loads OCI project artifact manifests and image indexes that reference Compose project artifacts.
- Materializes Compose YAML and env-file layers into the existing remote-resource cache.
- Keeps path traversal protection on artifact layer filenames.
- Honors `COMPOSE_EXPERIMENTAL_OCI_REMOTE=false` before network access.

## Upstream Alignment

The loader follows Docker Compose's OCI project artifact behavior from [docker/compose#12220](https://github.com/docker/compose/pull/12220), with the current artifact media types and traversal protections from [docker/compose#12289](https://github.com/docker/compose/pull/12289), [docker/compose#13311](https://github.com/docker/compose/pull/13311), and [docker/compose#13574](https://github.com/docker/compose/pull/13574). The upstream-derived OCI loader code is isolated in its own commit; local integration is limited to the helper resource-loader registration and documentation.

## User-Facing Behavior

```sh
container compose -f oci://registry.example.com/team/app:latest config
```

The artifact can contain one or more Compose YAML layers and env-file layers. Direct Compose artifact manifests, OCI 1.0 fallback manifests, OCI 1.1 artifact manifests, and image-index wrappers load through the same `compose-go` resource-loader path used by normal config, variables, and Bridge model parsing.

## Validation

```sh
cd Tools/compose-normalizer && go test ./...
swift test --disable-automatic-resolution --filter ComposeNormalizerTests
```

## Release Highlight

`container compose -f oci://...` now loads Docker Compose OCI project artifacts, including Compose YAML layers, env-file layers, image-index wrappers, and traversal-safe cached materialization. Upstream references: [docker/compose#12220](https://github.com/docker/compose/pull/12220), [docker/compose#12289](https://github.com/docker/compose/pull/12289), [docker/compose#13311](https://github.com/docker/compose/pull/13311), [docker/compose#13574](https://github.com/docker/compose/pull/13574).

## Commit Tracking

- Primary implementation commit in `stephenlclarke/container-compose`:
  local slice is uncommitted; record the upstream-import and integration commit IDs before release packaging.
