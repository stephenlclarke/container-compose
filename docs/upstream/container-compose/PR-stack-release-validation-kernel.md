# PR: Provision Containerization's integration kernel in the local release gate

## Summary

Make the full local stack release gate provision Containerization's documented
default kernel before running the VM-backed integration suite. This removes an
implicit, machine-local prerequisite and keeps release orchestration in the
Compose layer.

## Problem

`run-stack-release-validation.sh full` requested `integration` from a clean
Containerization checkout. That target requires `bin/vmlinux-arm64`, while the
gate did not request `fetch-default-kernel`; the release gate failed before
Container validation and Docker Compose parity could run.

## Change

- Add `fetch-default-kernel` immediately before `integration` for the `full`
  validation mode only.
- Retain the hosted target list unchanged: hosted validation deliberately does
  not run VM-backed integration.
- Update the release-validation regression assertion.

## Code Map

- `Tools/ci/run-stack-release-validation.sh` declares the full local sibling
  target sequence.
- `Tools/release/test_container_stack_release.py` prevents the prerequisite
  from being dropped from that sequence.

## Validation

```sh
python3 -m unittest Tools.release.test_container_stack_release
make -C /private/tmp/containerization-stack-validation-20260722 fetch-default-kernel
make -C /private/tmp/containerization-stack-validation-20260722 integration
make release-gate
```

The direct macOS integration validation completed with 175 passing tests and
2 expected virtio-GPU skips.

The full clean `make release-gate` passed on 2026-07-22 with its documented,
explicit Phase 5 Builder exception. The exception is narrowly limited to
later Apple Builder implementation tests. It does not exclude Containerization
integration, Compose's 25 live runtime tests, or the strict Docker Compose V2
interface-parity suite, all of which passed against `docker compose` 5.3.1.

## Compatibility and Risk

The full local gate obtains an already-documented default test kernel only if
it is absent. It does not affect product packaging, the hosted release gate,
or Docker Compose runtime behavior. The extra first-run download is deliberate
because a release gate must not depend on leftover developer state.

## Commit Tracking

`b5f425d0b8e9e8712c4659bd555a476efdb2e7af`
`fix(release): provision integration kernel`

## Upstream Scope

This is a Compose-owned release-orchestration correction, not an Apple
runtime primitive. It is ready for review in `stephenlclarke/container-compose`
and does not require an Apple runtime pull request.
