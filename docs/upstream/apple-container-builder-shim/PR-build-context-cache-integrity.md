# Verify and atomically publish BuildKit build contexts

## Summary

Harden the builder shim's content-addressed build-context cache so only verified, complete archives are visible to BuildKit.

## Motivation

The host advertises a SHA-256 for every build-context archive. The shim should verify that contract before using the digest as a cache key and must not expose a partially extracted tree to concurrent builds. Synthetic Dockerfile inputs also belong to the individual build request, not to the shared source-context cache.

Related issue draft: [ISSUE-build-context-cache-integrity.md](ISSUE-build-context-cache-integrity.md).

## Implementation

- Require canonical lower-case SHA-256 cache keys and verify each received archive before extraction.
- Extract under a per-context file lock into a temporary directory, write a completion marker, and atomically rename the completed tree into the cache.
- Reject symlinked or incomplete cache entries and remove incomplete directories only while holding the matching lock.
- Reject tar path traversal, reserved staging paths, duplicate targets, symlink traversal, unsafe hard links, and unsupported entry types.
- Stream synthetic Dockerfile inputs from request-local bytes and merge them into the ordered file walk without persisting them in the shared cache.

## Commit Tracking

- Apple-facing `stephenlclarke/container-builder-shim` implementation: `84c9c39844eb390d64178175ef406845a53a33c0` (`fix(fssync): verify and atomically publish build contexts`).
- No matching open upstream issue or pull request was found. [apple/container-builder-shim#87](https://github.com/apple/container-builder-shim/pull/87) remains adjacent `.dockerignore` work and is not a dependency.

## Testing

- [x] Tested locally
- [x] Added archive checksum, retry, cache-marker, symlink, concurrent-publisher, traversal, hard-link, and synthetic-Dockerfile regression coverage.
- [x] Ran the full module test suite and race detector.

Focused validation:

```sh
go test ./pkg/fileutils ./pkg/fssync
go test ./...
go test -race ./...
go vet ./...
make lint
make coverage
git diff --check
```

## Compatibility

Valid BuildKit context transfers retain their existing file and `.dockerignore` behavior. Invalid or incomplete transfers now fail instead of being cached. Separate builds of the same context can use different Dockerfiles without sharing synthetic content.

## Submission Boundary

The code is prepared in the `stephenlclarke` fork and documented here for upstream review. It must not be pushed to Apple remotes from this workspace.
