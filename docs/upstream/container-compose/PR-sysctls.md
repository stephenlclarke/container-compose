# Pull Request

## Summary

- Map compose-go normalized service `sysctls` to repeatable `container run/create --sysctl` arguments.
- Validate malformed sysctl names before runtime commands.
- Update compatibility/status documentation to distinguish fork-backed support from released upstream support.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose exposes service-level sysctls through `services.<name>.sysctls`. `container-compose` already receives that field from compose-go, and the local `apple/container` fork already has `ContainerConfiguration.sysctls` plus Linux runtime application. The missing piece was the small command bridge: `container run/create --sysctl name=value`.

This change implements the Compose side of that bridge after the matching runtime slice in the local container fork.

References:

- Compose service `sysctls`: <https://docs.docker.com/reference/compose-file/services/#sysctls>
- Docker run `--sysctl`: <https://docs.docker.com/reference/cli/docker/container/run/#sysctl>
- Runtime handoff in the local container fork: `ISSUE-sysctl-cli.md` / `PR-sysctl-cli.md`

## Implementation Details

- Replaced the early unsupported-field rejection with `runtimeSysctlArguments(service:)`.
- Rendered sysctls in sorted name order for deterministic command output and recreate hashes.
- Added validation for empty names and names containing `=`, because the runtime CLI syntax uses `name=value`.
- Added `up` and one-off `run` command mapping tests.
- Added an invalid-name regression test.
- Updated `STATUS.md` and `STATUS.md`.

## Docker Compose Compatibility Notes

- Supported by this plugin on the integration branch: service `sysctls` mapping to `--sysctl`.
- Runtime support remains fork-backed until the `apple/container` `--sysctl` CLI/runtime bridge is accepted upstream.
- Non-goal: privileged containers, host devices, GPUs, supplemental groups, or security profile support.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```bash
swift test --filter 'ComposeOrchestratorTests/upMapsSysctlsToRuntimeArguments|ComposeOrchestratorTests/runMapsSysctlsToRuntimeArguments|ComposeOrchestratorTests/runRejectsInvalidSysctlNamesBeforeRuntimeCommands'
```

Final local checks:

```bash
make check
make coverage-check
git diff --check
```

## container-compose Checks

- [x] I updated `STATUS.md` for runtime primitive changes, or no update is needed.
- [x] I updated `STATUS.md` for active-slab changes, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I signed my commits with a GitHub-supported signature method.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
