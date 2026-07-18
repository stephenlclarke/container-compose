# Pull request: expose a generic fractional CPU quota primitive

## Commit tracking

- Constructible commit: `f7b45bf` (`feat(runtime): support fractional CPU quota`)
- Separate Compose consumer: `aa1a5dab` (`feat(runtime): map stop defaults and CPU CFS resources`)

## Summary

Add optional `LinuxContainer.Configuration.cpuQuotaInMicroseconds` and project
it to OCI `LinuxCPU` while retaining the established 100 ms period when no
explicit period is supplied. The sandbox VM remains integral; the guest
cgroup limits workload CPU consumption.

## Apple-shaped boundary

The type is a generic OCI microsecond quota with no Docker, Compose, CLI, or
Windows API. Its Container consumer is tracked separately as `b2a44aa`.

## Validation

Focused runtime-spec tests and the full Containerization coverage run (626
tests) passed. The consuming Container integration verified macOS guest
`cpu.max == 25000 100000`.

## Review checklist

- [ ] Replay `f7b45bf` on the intended Apple base.
- [ ] Verify omission preserves CPU-count-derived quota behavior.
- [ ] Verify an explicit quota is unchanged in the generated OCI spec.
