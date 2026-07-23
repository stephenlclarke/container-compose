# Pull request handoff: update named runtime revisions

## Summary

- Teach the stable-release pin synchronizer both supported Containerization
  manifest shapes: inline quoted revisions and the named
  `containerizationRevision` constant.
- Preserve the dependency declaration and provenance coupling when the named
  constant is used.
- Add executable positive and fail-closed regression cases.

## Motivation

The matched Container main uses a named revision constant so the SwiftPM
requirement and packaged runtime provenance cannot drift. The release helper's
older regular expression understood only an inline string, causing a safe but
incorrect failure before the Phase 3 stable gate.

The correction is deliberately narrow. It still requires the exact
`stephenlclarke/containerization` dependency URL, performs one replacement,
and errors if neither supported form is present.

## Code map

- `scripts/CONTAINER_STACK_RELEASE.sh`
  - first updates a literal `branch` or `revision` requirement;
  - otherwise verifies that the fork dependency uses
    `containerizationRevision` and updates that constant;
  - requires exactly one successful replacement.
- `Tools/release/test_container_stack_release.py`
  - executes the function against named and literal manifest fixtures;
  - verifies the named dependency declaration remains intact;
  - verifies an unrelated upstream URL is rejected.

## Validation

```sh
bash -n scripts/CONTAINER_STACK_RELEASE.sh
python3 -m unittest \
  Tools.release.test_container_stack_release.ContainerStackReleasePolicyTests.test_containerization_pin_supports_literal_and_named_revisions
python3 -m unittest Tools.release.test_container_stack_release
make check
git diff --check
```

The function was also executed against the exact current Container manifest
and revision `9097a24d60deddaaa394f73c2ec5f8276ab5867b`; it returned successfully
and left the Container worktree clean.

## Commit tracking

Compose implementation commit:
[`03f74ce997acc104135a7eecf76a9e0dc6edc78f`](https://github.com/stephenlclarke/container-compose/commit/03f74ce997acc104135a7eecf76a9e0dc6edc78f)
(`fix(release): update named runtime revisions`).

## Upstream handoff

This is fork-owned release tooling. It does not change Apple runtime behavior
or the Apple-shaped dependency proposal. Supporting the named constant keeps
the helper compatible with the minimally invasive fork manifest and avoids
rewriting that provenance abstraction during a release.

## Checklist

- [x] Signed Conventional Commit
- [x] Literal revision compatibility retained
- [x] Named revision behavior covered
- [x] Unsupported dependency rejected
- [x] No Apple-fork change
- [x] No release gate bypass
