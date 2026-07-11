# Add non-exporting Dockerfile check mode

## Summary

Add a builder validation mode that runs BuildKit's Dockerfile lint operation
without configuring image exporters or loading an image result.

## Motivation

Validation is useful independently of Docker Compose: API and CLI clients can
check Dockerfile build configuration with the same frontend inputs as a normal
build while guaranteeing that the request has no image-export side effects.

Related issue draft: [ISSUE-build-check.md](ISSUE-build-check.md).

## Implementation

- Parse the `check` metadata field into the existing solve options.
- Reuse the normal Dockerfile conversion setup for build arguments, target,
  platforms, resolver, named contexts, labels, SSH forwarding, and secrets.
- Call the Dockerfile lint path and report diagnostics through the existing
  progress and standard-error streams.
- Leave `SolveOpt.Exports` empty and skip export archive creation.
- Keep normal build behavior unchanged when check mode is absent.

## Commit Tracking

- Apple-facing `stephenlclarke/container-builder-shim` implementation:
  `db59b64513200c4ec247ce54c3a911a9b9a25104` (`feat(build): add check
  mode`).
- The dependent host API and CLI commit is tracked separately in
  [PR-container-build-check.md](../apple-container/PR-container-build-check.md).

## Testing

- [x] Tested locally
- [x] Added or updated tests
- [x] Added or updated handoff documentation

Focused validation:

```sh
go test ./pkg/build ./pkg/stdio
go test ./...
make build
make vet
make coverage
make lint
make fmt
git diff --check
```

Coverage includes option parsing, lint diagnostics, successful check mode,
export suppression, and standard-error forwarding.

## Compatibility

Normal solves are unchanged. Check mode is opt-in and uses the existing
metadata transport, so older callers remain compatible.

## Submission Boundary

The code is prepared in the `stephenlclarke` fork and documented here for
upstream review. It must not be pushed to Apple remotes from this workspace.
