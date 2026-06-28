# Honor Shared Process `--ulimit` Flags

## Bug Report Details

`apple/container` exposes `--ulimit <limit>` through the shared process option group used by `container run`, `container create`, `container exec`, and `container machine run`, but only run/create currently route those values through `Parser.rlimits(...)` into `ProcessConfiguration.rlimits`.

The result is inconsistent behavior:

- `container run --ulimit ...` and `container create --ulimit ...` persist and apply the requested process rlimits.
- `container exec --ulimit ...` accepts the option but starts the process without the requested rlimits.
- `container machine run --ulimit ...` accepts the option but starts the machine process without the requested rlimits.

Because the flag is already advertised by the Apple CLI surface, users and higher-level tooling cannot distinguish an intentionally unsupported option from an accepted-but-ignored one.

## Expected Behavior

- `container exec --ulimit nofile=1024:2048 ...` should send `RLIMIT_NOFILE` in the additional process configuration.
- `container machine run --ulimit nofile=1024:2048 ...` should send `RLIMIT_NOFILE` in the machine process configuration.
- `container exec` without explicit `--ulimit` should preserve any inherited base process rlimits from the container's init process, matching existing behavior.
- Invalid and duplicate ulimit forms should fail through the existing parser before process creation.

## Compatibility Notes

Docker `container run` supports `--ulimit`; Docker `container exec` does not list `--ulimit` today. This fix does not try to force Docker CLI parity for exec. It instead makes the already-exposed Apple process flag behave consistently with Apple’s typed `ProcessConfiguration.rlimits` API.

`container-compose` already maps service `ulimits` to `container run --ulimit`, so Compose service ulimit support does not depend on this exec/machine-run fix. The fix is still useful for direct container CLI users, lifecycle hooks that reuse process configuration paths, and future orchestration features that need per-process rlimit control.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct
