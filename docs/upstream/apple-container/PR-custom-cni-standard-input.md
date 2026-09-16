# Fix large custom CNI manifest application

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

[apple/container#2254](https://github.com/apple/container/pull/2254) adds `--cni` support, but its bootstrap path places the complete manifest in a shell command argument. That is bounded by the host's process argument limit and can fail before `kubectl` executes. This fork synchronization also needs to retain the existing fork control-plane endpoint and CoreDNS resolver corrections.

The correction invokes `/bin/kubectl` directly with `--kubeconfig /etc/kubernetes/admin.conf apply -f -` and supplies the exact manifest bytes on standard input. The shared captured-process helper stages optional standard input in a unique mode-`0600` file, passes its handle as file descriptor zero, and removes it on every return path. The manifest is never present in the executable or argument vector. Custom manifests are opened without blocking or following a final symlink, verified as regular files through the opened descriptor, decoded once, and retained as an immutable snapshot before provisioning begins.

The synchronization was merged by [stephenlclarke/container#280](https://github.com/stephenlclarke/container/pull/280) at `84bb6e0a37176fe45927f5c6f785041c3f75f11f`. The corresponding problem statement is [ISSUE-custom-cni-standard-input.md](ISSUE-custom-cni-standard-input.md).

## Testing

- [x] `swift test --filter K8sPluginTests --no-parallel` passes all 69 focused tests in 17 suites.
- [x] A 420 KB regression manifest is preserved byte-for-byte on standard input and its marker is absent from every process argument.
- [x] A FIFO is rejected without blocking, and replacing a manifest after preflight does not change the immutable snapshot supplied to bootstrap.
- [x] Injected descriptor-inspection and read failures prove both snapshot error paths return typed failures without leaking the opened descriptor.
- [x] The exact-head hosted suite passes all 2,523 tests in 280 suites, and split SwiftPM test-bundle discovery exports LCOV and Sonar XML from 24 unit-test executables.
- [x] Strict Swift formatting passes for every touched source and test file.
- [x] Exact-head automated review at `cbfe2d13198f1bb243316e573cd2870f633328ef` reports no major issue.
- [x] Exact-head SonarQube reports 90.625% changed-code coverage (87/96), 0.0% duplication, and zero bugs, vulnerabilities, security hotspots, or code smells.

## Compatibility and parity

The command-line surface remains Apple's `container k8s create --cni`. Small manifests behave as before; large manifests now avoid `ARG_MAX`. This change is independent of Docker and Docker Compose and adds no Compose policy or persistent runtime state.

## Migration and rollback

No state migration is required. Reverting the standard-input change restores the argument-size defect but does not alter existing cluster metadata.

## Remaining risks

The full VM-backed cluster creation path remains covered by the repository's integration and release gates. Temporary standard-input data is host-local, mode `0600`, and removed by deferred cleanup; abrupt host termination can still leave an isolated temporary file for ordinary operating-system cleanup.
