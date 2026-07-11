# Root Help Can Wait Indefinitely For Plugin Discovery

## I Have Done The Following

- [x] I have searched the existing issues and pull requests
- [x] I reproduced the underlying timeout race with deterministic tests

## Steps To Reproduce

1. Register or start the API service so an XPC connection can be established.
2. Make the service accept requests without replying to the health route.
3. Run `container --help`, `container help`, or bare `container`.
4. Observe root help waiting in daemon-backed plugin discovery.

## Problem Description

Root help enriches its command list with installed plugins, but that optional
lookup should not prevent built-in help from printing. The former XPC timeout
race also waited for a non-cancellation-aware continuation after the timeout
task fired.

[apple/container#1862](https://github.com/apple/container/pull/1862) provides
the preferred generic XPC cancellation fix. The current root-help policy and
test coverage are proposed in
[apple/container#1935](https://github.com/apple/container/pull/1935):

- import `apple/container#1862` unchanged in a standalone commit;
- add deterministic XPC cancellation and late-reply tests;
- use a one-second health deadline only for root help;
- preserve the ten-second deadline for real plugin dispatch;
- fall back to built-in help when plugin discovery is unavailable.

## Environment

- macOS 26 class host
- Swift 6.2 or newer
- Current `apple/container` `main`
- API service registered but not replying

## Code Of Conduct

- [x] I agree to follow this project's Code of Conduct
