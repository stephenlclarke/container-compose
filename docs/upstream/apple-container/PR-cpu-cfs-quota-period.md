# Pull request: support CPU CFS quota and period

## Commit tracking

- Constructible commit: `81cc56f` (`feat(runtime): support CPU CFS quota and period`)
- Required lower-runtime commit: `e540824` in `apple/containerization`
- Required prior lower-runtime commit: `f7b45bf`
- Separate Compose consumer: `aa1a5dab` (`feat(runtime): map stop defaults and CPU CFS resources`)

## Summary

Expose generic `container run/create --cpu-period` and `--cpu-quota`, persist
the optional CFS values, and project them to the macOS Linux guest. Zero means
unset, `-1` quota means unlimited, and a positive `--cpus` conflicts with
positive explicit CFS controls, matching Docker Engine's NanoCPU conflict
rule. Docker Compose documents `cpu_period` and `cpu_quota` as Linux CFS
controls: <https://docs.docker.com/reference/compose-file/services/#cpu_period>.

## Apple-shaped boundary

The fork exposes generic CFS microseconds and configuration persistence only.
Compose normalization and Docker-compatible argument rendering stay in this
repository; no Compose or Docker types enter the Apple-shaped code.

## Validation

Focused parser/configuration tests, guest `cpu.max == 50000 200000`, CLI help,
`make check`, and Container's 1,042-test coverage gate passed. Docker Compose
V2 5.3.1 config and local dry-run parity passed; no local Engine was available
for its optional dry-run check.

## Review checklist

- [ ] Replay `f7b45bf`, `e540824`, then `81cc56f`.
- [ ] Verify zero/unlimited and invalid-negative handling.
- [ ] Verify explicit CFS values become the exact guest cgroup `cpu.max` pair.
- [ ] Keep CPU realtime, affinity, VM scheduling, and Windows behavior out.
