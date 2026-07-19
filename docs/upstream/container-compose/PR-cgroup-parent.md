# Pull request: support Compose guest cgroup parent

## Summary

- Remove `cgroup_parent` from the unsupported-runtime ledger.
- Validate a non-empty, relative, traversal-free guest cgroup parent before
  side effects.
- Carry the typed value in the service-create plan.
- Render it for `up`, `create`, and one-off `compose run` containers.
- Add Docker Compose V2 configuration parity coverage and update status,
  stack pins, and Apple-shaped handoff material.

## Commit tracking

- Containerization prerequisite: `8d4b530b5a8a9b8bca550e54a9820296cc548b7d`
  in `stephenlclarke/containerization`; handoff documentation:
  `cae7bd59b8db45ee70ec8c4cfafc062123e3379a`.
- Container runtime: `aa11d79f001af25a162925a5093f585fc24be955` in
  `stephenlclarke/container`; handoff documentation:
  `fb7d36bce1df42776cc401c91fa264fe7207bc2e`.
- Compose mapping: `f70e88bc8c2c092b3952d84c2a6999d0caa3bae1`.

## Apple-shaped boundary

The two generic forks expose only a validated Linux-guest cgroup-parent
primitive and its OCI projection. `container-compose` owns Compose syntax and
the relative-path policy. No fork needs Compose imports, Compose-specific
branching, or macOS-host cgroup behavior.

## Validation

```console
swift test --disable-automatic-resolution \
  --filter 'ComposeOrchestratorTests.(createMapsCgroupParentToRuntimeArguments|upMapsCgroupParentToRuntimeArguments|runMapsCgroupParentToRuntimeArguments|serviceCreatePlanMapsAndValidatesCgroupParent)' \
  -Xswiftc -warnings-as-errors
make docker-compose-cgroup-parent-parity
make test
make coverage-check
make check
markdownlint docs/upstream
```

The parity script requires Docker Compose V2's normalized configuration to
preserve `cgroup_parent`. When a Docker daemon is available, it also confirms
that `docker compose --dry-run up` accepts the same fixture. The local runtime
Engine check is skipped only when no daemon is available; the strict script does
not skip Docker Compose V2 config parity.
