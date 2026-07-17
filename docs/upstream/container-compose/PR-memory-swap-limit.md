# Pull request: support Compose memory-plus-swap limits

## Summary

- Remove `memswap_limit` from the unsupported runtime ledger.
- Preserve Docker Compose's total-memory-plus-swap meaning, zero-as-unset behavior, `-1` unlimited-swap sentinel, and required `mem_limit` relationship.
- Use Docker's two-times-`mem_limit` default when a hard memory limit is present without an explicit non-zero `memswap_limit`.
- Carry the resolved signed byte value in the Compose-owned service-create plan and render it for `up`, `create`, and one-off `run`.
- Pin the matched Container and Containerization runtime primitives, with Apple-shaped handoff documents kept separate.

## Commit tracking

- Containerization prerequisite: [`06c00072bcb7868dcd1f3e378a7319faa00ae42c`](https://github.com/stephenlclarke/containerization/commit/06c00072bcb7868dcd1f3e378a7319faa00ae42c) (`feat(runtime): project memory swap limit`) on `stephenlclarke/containerization` `main`.
- Container runtime transport: [`57cba8e39f5c0aa5d0a2566ff0e5187d9f63b105`](https://github.com/stephenlclarke/container/commit/57cba8e39f5c0aa5d0a2566ff0e5187d9f63b105) (`feat(runtime): carry memory swap limit`) on `stephenlclarke/container` `main`.
- Compose mapping: this change, to be recorded here with its immutable `container-compose` `main` SHA after the complete matched-stack gate passes.

## Compatibility contract

- `memswap_limit` is the total of memory and swap, not an amount of swap added to `mem_limit`.
- An omitted or zero value is unset. When `mem_limit` is configured, the Compose policy layer resolves Docker's default total to twice that hard memory limit before runtime projection.
- `-1` means unlimited swap and requires a positive `mem_limit`.
- A positive total must be at least `mem_limit`; invalid values fail before networks, containers, or images are changed.
- Deploy resource reservations and unrelated memory controls remain separate runtime/scheduler work.

## Scope boundary

The Compose layer owns syntax, validation, error messages, defaulting, and command composition. The lower stack only carries an optional signed Linux resource value to OCI. This does not introduce a general interception framework or Compose-specific type into either Apple-shaped handoff.

## Validation

```console
cd Tools/compose-normalizer && go test ./...
swift test --disable-automatic-resolution --filter 'ComposeOrchestratorTests/(serviceCreatePlanValidatesMemorySwapLimits|createMapsMemorySwapLimitToRuntimeArguments|upMapsMemorySwapLimitToRuntimeArguments|upMapsDefaultMemorySwapLimit)'
bash -n Tools/parity/check-compose-memory-swap-limit.sh
make docker-compose-memory-swap-limit-parity
make check
make test
```

The completed integration gate must also include the matched-runtime test and Docker Compose parity evidence before the Compose commit is published.
