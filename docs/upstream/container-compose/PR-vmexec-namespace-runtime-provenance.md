# Pull Request

## Summary

- Advance Compose's direct Container and Containerization revisions to the
  signed vmexec namespace-entry repair tips.
- Regenerate `Package.resolved` and synchronize `Tools/release/stack-refs.json`.
- Preserve an immutable, matched local graph for the existing Phase 1 runtime
  execution regressions without expanding any runtime or Compose API.

## Type of Change

- [x] Build and dependency metadata
- [x] Documentation update
- [ ] Runtime API change
- [ ] Docker Compose behavior change

## Motivation and Context

The generic lower-runtime fix compares current and target user namespaces and
avoids the Linux-invalid `CLONE_NEWUSER` reentry only when they match. The
Compose integration layer validates privileged, guest-host-user-namespace, and
private-user-namespace execution against that fixed guest image. A release
graph must resolve those reviewed lower revisions, rather than older tips that
predate the repair.

## Apple-Shaped Boundary

| Layer | Responsibility |
| --- | --- |
| `apple/containerization` | Generic guest namespace-entry repair. |
| `apple/container` | Dependency provenance only; no new API or policy. |
| `container-compose` | Docker mapping, help/status, and integration coverage. |

This fork-only provenance commit is not an Apple upstream pull request. Any
future upstream package update must use accepted Apple revisions rather than
the `stephenlclarke` fork URLs and hashes.

## Commit Tracking

- Containerization implementation:
  `fe896b6511d9fe0f0b8d3d25d3a8d8a1ed5ab5a1`
  (`fix(vmexec): avoid reentering the current user namespace`).
- Containerization handoff tip:
  `422302c9490f337ebfad0b17b9542de97bde9e34`
  (`docs(handoff): add vmexec namespace-entry repair`).
- Container provenance handoff tip:
  `f4d5366f352ddbdc2ee13314a2183b89cd7a2f96`
  (`docs(handoff): add vmexec namespace runtime provenance`).
- Compose provenance update:
  `dd0991a3344fc6cecc0c4b7e6cf756d52927f2b8`
  (`chore(release): align vmexec namespace runtime refs`).

## Code Map

- `Package.swift` declares the direct Container and Containerization revisions.
- `Package.resolved` locks the remote resolutions to those exact revisions.
- `Tools/release/stack-refs.json` records the same component refs for release
  and installed-stack validation.

## Validation

```console
swift package resolve
CONTAINER_STACK_REPO=/absolute/path/to/container \
CONTAINERIZATION_STACK_REPO=/absolute/path/to/containerization \
python3 Tools/ci/check-stack-consistency.py
make build
make test
make check
make coverage-check
make docker-compose-userns-mode-parity DOCKER_COMPOSE_REFERENCE=docker-compose
git diff --check
```

The resolved-graph build and test suite pass locally: 1,067 tests in 25
suites. Direct Docker Compose V2 configuration parity accepts `userns_mode`
`host` and `private`; the local Docker daemon is unavailable, so its Engine
dry-run assertion is correctly skipped. Matched macOS guest integration is
run separately for privileged, host-user-namespace, and private-user-namespace
execution.

## container-compose Checks

- [x] `Package.swift`, lockfile, and stack manifest use the same lower refs.
- [x] The lower forks expose signed Apple-shaped source and handoff commits.
- [x] Docker-specific behavior remains in Compose rather than the forks.
- [x] Then-current help/status marked the independent Phase 4
  `--exit-code-from` status-propagation defect as partial; the Compose-layer
  correction is now tracked by [PR-up-exit-code-from-status.md](PR-up-exit-code-from-status.md).
- [x] This commit uses a Conventional Commit subject and verified signature.
