# Version Output Truncates The Unspecified Commit Placeholder

## I Have Done The Following

- [x] I have searched the existing issues
- [x] I reproduced or inspected the issue using the current project source

## Steps To Reproduce

1. Build `container` without setting `GIT_COMMIT`.
2. Run `container --version`.
3. Observe `commit: unspeci` instead of `commit: unspecified`.

## Problem Description

The C version shim returns `unspecified` when no commit is injected.
`ReleaseVersion.singleLine(appName:)` shortens every non-nil value to seven
characters, treating the placeholder like a Git hash.

The current fix is
[apple/container#1934](https://github.com/apple/container/pull/1934). It keeps
nil, empty, and placeholder values intact while preserving seven-character
display for real commit hashes.

## Environment

- macOS 26 class host
- Swift 6.2 or newer
- Current `apple/container` `main`
- `GIT_COMMIT` unset

## Code Of Conduct

- [x] I agree to follow this project's Code of Conduct
