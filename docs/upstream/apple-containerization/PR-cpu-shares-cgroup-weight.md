# Pull request: apply OCI CPU shares as cgroup v2 weight

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation and test update

## Motivation and Context

OCI CPU shares were persisted in the runtime specification but were ignored by the macOS guest's cgroup manager. A container configured with `cpu_shares: 512` therefore retained the cgroup v2 default `cpu.weight` of `100`. The fix completes an existing generic OCI resource primitive at the cgroup v2 boundary.

## Changes

- Constructible Containerization commit: `ce28048` (`fix(cgroup): apply OCI CPU shares as weight`).
- Required prior generic configuration projection: `d5e6c22` (`feat(runtime): project Linux CPU-share weight`).
- Separate Container regression consumer: `ac7643b` (`test(runtime): cover CPU share weight`).
- Separate Compose parity consumer: `82c74e82` (`test(parity): verify CPU share weight`).
- Add the runc-compatible OCI-shares-to-cgroup-v2-weight conversion (`512` shares becomes weight `59`, and `1024` becomes the cgroup v2 default weight `100`).
- Apply the converted weight to `cpu.weight` only when `LinuxCPU.shares` is nonzero.
- Add deterministic conversion/write tests and a macOS-hosted Linux guest integration test that asserts live `cpu.weight == 59`.

## Apple-shaped boundary

This is a minimal generic OCI/cgroup-v2 conversion inside the Linux guest. It introduces no Docker or Compose API, CLI option, Windows behavior, host-Linux behavior, CPU realtime feature, cpuset behavior, VM vCPU allocation, or host scheduler control.

## Testing

- [x] Cross-build compiled the modified Linux `Cgroup` module with warnings treated as errors.
- [x] `make init` rebuilt the host runtime, guest daemon, and init filesystem.
- [x] Focused macOS-hosted guest integration `container cgroup CPU share weight` passed (1/1) and read `59` from `cpu.weight`.
- [x] Focused host `LinuxContainerTests` passed (36 tests).
- [x] Direct Container smoke with a uniquely rebuilt init image read `59` after `container run --cpu-shares 512`.
- [ ] The added Linux-only cgroup-manager unit tests cannot run through this Mac's static SDK because it lacks Swift Testing support; they are deterministic and run on a Linux-capable CI worker.
- [ ] `make check` formatted sources but its license phase is blocked locally because `hawkeye` is not installed.

## Compatibility and risks

An omitted or zero share value continues to leave the cgroup default unchanged. Positive OCI shares gain the standard cgroup-v2 equivalent weight; no other CPU resource field changes. The conversion is intentionally identical to runc's current shares-to-weight behavior so Docker-compatible callers retain relative-weight semantics.

## Review checklist

- [ ] Replay `d5e6c22`, then `ce28048` on the intended Apple base.
- [ ] Verify zero/unset shares do not write `cpu.weight`.
- [ ] Verify shares `512` produce weight `59` and shares `1024` produce weight `100`.
- [ ] Keep Docker/Compose types, Windows behavior, host-Linux behavior, realtime controls, cpusets, VM CPU allocation, and host scheduling out of scope.
