# Pull Request

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

This change extends the existing local privileged-process primitive to init-process creation paths. `container run --privileged` is already requested upstream in [apple/container#206](https://github.com/apple/container/issues/206), and Compose service-level `privileged: true` needs the same generic runtime surface for service containers.

The Apple-facing shape stays generic: the CLI sets `ProcessConfiguration.privileged`, and the runtime decides how that process privilege request maps onto Linux capabilities. Compose-specific service semantics, dry-run formatting, and Docker parity notes stay in `container-compose`.

References:

- Apple issue: <https://github.com/apple/container/issues/206>
- Docker Compose service `privileged`: <https://docs.docker.com/reference/compose-file/services/#privileged>
- Docker run `--privileged`: <https://docs.docker.com/reference/cli/docker/container/run/#privileged>

## Commit Tracking

- Container code commit: `9871093f3c5585775a7dc4ff957aa360baf47ac1` in `stephenlclarke/container` (`feat(process): support privileged init processes`).
- Compose integration code is tracked in `docs/upstream/container-compose/PR-service-privileged.md`, not part of this Apple PR.

## Implementation Details

- Moved `--privileged` into the shared process option group used by run, create, exec, and machine run.
- Passed `processFlags.privileged` through `Parser.process` so `container run` and `container create` set `ProcessConfiguration.privileged`.
- Updated `container exec` to use the shared process flag instead of a duplicate exec-only flag.
- Passed the flag into the machine-run process configuration so accepted process flags are not ignored.
- Updated command reference and capability how-to documentation.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --disable-automatic-resolution --filter 'ParserTest.testProcessPrivilegedFlag|ContainerRunCreateCommandTests|ContainerExecCommandTests.execParsesPrivilegedFlag|MachineRunCommandTests'
.build/debug/container run --help | rg -n -- '--privileged|USAGE|OPTIONS|Process options'
.build/debug/container create --help | rg -n -- '--privileged|USAGE|OPTIONS|Process options'
.build/debug/container exec --help | rg -n -- '--privileged|USAGE|OPTIONS|Process options'
.build/debug/container machine run --help | rg -n -- '--privileged|USAGE|OPTIONS|Process options'
```

Before release promotion, run the broader local gate:

```sh
swift build -c release --disable-automatic-resolution --product container
markdownlint docs/command-reference.md docs/how-to.md
git diff --check
```

## Dependency Notes

This slice does not require a new `containerization` API because `Containerization.LinuxCapabilities.allCapabilities` already exists and `ProcessConfiguration.privileged` is already present in the local fork.

## Remaining Risks

- This maps privileged process intent to Linux capabilities. It does not implement Docker's full privileged container behavior for devices, seccomp, AppArmor, or other isolation boundaries.
- Upstream review may prefer a different CLI spelling or a more explicit capability override model; the typed process configuration field keeps the runtime boundary small either way.
