# Pull request: align up-menu parity with retained exit-control containers

## Purpose

Align the Docker Compose up-menu parity contract with the existing stop-and-retain exit-control lifecycle. This corrects the test oracle that halted the stable 0.14.1 release at parity contract 56.

Closes [`#432`](https://github.com/stephenlclarke/container-compose/issues/432).

## Scope

- Expect `container stop` after the exit-controlled dry-run wait step.
- Reject any subsequent `container delete` plan.
- Leave production behavior unchanged.

## Evidence

- `bash -n Tools/parity/check-compose-up-menu.sh`
- `shellcheck Tools/parity/check-compose-up-menu.sh`
- `CONTAINER_COMPOSE=.build/arm64-apple-macosx/release/compose ./Tools/parity/check-compose-up-menu.sh --strict`
- `git diff --check`

The focused parity contract passed against the release binary. Existing orchestrator regressions independently assert the same stop-and-retain behavior and reject deletion.

## Compatibility and risk

This is a test-oracle correction only. The main risk is accidentally accepting both stop and delete; the new negative assertion prevents that regression.
