# Pull request: support CPU CFS quota and period

## Commit tracking

- Constructible commit: `e540824` (`feat(runtime): support CPU CFS quota and period`)
- Required prior commit: `f7b45bf`
- Separate Compose consumer: `aa1a5dab` (`feat(runtime): map stop defaults and CPU CFS resources`)

## Summary

Add `cpuPeriodInMicroseconds` to `LinuxContainer.Configuration` and project
the optional CFS pair to OCI `LinuxCPU`. With neither value, existing
CPU-count-derived quota/period behavior remains unchanged. A period without a
quota intentionally leaves quota unlimited.

## Apple-shaped boundary

This is a generic OCI and macOS Linux-guest primitive. It introduces no Docker
or Compose type, VM scheduling change, or Windows code path.

## Validation

Focused runtime-spec tests and the 626-test coverage run passed. The consumer
guest integration created a container with quota `50000`, period `200000`, and
asserted the exact cgroup v2 `cpu.max` content.

## Review checklist

- [ ] Replay `f7b45bf`, then `e540824`.
- [ ] Verify default, explicit pair, and period-only OCI projections.
- [ ] Keep realtime CPU, affinity, and host scheduling out of scope.
