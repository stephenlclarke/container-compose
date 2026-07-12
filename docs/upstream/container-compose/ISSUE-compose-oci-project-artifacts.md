# Support OCI Compose Project Artifacts

## Summary

`container compose` should accept Docker Compose `oci://` project artifacts wherever a Compose file can be loaded through `-f` / `--file`.

## Docker Compose References

- [docker/compose#12220](https://github.com/docker/compose/pull/12220) adds `-f oci://...` Compose artifact loading.
- [docker/compose#12289](https://github.com/docker/compose/pull/12289) keeps OCI 1.1 artifact pushes loadable by publishing the empty config descriptor.
- [docker/compose#13311](https://github.com/docker/compose/pull/13311) fixes OCI Compose override support.
- [docker/compose#13574](https://github.com/docker/compose/pull/13574) rejects path traversal in OCI artifact filenames across platforms.

## Required Behavior

- Accept `oci://REPOSITORY[:TAG|@DIGEST]` through `--file`.
- Fetch Docker Compose OCI project manifests from registries using Docker-compatible credential lookup.
- Support direct OCI image manifests and OCI image indexes that point at a Compose project artifact.
- Materialize Compose YAML layers into a cached `compose.yaml`.
- Materialize published env-file layers beside the Compose file.
- Reject artifact layer filenames containing path separators, absolute paths, or parent-directory traversal.
- Honor `COMPOSE_EXPERIMENTAL_OCI_REMOTE=false` with a clear failure before registry access.

## Runtime Boundary

This is a Compose project-loading feature in the Go helper. It requires `compose-go`, OCI registry reads, and Docker-compatible credentials, but no `apple/container`, `apple/containerization`, or builder-shim API change.

## Acceptance

```sh
cd Tools/compose-normalizer && go test ./...
swift test --disable-automatic-resolution --filter ComposeNormalizerTests
```
