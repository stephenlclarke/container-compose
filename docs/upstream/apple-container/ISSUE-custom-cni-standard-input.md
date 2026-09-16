# Bug: large custom Kubernetes CNI manifests exceed the process argument limit

## I have done the following

- [x] I have searched the existing issues.
- [x] I reproduced the issue against the fork branch that synchronizes Apple Container's custom CNI support.

## Steps to reproduce

1. Create a valid Kubernetes CNI manifest larger than the host process argument limit.
2. Run `container k8s create --cni <manifest>` against the synchronization candidate for [apple/container#2254](https://github.com/apple/container/pull/2254).
3. Observe the control-plane bootstrap when it applies the CNI manifest.

## Problem description

Apple's initial custom-CNI implementation interpolated the complete manifest into a `/bin/sh -c` argument. A sufficiently large manifest can therefore make process creation fail with `E2BIG` before `kubectl` starts. Manifest content also does not belong in process arguments.

The manifest should be supplied through the child process's standard input while `kubectl` receives a fixed argument vector. The fork must preserve that correction alongside its existing control-plane endpoint and CoreDNS resolver fixes when synchronizing Apple `main`.

## Environment

- OS: macOS 26.6.2 (25G83)
- Xcode: 27.0 (27A266a)
- Swift: 6.4
- Container: `stephenlclarke/container` pull request 280, reviewed head `cbfe2d13198f1bb243316e573cd2870f633328ef`, merged as `84bb6e0a37176fe45927f5c6f785041c3f75f11f`

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
