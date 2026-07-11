# SwiftLog Event Handlers Emit Deprecation Warnings

## I Have Done The Following

- [x] I have searched the existing issues
- [x] I reproduced or inspected the issue using the current project source

## Steps To Reproduce

1. Resolve `swift-log` 1.13.2 or newer in an `apple/container` checkout.
2. Build the `ContainerLog` target with warnings enabled.
3. Observe compatibility-bridge warnings for `FileLogHandler`,
   `OSLogHandler`, and `StderrLogHandler`.

## Problem Description

SwiftLog now uses `log(event:)` as the primary `LogHandler` entry point. The
three handlers implement only the older compatibility method, so downstream
dependency resolution can make otherwise valid builds emit deprecation
warnings.

The current fix is
[apple/container#1933](https://github.com/apple/container/pull/1933). It adds
the primary event method, keeps the compatibility method, and routes both
through one emission path so formatting and metadata precedence stay the same.

## Environment

- macOS 26 class host
- Swift 6.2 or newer
- SwiftLog 1.13.2
- Current `apple/container` `main`

## Code Of Conduct

- [x] I agree to follow this project's Code of Conduct
