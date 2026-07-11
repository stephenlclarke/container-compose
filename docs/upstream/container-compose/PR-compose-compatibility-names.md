# Support compatibility-mode container names

## Summary

- Threads root `--compatibility` into `ComposeExecutionOptions`.
- Uses `_` instead of `-` for generated service and one-off container names when compatibility mode is enabled.
- Adds Swift regression coverage.
- Adds a Docker Compose parity script and Makefile target for compatibility-name behavior.
- Marks root `--compatibility` supported in status/help metadata.

## Type of Change

- [x] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose V2 retains legacy underscore container names behind root `--compatibility`. `container-compose` parsed the flag but did not change generated names, so scripts depending on legacy names could not use the compatibility mode they expected.

This is a Compose-owned naming policy. It does not require Apple runtime changes.

## Implementation Details

- Added `serviceContainerNameSeparator` to execution options.
- Configured global orchestrator construction to select `_` when `--compatibility` is present.
- Updated generated service and one-off container name helpers to use the configured separator.
- Added `Tools/parity/check-compose-compatibility-names.sh`.
- Added `docker-compose-compatibility-names-parity` and included it in `make docker-compose-parity`.

## Validation

```bash
swift test --filter ComposeOrchestratorTests/compatibilityModeUsesLegacyUnderscoreContainerNames --no-parallel
bash -n Tools/parity/check-compose-compatibility-names.sh
make docker-compose-compatibility-names-parity
git diff --check
```

## Compatibility Notes

Default generated names keep the modern Docker Compose V2 hyphen separator. The underscore separator is only used when root `--compatibility` is enabled.

## Commit Tracking

- Primary implementation commit in `stephenlclarke/container-compose`:
  `cd78edc37aa7a9887712b6082cd7516a5f8156a0`.
