# Pull Request

## Resolution Status

This historical handoff documented the then-current partial behavior. The Phase 4 lifecycle correction is now complete; see [PR-up-exit-code-from-status.md](PR-up-exit-code-from-status.md). Current generated help and `STATUS.md` mark `up --exit-code-from` as supported.

## Summary

- Mark `compose up --exit-code-from` as partially supported in generated help
  metadata.
- Show the live terminal-status limitation in `compose up --help`.
- Correct the host-user-namespace guest test to assert its documented guest
  identity map rather than an unrelated Linux-initial-namespace condition.
- Record the independently observed `--exit-code-from` lifecycle gap in the
  parity ledger and paired issue handoff.

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

The live macOS guest integration test shows that `up --exit-code-from api`
returns generic orchestration status `5` when the selected `api` service exits
with `7`. The command previously appeared fully supported in generated help
and in `STATUS.md`, which could mislead users about Docker Compose V2 parity.

This pull request deliberately does not implement the lifecycle correction:
that is separately tracked Phase 4 work in
[ISSUE-up-exit-code-from-status.md](ISSUE-up-exit-code-from-status.md). It
makes the supported command surface truthful while retaining the existing
option, parsing, and dry-run behavior.

The host-user-namespace test correction keeps the live regression contract
aligned with `userns_mode: host`: it retains the sandbox guest's existing user
namespace and therefore reports the guest identity map `0 0 4294967295`. It
does not create, join, or claim a macOS host namespace.

## Commit Tracking

- Help metadata and unit coverage:
  `f2476b5a9a19182d47e6dbede9a5970ac2ba952d`
  (`fix(help): disclose up exit-code limitation`)
- Host-user-namespace runtime assertion:
  `7fffb111d48f44fc81c9e186ec1592c79ba58349`
  (`test(runtime): align host user namespace mapping`)
- Generic guest `vmexec` prerequisite:
  `fe896b6511d9fe0f0b8d3d25d3a8d8a1ed5ab5a1` in
  `stephenlclarke/containerization`
  (`fix(vmexec): avoid reentering the current user namespace`)

## Implementation Details

- `ComposeCLIHelp.supportByOption` assigns partial support to
  `up --exit-code-from`.
- The command help retains the option and its Docker-shaped description, now
  colors it orange and names the selected-status limitation.
- `ComposeCLIHelpTests` verifies the color, limitation, Status totals, and
  complete help/status metadata contract.
- The YAML-backed host-user-namespace runtime test reads `/proc/self/uid_map`
  directly and asserts the documented map.
- `STATUS.md` records both the option-level gap and the Phase 4 exit-control
  work item.

## Docker Compose Compatibility Notes

- Docker Compose V2 accepts and documents `--exit-code-from`; this plugin
  continues to do so.
- Dry-run rendering and unit-level orchestration behavior remain covered.
- Live selected-service status propagation is explicitly partial until the
  Phase 4 repair returns the selected terminal status instead of status `5`.
- The generic lower-runtime repair remains Docker/Compose-free and only avoids
  the Linux-invalid reentry to vmexec's current user namespace.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused checks that pass:

```console
swift test --disable-automatic-resolution \
  --filter ComposeCLIHelpTests --no-parallel
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 \
swift test --disable-automatic-resolution --skip-build \
  --filter ComposeRuntimeTests.ComposeRuntimeSmokeTests/\
runtimeHostUserNamespaceRetainsGuestIdentityMapping --no-parallel
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 \
swift test --disable-automatic-resolution --skip-build \
  --filter ComposeRuntimeTests.ComposeRuntimeSmokeTests/\
runtimePrivateUserNamespaceHasIdentityMappedGuestNamespace --no-parallel
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 \
swift test --disable-automatic-resolution --skip-build \
  --filter ComposeRuntimeTests.ComposeRuntimeSmokeTests/\
runtimePrivilegedServiceRestoresGuestReadonlyPaths --no-parallel
```

The selected-service status regression asserts the documented current status
`5`, so the release gate stays green without claiming Docker Compose V2
parity. Phase 4 acceptance must update that assertion to status `7` together
with the implementation, help text, and `STATUS.md` ledger.

## container-compose Checks

- [x] `STATUS.md` reflects the observed live limitation.
- [x] Generated help metadata and its status-contract tests agree.
- [x] The lower-runtime change is isolated and Apple-shaped.
- [x] The commits use Conventional Commit subjects and verified signatures.
- [x] The change contains no credentials, private keys, or user data.
