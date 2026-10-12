<!-- markdownlint-disable MD013 -->

# Supply the active macOS SDK to prebuilt XCTest runners

## Problem

The retained prebuilt Core XCTest runner stopped before executing its selected tests because XCTest could not locate the macOS SDK. The already-built test binary requires `SDKROOT`; the parity runner passed test filters and runfiles but omitted that environment variable.

## Expected behavior

Resolve the active developer directory from `DEVELOPER_DIR` or `xcode-select -p`, ask `xcrun` for its macOS SDK, verify the resolved SDK is a macOS SDK inside that developer directory, and pass that exact path as `SDKROOT` to each prebuilt XCTest process. Missing or inconsistent SDK configuration must fail before running a test binary. The runner must not rebuild binaries, select an arbitrary fallback SDK, or skip a requested test filter.

## Validation

The original optimized failure and the corrected focused source proof are retained under the current Compose candidate evidence. The focused tests verify active SDK resolution, reject a missing or out-of-directory SDK, and assert that the selected SDK reaches the prebuilt process environment. Live prebuilt fixture execution remains a separate qualification step.

See [the implementation handoff](PR-prebuilt-xctest-sdkroot.md).
