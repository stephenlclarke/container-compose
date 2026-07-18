# Pull request: cover CPU-share cgroup-v2 projection

> [!IMPORTANT]
> Sign and verify all commits before opening the upstream pull request. File the linked bug report before proposing this non-trivial regression test.

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

The generic `--cpu-shares` path already stores an OCI relative weight, but a missing lower-runtime cgroup-v2 projection made it ineffective. Containerization commit `ce28048` supplies that Apple-shaped implementation. This Container change adds a guest-visible regression test, preventing the CLI consumer from silently regressing after the required lower-runtime commit is adopted.

## Changes

- Constructible Container test commit: `ac7643b` (`test(runtime): cover CPU share weight`).
- Required lower-runtime implementation: `ce28048` in `apple/containerization` (`fix(cgroup): apply OCI CPU shares as weight`).
- Required prior Containerization configuration projection: `d5e6c22`.
- Separate Compose V2 parity consumer: `82c74e82` (`test(parity): verify CPU share weight`).
- Add a `container run --cpu-shares 512` integration regression asserting that the macOS Linux guest exposes cgroup v2 `cpu.weight == 59`.

## Apple-shaped boundary

The Container change is test-only and consumes the existing generic CLI/resource surface. No Compose or Docker model enters the source, and no Windows feature, host-Linux code path, realtime scheduling, cpuset, VM CPU allocation, or host scheduler behavior is introduced.

## Testing

- [x] Focused parser/runtime-data tests passed.
- [x] `make check` passed.
- [x] The new integration test compiled with the Container test bundle.
- [x] A direct local CLI smoke using a uniquely rebuilt Containerization init image returned `59` from `/sys/fs/cgroup/cpu.weight`.
- [ ] The checked-in integration test requires a Containerization dependency pin that includes `ce28048`; the local default init image was intentionally not used because it caches the older guest runtime.

## Compatibility and risks

The test asserts the standard runc conversion for the existing positive CPU-shares option and does not change the CLI behavior. Zero remains the runtime default. The only dependency is the explicitly listed lower-runtime cgroup-v2 fix.

## Review checklist

- [ ] Replay `d5e6c22`, `ce28048`, then `ac7643b` on the intended Apple branches.
- [ ] Confirm the guest observes `cpu.weight == 59` for `--cpu-shares 512`.
- [ ] Confirm zero/unset shares retain the default cgroup value.
- [ ] Keep Docker/Compose types, Windows behavior, host-Linux behavior, realtime controls, cpusets, VM CPU allocation, and host scheduling out of scope.
