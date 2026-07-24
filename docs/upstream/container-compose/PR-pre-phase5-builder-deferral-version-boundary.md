# Pull request handoff: expire the Builder deferral at Phase 5

> Historical release control. The boundary behaved as intended and Phase 5
> removes the exception; see
> [the closure handoff](PR-phase5-builder-release-exception-closure.md).

## Summary

- Align the temporary local Builder-suite deferral with the stable version
  lanes that precede Phase 5.
- Accept explicit milestone reasons for `0.7.x`, `0.8.x`, and `0.9.x`.
- Reject the exception from `0.10.0` onward.
- Add executable regression coverage for every accepted lane, representative
  rejected versions, and non-milestone intent.

## Motivation

The original guard correctly prevented a temporary test exception from
silently surviving forever, but tied that boundary to the already-published
`0.7.0` tag. Phase 3 promotion therefore could not reach its otherwise complete
local gate even though the same three out-of-scope Phase 5 suites remained
explicitly tracked.

This correction preserves the fail-closed design and moves its expiry to the
actual Phase 5 boundary. It does not change the suite filter, add a skip, or
alter hosted validation.

## Code map

- `scripts/CONTAINER_STACK_RELEASE.sh`
  - documents the pre-Phase-5 scope;
  - accepts only milestone candidates in `0.7.x` through `0.9.x`;
  - rejects `0.10.0` and later candidates.
- `Tools/release/test_container_stack_release.py`
  - verifies the exact local and hosted boundary remains present;
  - executes the policy for `0.7.0`, `0.8.0`, `0.9.0`, and `0.9.4`;
  - rejects `0.6.70`, `0.10.0`, `1.0.0`, and maintenance intent.

## Validation

```sh
bash -n scripts/CONTAINER_STACK_RELEASE.sh
python3 -m unittest \
  Tools.release.test_container_stack_release.ContainerStackReleasePolicyTests.test_phase5_builder_gaps_exception_is_local_and_expires_at_phase5 \
  Tools.release.test_container_stack_release.ContainerStackReleasePolicyTests.test_phase5_builder_gaps_exception_accepts_only_pre_phase5_milestones
python3 -m unittest Tools.release.test_container_stack_release
make check
git diff --check
```

The full stable gate still runs the matched Builder, Containerization,
Container, and Compose checks; all in-scope live integration suites; the live
Compose scenarios; and all 56 strict Docker Compose V2 parity contracts. The
three deferred suites remain named and fail closed if renamed or removed.

## Commit tracking

Compose implementation commit:
[`c2cd899f30bff81047ffdf164ee3565306ba7e7e`](https://github.com/stephenlclarke/container-compose/commit/c2cd899f30bff81047ffdf164ee3565306ba7e7e)
(`fix(release): expire builder deferral at phase five`).

## Upstream handoff

This is Compose release-policy maintenance rather than an Apple runtime
change. The Apple-shaped Phase 5 implementations remain defined by
[the external-Dockerfile handoff](ISSUE-phase5-external-dockerfile-paths.md)
and [the tar-export handoff](ISSUE-phase5-builder-tar-export.md). Removing this
exception in Phase 5 requires those generic Builder changes and their complete
unit and live integration suites.

## Checklist

- [x] Signed Conventional Commit
- [x] Focused executable regression tests
- [x] No new skipped or weakened suite
- [x] No hosted-gate bypass
- [x] No Apple-fork change
- [x] Phase 5 expiry remains fail closed
