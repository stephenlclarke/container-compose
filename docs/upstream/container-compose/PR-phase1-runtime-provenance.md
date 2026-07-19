# Pull request handoff: synchronize Phase 1 release stack provenance

## Summary

- Advance Compose's Container and Containerization pins to the signed Phase 1
  runtime handoff chain.
- Regenerate `Package.resolved` from the remote dependencies.
- Update the checked release stack manifest to the identical immutable refs.

## Type of change

- [x] Build and release metadata
- [x] Documentation update
- [ ] Compose command or schema behavior
- [ ] Apple runtime API

## Motivation and context

The earlier manifest described a stack that predated the completed generic
namespace work. A publishable Compose artifact must be reproducible from the
same package refs it reports in release validation, so this change restores the
single source of truth across manifests and lockfiles.

## Code map

- `Package.swift` declares exact Container and Containerization revisions.
- `Package.resolved` locks SwiftPM to the same two revisions.
- `Tools/release/stack-refs.json` provides canonical release provenance.
- `Tools/ci/check-stack-consistency.py` verifies the agreement; its existing
  unit suite covers matching and mismatched dependency configurations.

## Validation

```sh
make resolve
CONTAINER_STACK_REPO=/Users/sclarke/github/container make stack-consistency
python3 Tools/ci/test_check_stack_consistency.py
make build
make test
make check
git diff --check
```

The full local release-stack validation additionally builds the Builder shim,
Containerization, Container, and Compose from the resolved revisions. This
provenance-only slice adds no Compose behavior, so it adds no new Docker
Compose V2 YAML fixture; existing feature fixtures continue to be run in the
aggregate parity gate.

## Commit tracking

- Containerization handoff tip:
  `2d7ae6c01227d4c95a5f44fdc9768070923ee335`.
- Container pin and handoff tip:
  `bd436af1720d77599d56e3c5afe2ade4381f2ff1`.
- Compose implementation:
  `17c2b8980e108a15e2c975b8d0c31e69cb918930`
  (`chore(release): align phase one runtime refs`).

## Upstream handoff

This is a fork release-maintenance correction and is not proposed as an Apple
pull request. Future Apple pull requests must stack on accepted Apple revisions
rather than the fork URLs and hashes recorded here.

## Remaining risks

The completed lower-runtime pod policy remains insufficient for Docker Compose
service/container namespace joining because it does not retain independently
networked per-container membership. Compose continues to reject those forms
before side effects.
