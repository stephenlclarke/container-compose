# Build-context cache publication does not verify or atomically mark archives

## Target

- Upstream repository: <https://github.com/apple/container-builder-shim>
- Local implementation: `stephenlclarke/container-builder-shim` commit `84c9c39844eb390d64178175ef406845a53a33c0`
- Related upstream work: [apple/container-builder-shim#87](https://github.com/apple/container-builder-shim/pull/87) is limited to `.dockerignore` filtering and does not cover archive integrity or cache publication.

## Problem

The shim uses the host-provided build-context hash as a cache key but previously trusted it without verifying the received archive. It could also expose a cache directory before extraction completed. Concurrent builds with the same context could observe a partial tree, and generated Dockerfile inputs written into that shared cache could cross-contaminate builds using different `-f` files.

## Expected Behavior

The shim must accept only canonical SHA-256 cache keys, verify the complete archive before extraction, publish each cache tree atomically after successful extraction, and never reuse incomplete or symlinked cache entries. Generated Dockerfile inputs must remain request-local while preserving ordered BuildKit file-sync metadata.

## Local Resolution

The `stephenlclarke` fork verifies the advertised SHA-256 against a temporary archive, serializes publication with a per-context lock, extracts into a temporary directory, and atomically renames a completion-marked cache tree. Cache validation rejects symlinked or incomplete entries. Tar extraction rejects path traversal, reserved staging paths, duplicate targets, symlink traversal, and unsafe hard links.

Synthetic Dockerfile and Dockerignore files are merged into the active request's ordered walk and continue to be served from request-local bytes. They are no longer written into the content-addressed context cache.

## Validation

- `go test ./pkg/fileutils ./pkg/fssync`
- `go test ./...`
- `go test -race ./...`
- `go vet ./...`
- `make lint`
- `make coverage`
- `git diff --check`

## Apple Submission Notes

This is a generic BuildKit context-transfer integrity and concurrency fix. It does not include Docker Compose behavior. Do not push from this workspace to Apple remotes.
