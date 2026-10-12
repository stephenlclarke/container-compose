# Release cache omits parity memory and fixture retention settings

## Problem

The release tool check in [PR 708](https://github.com/stephenlclarke/container-compose/pull/708) fails because the Make release fingerprint omits two defaulted fixture inputs: `PARITY_SERVICE_MEMORY_MIB` and `PARITY_RETAIN_FIXTURE_DIR`. Changing the service memory cap can change the measured workload; changing fixture retention changes the retained evidence. Cached release gates must distinguish these selections.

## Expected behavior

The release fingerprint includes both inputs, and Make passes their selected values to the parity fixtures. Defaults remain zero: uncapped services and disposable fixture files. Each override changes the release fingerprint without changing product source or rebuilding historical baselines.

## Compatibility impact

Contributor workflow and cache admission only. The original parity inventory and assertions remain unchanged. See [the implementation and validation](PR-release-cache-parity-controls.md).
