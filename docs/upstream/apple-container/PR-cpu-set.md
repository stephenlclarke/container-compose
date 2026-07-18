# Pull request: expose the generic Linux guest CPU-set resource

> [!IMPORTANT]
> Sign and verify all commits before opening the upstream pull request. File the linked feature request before proposing this feature.

## Type of Change

- [x] New feature
- [ ] Breaking change
- [x] Documentation and test update

## Motivation and Context

The Linux guest cgroup controller can apply CPU sets, but Container did not persist or forward the generic OCI CPU-set resource. This small consumer change completes the user-facing generic runtime path once the lower-level Containerization support is present.

## Changes

- Constructible Container commit: `90b6cd1` (`feat(runtime): add CPU set option`).
- Required lower-runtime implementation: `fb1dba4` in `apple/containerization` (`feat(cgroup): apply CPU set`).
- Separate Compose V2 parity consumer: `2c44de78` (`feat(runtime): map Compose CPU sets`).
- Add `ContainerConfiguration.Resources.cpuSet`, including backward-compatible decoding of older persisted configuration.
- Add generic `container run|create --cpuset-cpus <cpus>` parsing that rejects empty values but leaves cgroup CPU-set grammar to the guest kernel.
- Forward the value to `LinuxContainer.Configuration.cpuSet` and add resource, parser, command, help, and guest-visible CLI integration coverage.

## Apple-shaped boundary

The Container change is a minimal generic resource option and configuration projection. No Compose or Docker type enters Container source. It intentionally adds no Windows behavior, host-Linux behavior, CPU realtime setting, VM CPU allocation, or host scheduler control.

## Testing

- [x] Focused resource/parser/command tests passed (267 tests).
- [x] `container run --help` exposes `--cpuset-cpus` with a Linux-guest CPU-list description.
- [x] `make check` passed with the local Containerization worktree selected.
- [x] The new CLI integration test passed against a freshly rebuilt `vminit:latest`, asserting `cpuset.cpus = 0-1` and `cpuset.mems = 0`.
- [x] Compose's Docker Compose V2 config/dry-run parity target passed against Docker Compose `5.3.1`; the parity harness reported the local Docker daemon unavailable and skipped only Engine dry-run confirmation.

## Compatibility and risks

Existing containers decode with `cpuSet == nil`, so their behavior is unchanged. Values are not reinterpreted by Container: it only rejects an empty string and allows the Linux cgroup controller to remain the authority for valid CPU-set syntax.

## Review checklist

- [ ] Replay `fb1dba4`, then `90b6cd1` on the intended Apple branches.
- [ ] Verify `container run --help` includes the generic `--cpuset-cpus` option.
- [ ] Verify `--cpuset-cpus 0-1` produces valid CPU and memory-node cgroup assignments in a rebuilt guest image.
- [ ] Keep Docker/Compose types, Windows behavior, host-Linux behavior, CPU realtime controls, VM CPU allocation, and host scheduling out of scope.
