# Issue: Make the local stack release gate self-contained

## Summary

`make release-gate` invokes Containerization's macOS integration suite in a
clean sibling checkout but did not provision that suite's documented default
kernel. The gate therefore stopped before Container integration with:

```text
No kernel found. Looked for: bin/vmlinux-arm64. See fetch-default-kernel target or build via kernel/Makefile.
```

The missing prerequisite is orchestration policy, not an Apple runtime API
gap. It belongs in `container-compose`'s local full-release validation layer.

## Reproduction

On an Apple-silicon Mac with clean sibling checkouts:

```sh
make release-gate
```

The failure occurs after Containerization's check, build, examples,
documentation, and coverage steps, when it reaches `make integration`.

Running the documented prerequisite followed by the target proves the
dependency is sufficient:

```sh
make -C containerization fetch-default-kernel
make -C containerization integration
```

The second command completed locally with 175 passed tests and 2 expected
virtio-GPU skips.

## Intended resolution

For the `full` local validation mode, request `fetch-default-kernel` directly
before `integration`. Hosted validation remains unchanged because it does not
run VM-backed integration.

## Commit Tracking

`b5f425d0b8e9e8712c4659bd555a476efdb2e7af`
`fix(release): provision integration kernel`

## Validation

- `python3 -m unittest Tools.release.test_container_stack_release`
- `make -C containerization fetch-default-kernel`
- `make -C containerization integration`
- `make release-gate` with clean, explicitly addressed sibling worktrees

The final clean release gate passed on 2026-07-22 with its explicit Phase 5
Builder exception enabled. The exception is limited to the later Builder
implementation work; Containerization integration passed with 175 tests and
2 expected virtio-GPU skips, Compose runtime passed 25 live tests, and strict
Docker Compose V2 interface parity passed against `docker compose` 5.3.1.
