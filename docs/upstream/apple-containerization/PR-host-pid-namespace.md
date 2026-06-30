# Pull request: allow host PID namespace runtime specs

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

This change gives `LinuxContainer` callers a typed way to run the workload process in the sandbox VM PID namespace. The current generated OCI spec always includes a private `.pid` namespace, which prevents downstream runtimes from implementing Docker-compatible `--pid host` / Compose `pid: host` semantics.

The API stays Apple-shaped and runtime-native: callers set `LinuxContainer.Configuration.hostPIDNamespace`, and `generateRuntimeSpec()` omits the OCI PID namespace only for that explicit request. Docker/Compose strings remain downstream policy.

## Commit Tracking

- Lower runtime code commit: `93b6e729e95a3e81cf94f662b4e5716fa9d3068d` in `stephenlclarke/containerization` (`feat(runtime): allow host PID namespace specs`).
- Initial container API/CLI PID commit: `727ed4e75245f6ac1499fcd4a8330982bf0cbb6d` in `stephenlclarke/container` (`feat(runtime): add host PID namespace option`), tracked separately in `docs/upstream/apple-container/PR-host-pid-namespace.md`.
- Current reviewed container pin: `110f340456d2a25cb0256094bd671c6b91c949e4`, which also includes the separate host-network runtime path used by the same `container-compose` namespace-mode slice.
- Compose integration code is tracked in `docs/upstream/container-compose/PR-host-namespace-modes.md`.

## Implementation Details

- Added `hostPIDNamespace` to `LinuxContainer.Configuration`, defaulting to `false`.
- Preserved the existing namespace list for default containers.
- Omitted `LinuxNamespace(type: .pid)` only when `hostPIDNamespace` is enabled.
- Added a focused `LinuxContainerTests.runtimeSpecCanUseHostPIDNamespace` unit test that proves the default spec remains isolated and the host-PID spec omits `.pid`.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter LinuxContainerTests/runtimeSpecCanUseHostPIDNamespace
git diff --check
```

## Compatibility Notes

- Default behavior is unchanged because `hostPIDNamespace` defaults to `false`.
- This does not expose a Docker or Compose API in `containerization`.
- This does not implement service/container PID namespace joining; it only covers the host namespace subset.

## Remaining Risks

- End-to-end behavior depends on downstream `apple/container` passing the configuration through to runtime create.
- Upstream may prefer a more general namespace policy type if additional namespace modes are added later.
