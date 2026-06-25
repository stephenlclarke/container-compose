# Pull Request

## Summary

- Honor service-level `mode` on generated runtime config and secret grants.
- Parse Compose octal mode strings from compose-go, ignore writable bits, and preserve executable bits.
- Include effective permissions in materialized file names so mode-only changes affect recreate hashes.
- Keep file-backed grants on Docker Compose bind-mount semantics and reject generated `uid`/`gid` ownership remapping clearly.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose service `configs` and `secrets` long syntax includes `mode` for mounted file permissions. The Compose service documentation states that `mode` is octal, defaults to `0444`, ignores writable bits, and may preserve executable bits. For local Docker Compose secrets, `uid`, `gid`, and `mode` are implemented only when the secret source is `environment`; file-backed sources use bind mounts and ignore the metadata.

The previous materialization slice gave `container-compose` control over generated local files for `configs.content`, `configs.environment`, and `secrets.environment`. That means `container-compose` can now apply the Compose `mode` contract locally without adding Compose-specific policy to `apple/container`.

`uid` and `gid` remain runtime gaps. A host bind mount cannot reliably project arbitrary in-container ownership, so generated grants that request ownership remapping fail before resources are created.

## Commit Tracking

- Compose code commit: `4d3bc2e` (`feat(configs): honor generated grant modes`)
- Container code commit: not required; this slice only changes `container-compose`
- Lower runtime code commit: not required

## Implementation Details

- Extended the private service config/secret grant parser to retain `uid`, `gid`, and `mode`.
- Added octal mode parsing for normalized compose-go strings such as `0440`, `0555`, and `0o400`.
- Applied `mode & ~0o222` so writable bits are ignored and executable bits are preserved.
- Changed generated config and secret default permissions to Compose default `0444`.
- Included the effective permission mode in the materialized file digest so permission-only changes change the bind-mount source path and service config hash.
- Left file-backed grants as direct read-only bind mounts without mutating source permissions, matching Docker Compose local bind-mount behavior.
- Added clear unsupported errors for generated grant `uid`/`gid` requests.

## Docker Compose Compatibility Notes

- Supported now: generated `configs.content`, `configs.environment`, and `secrets.environment` grant modes.
- Supported now: Compose writable-bit ignoring and executable-bit preservation.
- Supported now: file-backed grant metadata remains source-file controlled and is not mutated by `container-compose`.
- Remaining gap: `uid`/`gid` ownership remapping for generated grants needs an `apple/container` runtime primitive.
- Remaining gap: external configs/secrets still need an `apple/container` lookup or store primitive.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
cd Tools/compose-normalizer && go test ./...
swift test --filter 'ComposeOrchestratorTests/upMaterializesInlineConfigsAndEnvironmentBackedSecrets|ComposeOrchestratorTests/upRejectsGeneratedConfigOwnershipRemappingBeforeCreatingResources|ComposeOrchestratorTests/upRejectsInvalidGeneratedSecretModeBeforeCreatingResources|ComposeOrchestratorTests/runMaterializesEnvironmentBackedSecrets'
```

Results: passed locally on 2026-06-22. The focused Swift run executed 4 tests. The Go normalizer run passed for `Tools/compose-normalizer`.

## container-compose Checks

- [x] I updated `STATUS.md` for runtime primitive changes, or no update is needed.
- [x] I updated `PLAN.md` for newly discovered gaps, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I signed my commits with a GitHub-supported signature method.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
