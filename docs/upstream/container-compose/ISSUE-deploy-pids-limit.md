# Compose compatibility gap: Deploy pids limit

## Compose surface

`services.<name>.deploy.resources.limits.pids`

## Docker Compose V2 behavior

The Compose Deploy Specification defines `pids` as an integer process-limit constraint. Docker Compose V2 preserves this value in `config --format json`.

The local Compose V2 configuration probe for this slice confirms that `pids: 64` remains in the normalized Deploy block. The focused parity target checks Docker Engine `HostConfig.PidsLimit` whenever a local Docker daemon is available.

Reference: <https://docs.docker.com/reference/compose-file/deploy/#pids>

## Previous container-compose behavior

The Go normalizer preserved the raw Deploy metadata but also reported `resources.limits.pids` in `unsupportedDeployFields`. Swift validation therefore rejected the service before it could reuse the already-supported `container run/create --pids-limit` path.

## Ownership and minimal implementation

No new Apple fork change is needed. The pinned `stephenlclarke/container` runtime already carries `--pids-limit` through to the Linux container configuration, and the existing Compose service-level `pids_limit` mapping already renders that command argument.

`container-compose` owns the narrow projection: normalize a non-zero Deploy pids limit into `pidsLimit`, then use the existing runtime argument rendering. Compose-go enforces consistency when a service-level `pids_limit` is also present.

`deploy.resources.reservations.pids` remains unsupported because it represents scheduler reservation semantics rather than a process cgroup limit. Device and generic-resource Deploy limits also remain blocked on matching runtime primitives.

## Expected behavior

- `container compose config --format json` retains the Compose Deploy block and exposes the normalized `pidsLimit` value.
- `container compose --dry-run up SERVICE` renders `--pids-limit VALUE` for a positive Deploy pids limit.
- Compose-go rejects distinct values when both service and Deploy pids limits are set; matching values normalize to the same runtime limit.
