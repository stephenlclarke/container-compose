# Unavailable build-context files can be sent as empty content

## Target

- Upstream repository: <https://github.com/apple/container-builder-shim>
- Local implementation: `stephenlclarke/container-builder-shim` commit `6bbbefff020bd899fa4642f79c57287754ba3f7e`
- Related upstream work: [apple/container-builder-shim#87](https://github.com/apple/container-builder-shim/pull/87) changes `.dockerignore` filtering only; it does not cover failed local source reads.

## Problem

When BuildKit requests a regular build-context file and the shim cannot open it from its unpacked context cache, the transfer can previously end as an empty data stream. BuildKit then receives content that looks valid but is truncated or empty, hiding the source-read failure and producing an incorrect build result.

## Expected Behavior

The shim must fail the file-sync operation with the original source-open error before it emits any data packet for that requested file. The error should identify the requested path so the caller can report a useful build failure.

## Local Resolution

The `stephenlclarke` fork returns a wrapped `Open` error from `sender.sendFile` and does not emit the terminal empty data packet after a failed open. Synthetic Dockerfile inputs continue to use their request-local reader path.

## Validation

- `go test ./pkg/fssync`
- `go test ./...`
- `go test -race ./...`
- `go vet ./...`
- `make lint`
- `make coverage`
- `git diff --check`

## Apple Submission Notes

This is a generic BuildKit file-sync correctness fix. It contains no Docker Compose policy or formatting behavior. Do not push from this workspace to Apple remotes.
