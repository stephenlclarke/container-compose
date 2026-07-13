# Serialize vmnet-backed integration tests

## Summary

The macOS integration runner executes vmnet-backed container and pod networking tests in its normal concurrent pool. Virtualization.framework can invalidate a VM's XPC connection when several of those host-networking cases start and stop at the same time.

## Current Gap

The intermittent failure is reported as `VZErrorDomain Code=1`, with the virtual machine stopping unexpectedly. It makes the release gate nondeterministic even though the same IPv6 case succeeds when run serially.

No matching open Apple issue or pull request was found after reviewing the current `apple/containerization` IPv6, vmnet, and integration work.

## Proposed Shape

- Mark only vmnet-backed integration cases as requiring exclusive execution.
- Keep the regular integration pool concurrent at its configured limit.
- Run the marked cases one at a time after the concurrent pool completes.
- Keep the change inside the integration executable; it does not alter Linux container runtime behavior or Docker Compose policy.

## Acceptance Criteria

- A full macOS integration run completes the vmnet and IPv6 coverage without concurrent VM lifecycle contention.
- Non-vmnet integration tests retain their existing configurable concurrency.
- The runner continues after a skipped or failed test and preserves its final pass/fail accounting.
- No Docker-shaped CLI or Compose behavior is added to `containerization`.

## Ownership

`containerization` owns its integration runner and Virtualization.framework lifecycle coverage. `container-compose` has no runtime-policy change for this work.

## Validation

```sh
make containerization integration
```

The signed macOS integration executable completed all 166 tests, including the eleven serialized vmnet and IPv6 cases.
