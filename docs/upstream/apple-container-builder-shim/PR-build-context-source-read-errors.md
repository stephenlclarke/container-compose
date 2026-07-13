# Report unavailable build-context source reads

## Summary

Return the underlying source-open error when BuildKit requests a cached build-context file that the shim cannot read.

## Motivation

An unavailable requested file must fail the build rather than being represented by an empty data stream. Preserving the original error prevents silent content corruption and gives callers the path that failed.

Related issue draft: [ISSUE-build-context-source-read-errors.md](ISSUE-build-context-source-read-errors.md).

## Implementation

- Return a path-qualified error when `fs.Open` fails in `sender.sendFile`.
- Do not emit data or the terminal empty data packet after the failed open.
- Keep synthetic Dockerfile readers on their existing request-local transfer path.

## Commit Tracking

- Apple-facing `stephenlclarke/container-builder-shim` implementation: `6bbbefff020bd899fa4642f79c57287754ba3f7e` (`fix(fssync): report unavailable source reads`).
- No matching open upstream issue or pull request was found. [apple/container-builder-shim#87](https://github.com/apple/container-builder-shim/pull/87) is adjacent `.dockerignore` stream-ordering work and is not a dependency.

## Testing

- [x] Tested locally
- [x] Added a regression test for a missing source file.
- [x] Verified no packets are emitted after the open failure.

Focused validation:

```sh
go test ./pkg/fssync
go test ./...
go test -race ./...
go vet ./...
make lint
make coverage
git diff --check
```

## Compatibility

Successful file transfers are unchanged. Failed source reads now fail explicitly instead of presenting empty file content.

## Submission Boundary

The code is prepared in the `stephenlclarke` fork and documented here for upstream review. It must not be pushed to Apple remotes from this workspace.
