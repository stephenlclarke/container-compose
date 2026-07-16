# Pull request: support Deploy pids limits

## Summary

- Map `deploy.resources.limits.pids` through the existing Compose pids-limit runtime path.
- Stop reporting the field as an unsupported Deploy resource limit.
- Extend the local Docker Compose parity target to verify normalized config, Docker Engine `HostConfig.PidsLimit`, and container-compose dry-run output for both service and Deploy forms.

## Motivation and Context

The Apple-backed runtime already exposes the Docker-compatible process cgroup primitive used by service `pids_limit`. Docker Compose V2 also applies a positive Deploy pids limit to local Engine containers, so rejecting the Deploy form created an avoidable compatibility gap.

This is intentionally a Compose-only change: it reuses the generic `container run/create --pids-limit` contract and introduces no Compose-specific behavior in either Apple-shaped fork.

## Implementation Details

- The normalizer reuses the service pids field for a non-zero Deploy value. Compose-go rejects distinct values when both Compose pids forms are set.
- The existing runtime command rendering continues to omit non-positive values.
- Pids reservations remain rejected; they require scheduler reservation semantics that the local runtime does not expose.

## Validation

```sh
go test ./Tools/compose-normalizer
swift test --filter normalizesDeployResourceLimitsThroughComposeGo
bash -n Tools/parity/check-compose-pids-limit.sh
make docker-compose-pids-limit-parity
make test
make check
```

## Commit Tracking

- Compose mapping code is the `feat/deploy-pids-limit` slice in `stephenlclarke/container-compose`.
- It relies on the existing generic Apple-shaped `--pids-limit` support in the pinned `stephenlclarke/container` dependency.
