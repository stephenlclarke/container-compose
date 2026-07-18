# Pull request: accept an explicit unlimited CPU limit

> [!IMPORTANT]
> Sign and verify all commits before opening the upstream pull request. Open the linked feature request first, as this is more than a trivial fix.

## Type of Change

- [x] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker interprets a zero CPU limit as unlimited. The generic Container CLI previously rejected `--cpus 0`, and the OCI unlimited quota sentinel reached cgroup v2 as the invalid literal `-1` rather than its required `max` spelling. This change makes the unlimited behavior explicit without introducing Docker or Compose concepts into Apple code.

## Changes

- Constructible Container commit: `29c3cc8` (`feat(runtime): accept zero CPU limits`).
- Required lower-runtime commit: `46c0921` in `apple/containerization` (`fix(cgroup): map unlimited CPU quota to max`).
- Separate Compose consumer and parity evidence: `52b0b874` in `container-compose` (`test(parity): confirm zero CPU limits`).
- `Parser.resources` accepts finite, nonnegative `--cpus`; zero retains the existing VM CPU allocation and uses the OCI unlimited-quota sentinel.
- `Cgroup2Manager` translates a negative OCI CPU quota to `max` while preserving the caller's CFS period, yielding `cpu.max = max PERIOD`.
- CLI help, parser/unit tests, a focused macOS guest integration test, and Compose V2 parity coverage cover the behavior.

## Apple-shaped boundary

The change exposes only generic CPU resource semantics already represented by OCI and cgroup v2. It contains no Compose file parsing, Docker-specific data model, Windows implementation, Linux-host code path, CPU realtime settings, cpuset support, VM CPU hotplug, or host scheduler control.

## Testing

- [x] Tested locally: Container focused parser/command suite passed (256 tests), `make check` passed, and a direct macOS guest smoke test using a uniquely rebuilt init image reported `max 100000` for `container run --cpus 0`.
- [x] Added/updated tests: Containerization's focused host `LinuxContainerTests` suite passed (36 tests) and its macOS-hosted guest integration `container cgroup unlimited CPU quota` passed (1/1).
- [x] Added/updated docs: `container --help` now documents zero as unlimited; Compose status, a Docker Compose V2.5.3.1 config/local dry-run parity fixture, and this handoff pair were updated.
- [ ] Full Container coverage: attempted but stopped after the locally parallel integration workers produced unrelated XPC create timeouts; the focused regression and direct guest smoke are green.
- [ ] Containerization `make check`: source formatting passed, but the host does not have the required `hawkeye` license tool. Cross-SDK test compilation is also unavailable because the static Linux SDK lacks Swift Testing support; the macOS-hosted guest integration is green.

## Compatibility and risks

Existing positive CPU limits retain their quota calculation. `--cpus 0` now has the conventional unlimited meaning; negative and non-finite values remain rejected. The lower-runtime conversion applies only when an existing OCI caller deliberately supplies a negative CPU quota. Docker Compose V2 normalizes `cpus: 0` to no runtime flag, which remains unchanged and is parity-tested.

## Review checklist

- [ ] Replay `46c0921`, then `29c3cc8` on the intended Apple branches.
- [ ] Confirm a zero CPU limit retains the default VM CPU count and produces `max 100000` in the Linux guest.
- [ ] Confirm positive fractional limits and explicit CFS quota/period remain unchanged.
- [ ] Keep Docker/Compose types, Windows behavior, host-Linux behavior, realtime CPU controls, and cpusets out of the patch.
