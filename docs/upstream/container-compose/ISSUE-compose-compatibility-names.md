# Compose compatibility gap: legacy compatibility-mode container names

## Compose Surface

```bash
docker compose --compatibility up SERVICE
docker compose --compatibility run SERVICE COMMAND
```

## Docker Compose v2 Behavior

Docker Compose keeps the modern hyphen separator for generated container names by default and uses the legacy underscore separator when root `--compatibility` is enabled. The behavior applies to service replicas and one-off `run` container names.

## Current container-compose Behavior

`container-compose` now threads root `--compatibility` into execution options and uses `_` for generated service and one-off container names in compatibility mode. The default behavior remains the modern `-` separator.

## Acceptance Criteria

- Default dry-run `up` emits names like `PROJECT-api-1`.
- `--compatibility` dry-run `up` emits names like `PROJECT_api_1`.
- `--compatibility` dry-run `run` emits names like `PROJECT_job_run_...`.
- The local parity suite compares this behavior against Docker Compose V2.
- CLI help and `STATUS.md` mark root `--compatibility` as supported.
