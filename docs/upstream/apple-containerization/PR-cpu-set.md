# Pull request: apply generic OCI CPU sets in the cgroup v2 guest

## Type of Change

- [x] New feature
- [ ] Breaking change
- [x] Documentation and test update

## Motivation and Context

The generic OCI `LinuxCPU.cpus` field was not represented in Containerization's configuration or consumed by the macOS guest cgroup manager. This prevented an otherwise supported cgroup v2 CPU-set primitive from reaching a container.

## Changes

- Constructible Containerization commit: `fb1dba4` (`feat(cgroup): apply CPU set`).
- Generic Container consumer: `90b6cd1` (`feat(runtime): add CPU set option`).
- Compose V2 parity consumer: `2c44de78` (`feat(runtime): map Compose CPU sets`).
- Add optional `LinuxContainer.Configuration.cpuSet` and construct OCI `LinuxCPU(cpus:)` from it.
- Initialize an implicit `cpuset.mems` from the parent effective memory-node set before writing `cpuset.cpus`; preserve an explicit OCI memory-node set when present.
- Add configuration/spec tests, a deterministic fake-cgroup manager test, and a macOS-hosted guest integration test that reads the live CPU and memory-node assignments.

## Apple-shaped boundary

The implementation adds a small generic OCI/cgroup-v2 primitive in the Linux guest. It contains no Docker/Compose model or CLI, no Windows or host-Linux path, no CPU realtime control, no VM CPU hotplug/allocation, and no host scheduler policy.

## Testing

- [x] Focused host `LinuxContainerTests` passed (37 tests).
- [x] Focused macOS-hosted guest integration `container cgroup CPU set` passed (1/1), reading `cpuset.cpus = 0-1` and `cpuset.mems = 0`.
- [x] A direct generic Container smoke using a uniquely rebuilt init image read the same two values after `container run --cpuset-cpus 0-1`.
- [x] The corresponding Container CLI integration test passed using the freshly rebuilt `vminit:latest`.
- [x] Compose's Docker Compose V2 config/dry-run parity target passed against Docker Compose `5.3.1`; the local Docker daemon was unavailable, so Engine dry-run confirmation was intentionally skipped by the parity harness.

## Compatibility and risks

An omitted CPU set remains unchanged. For a supplied CPU set, initializing the memory-node set is required by cgroup v2 before a child cgroup can accept `cpuset.cpus`; the parent effective node set is the least-surprising generic default. An explicit OCI memory-node value still wins.

## Review checklist

- [ ] Replay `fb1dba4` on the intended Apple base.
- [ ] Verify an unset CPU set leaves cgroup defaults unchanged.
- [ ] Verify `cpuset.cpus = 0-1` also receives a valid `cpuset.mems` value.
- [ ] Keep Docker/Compose types, Windows behavior, host-Linux behavior, CPU realtime controls, VM CPU allocation, and host scheduling out of scope.
