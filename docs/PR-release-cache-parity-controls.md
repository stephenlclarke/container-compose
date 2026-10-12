# fix(release): fingerprint parity memory and fixture retention settings

## Problem and behavior

The existing release tool check finds two missing parity inputs in the release cache key. This change gives both inputs their existing fixture defaults, fingerprints them, and forwards their selected values through the common parity environment.

## Validation

The existing defaulted-input regression fails before the fix. The focused release fingerprint test covers changes to the memory cap and fixture retention setting, alongside the existing archive and parity controls. Validation results are retained separately from current runtime and benchmark receipts; this change does not relabel those receipts or require historical benchmark execution.

## Compatibility and risks

Zero remains the default for both settings. No executable, dependency, runtime fixture or parity assertion changes. The release cache rejects results captured with different selected settings. Related: [the issue](ISSUE-release-cache-parity-controls.md) and [PR 708](https://github.com/stephenlclarke/container-compose/pull/708).
