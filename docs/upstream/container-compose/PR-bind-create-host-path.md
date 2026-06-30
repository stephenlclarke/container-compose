# Support bind create_host_path policy

## Summary

- Preserves compose-go's normalized bind `create_host_path` policy in the Swift model.
- Rejects missing bind sources before side effects when `bind.create_host_path: false`.
- Creates missing bind source directories before runtime handoff when the policy is true or defaulted.
- Adds focused Go normalizer and Swift orchestration coverage.
- Adds a local-only Docker Compose parity target for bind `create_host_path`.
- Bumps the plugin minor version to `0.3.0`.
- Updates README, status, parity/build docs, and release metadata.

## Type of Change

- [x] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose local development commonly relies on bind mounts whose host paths are created on demand. compose-go already carries the effective policy and defaults it to true. Apple/container requires bind source paths to exist before `container run --volume`, so `container-compose` needs to own the Docker-compatible source creation policy before invoking the runtime.

The upstream review found Docker Compose issue `docker/compose#13602` and PR `docker/compose#13889`, both centered on explicit `create_host_path: false` validation. Apple/container searches found bind mount support and relative-path work, but no API surface for Docker Compose's host-path creation policy. That makes this a `container-compose` orchestration fix.

## Implementation Details

- Added `bindCreateHostPath` to the normalized mount JSON and Swift `ComposeMount`.
- Preserved false with a pointer-backed Go JSON field so explicit opt-out is not lost.
- Added validation to reject missing false-policy bind sources during runtime-support checks, before networks, volumes, pulls, builds, or container commands.
- Added non-dry-run bind source materialization before create/run argument rendering.
- Kept advanced bind fields on the existing unsupported mount path.
- Added `Tools/parity/check-compose-bind-create-host-path.sh` and `make docker-compose-bind-create-host-path-parity`.

## Validation

```sh
gh api 'search/issues?q=repo:docker/compose+create_host_path+OR+create-host-path+OR+bind+missing+path+is:issue'
gh api 'search/issues?q=repo:docker/compose+create_host_path+OR+create-host-path+OR+bind+missing+path+is:pr'
gh api 'search/issues?q=repo:apple/container+bind+mount+source+path+OR+create_host_path+OR+missing+host+path+is:issue'
gh api 'search/issues?q=repo:apple/container+bind+mount+source+path+OR+create_host_path+OR+missing+host+path+is:pr'
go test ./...
swift test --disable-automatic-resolution --filter 'normalizesBindCreateHostPathPolicy|upCreatesMissingBindSourcesWhenCreateHostPathIsEnabled|upRejectsMissingBindSourcesWhenCreateHostPathIsDisabled|runRejectsMissingBindSourcesWhenCreateHostPathIsDisabled'
bash -n Tools/parity/check-compose-bind-create-host-path.sh
shellcheck Tools/parity/check-compose-bind-create-host-path.sh
make docker-compose-bind-create-host-path-parity
make check
make cli-smoke-built
make coverage-check
git diff --check
```

## Compatibility

This change makes `container-compose` more Docker Compose compatible for bind mounts. Explicit false-policy bind sources now fail earlier and with a Compose-owned error. Default bind mounts become more permissive on Apple/container because missing source directories are created before runtime handoff.

## Remaining Risks

- Docker Compose may refine the exact error text for `create_host_path: false` as `docker/compose#13889` evolves; the plugin intentionally matches the behavior rather than the wording.
- If Apple/container later adds its own Docker-compatible bind source creation policy, the plugin can remove the local directory creation and pass the policy through instead.
