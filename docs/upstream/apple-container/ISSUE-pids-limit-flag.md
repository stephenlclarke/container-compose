# Runtime gap: Docker-compatible pids limit flag

## Summary

`apple/container` did not expose a `container run/create --pids-limit` bridge, so higher-level tooling could not request Docker-compatible pids cgroup limits even after the lower runtime model gained a `LinuxContainer.Configuration.pidsLimit` field.

## Expected Behavior

`container run` and `container create` should accept `--pids-limit VALUE`, where `VALUE` is `-1` for unlimited or a positive integer. Invalid values should fail before runtime configuration is written.

## Ownership

`apple/container` owns CLI parsing, runtime-data compatibility, and passing the parsed value to the Linux runtime service. `containerization` owns OCI spec projection. `container-compose` owns service `pids_limit` mapping.

## Validation Expectations

- `container run --pids-limit 128 IMAGE ...` encodes a Linux runtime-data pids limit.
- `container create --pids-limit -1 IMAGE ...` accepts Docker's unlimited spelling as a separate dash-prefixed argument.
- `--pids-limit 0` and values below `-1` fail before runtime mutation.
- Runtime-data payloads written before this field existed still decode successfully.
