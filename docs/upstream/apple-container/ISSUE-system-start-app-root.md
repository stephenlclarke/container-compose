# System Start Can Adopt The Wrong App Root

## Upstream Reference

- Existing report: [apple/container#1757](https://github.com/apple/container/issues/1757)

Do not open a duplicate issue.

## Problem

`ServiceManager.register` discards the `launchctl bootstrap` termination
status. A repeated `container system start --app-root B` can therefore appear
successful while launchd continues running the singleton API service created
for app root A. The health response already exposes the live daemon's app root,
but `SystemStart` discards it.

## Expected Behavior

- A nonzero launchd bootstrap result is an error.
- An already registered API service is not bootstrapped again.
- The live health response must identify the requested canonical app root.
- A mismatch explains that the existing system must be stopped before changing
  `--app-root`.

## Ownership

This is native `container` service lifecycle and identity handling. Compose
must be able to trust a successful system start without probing private paths.
