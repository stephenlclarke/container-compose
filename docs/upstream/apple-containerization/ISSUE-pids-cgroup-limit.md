# Runtime gap: Linux pids cgroup limit in container configuration

## Summary

`containerization` already models OCI `linux.resources.pids` through `ContainerizationOCI.LinuxPids`, but `LinuxContainer.Configuration` did not expose a high-level field that callers could set before generating the runtime spec. That blocked Docker-compatible pids-limit behavior in `apple/container` and `container-compose` even though the final OCI shape already existed.

## Expected Behavior

Callers should be able to set an optional process-count limit on `LinuxContainer.Configuration`. When present, generated OCI specs should include `linux.resources.pids.limit`; when absent, existing default behavior should remain unchanged.

## Ownership

`containerization` owns the high-level runtime configuration field and OCI projection. `apple/container` owns the CLI/API surface that parses Docker-compatible values and passes them down. `container-compose` owns Compose service-field mapping.

## Validation Expectations

- `LinuxContainer.Configuration(pidsLimit: 128)` generates OCI `linux.resources.pids.limit == 128`.
- Existing callers that omit the field generate the same specs as before.
- No Compose-specific behavior enters `containerization`.
