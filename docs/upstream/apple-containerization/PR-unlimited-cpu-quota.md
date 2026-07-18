# Pull request: map an unlimited OCI CPU quota to cgroup v2 max

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation and test update

## Motivation and Context

An OCI CPU quota below zero means unlimited, but a cgroup v2 `cpu.max` file accepts `max` rather than a negative numeric quota. The current direct write fails with `EINVAL` in the Linux guest. Converting the existing sentinel at the cgroup boundary restores the intended OCI behavior without changing the public resource model.

## Changes

- Constructible Containerization commit: `46c0921` (`fix(cgroup): map unlimited CPU quota to max`).
- Separate generic Container consumer: `29c3cc8` (`feat(runtime): accept zero CPU limits`).
- Separate Compose parity consumer: `52b0b874` (`test(parity): confirm zero CPU limits`).
- `Cgroup2Manager.applyResources` converts a negative `LinuxCPU.quota` to `max` and preserves the specified period when writing `cpu.max`.
- A deterministic cgroup-manager unit test verifies `max 100000` in a fake cgroup directory.
- A macOS-hosted Linux guest integration test creates a generic container with quota `-1` and period `100000`, then asserts its live `cpu.max` value.

## Apple-shaped boundary

This is a minimal generic OCI-to-cgroup-v2 translation at the Linux guest boundary. No Docker/Compose type, CLI flag, Windows behavior, Linux-host behavior, real-time CPU scheduling, cpuset support, VM CPU count behavior, or host scheduling feature is added.

## Testing

- [x] Focused host `LinuxContainerTests` suite passed (36 tests).
- [x] `make init` successfully rebuilt the host runtime, Linux guest daemon, and init filesystem.
- [x] Focused macOS-hosted guest integration `container cgroup unlimited CPU quota` passed (1/1) and observed `max 100000`.
- [x] A direct Container smoke using a uniquely rebuilt init image printed `max 100000` for `container run --cpus 0`.
- [ ] Full Containerization check: Swift formatting passed, but `make check` could not run its license phase because `hawkeye` is not installed on this Mac.
- [ ] Linux static-SDK test run: unavailable locally because the SDK lacks the Swift Testing module; the focused macOS guest integration covers the Linux guest behavior.

## Compatibility and risks

Positive quotas retain the exact `quota period` output. The conversion is limited to negative quotas, which OCI reserves for unlimited CPU time. An omitted quota still follows the existing resource path. The only behavior change is replacing an invalid cgroup v2 write with its documented unlimited representation.

## Review checklist

- [ ] Replay `46c0921` on the intended Apple base.
- [ ] Verify a negative quota writes `max PERIOD` and a positive quota remains numeric.
- [ ] Verify the generated OCI specification still carries the original quota value.
- [ ] Keep Docker/Compose types, Windows behavior, host-Linux behavior, realtime controls, cpusets, and VM CPU allocation out of scope.
