<!-- markdownlint-disable MD013 -->

# fix(test): set the active SDK for prebuilt XCTest parity runs

## Problem and behavior

The retained prebuilt Core XCTest runner failed before its selected tests ran because `SDKROOT` was unset. The parity runner now resolves the macOS SDK from the active `DEVELOPER_DIR` or `xcode-select` selection, confirms `xcrun` returns an SDK beneath that developer directory, and supplies it to each selected prebuilt test process. An unavailable or mismatched SDK fails closed; no binary rebuild or filter skip is introduced.

## Changes

- Add a strict SDK resolver using `/usr/bin/xcode-select` and `/usr/bin/xcrun`.
- Set `SDKROOT` in the per-test environment while preserving caller-provided parity variables.
- Add deterministic tests for SDK discovery, invalid-path rejection, and environment propagation.

## Validation

The focused `Tools/bazel/test_prebuilt_parity_tests.py` suite passes seven tests. Python bytecode compilation for the two touched Python files and `git diff --check` pass. The original optimized runner failure executed no unit test cases. The corrected prebuilt CLI ran the original signal filter (18 Core and 1 Plugin tests) and lifecycle filter (20 Core tests), with the host restored and no rebuild or VM started; proof is retained at `candidate-compose-attached-output/prebuilt-filter-preflight-v2/acceptance.json` in the current performance evidence root. The instrumented offline proof at `prebuilt-sdk-unit-v1/receipt.json` records 56/65 statements (86.1538%) and 17/22 branches (77.2727%) for the whole helper. The new SDK resolver has one uncovered invalid-SDK-shape failure line; CLI entry and existing error paths remain an explicit coverage follow-up. No 90% whole-helper coverage claim is made. Complete live semantic fixtures remain separate qualification. No build, VM, or runtime workload is part of this change.

## Compatibility and risks

The runner uses the SDK selected by the host's active developer directory, including an explicit `DEVELOPER_DIR` when supplied. It rejects command-line-tools/Xcode mismatches rather than selecting another installed SDK. The test binaries and original test filters are unchanged.
