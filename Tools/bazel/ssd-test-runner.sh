#!/usr/bin/env bash
# Copyright 2026 devcontainer project authors. SPDX-License-Identifier: Apache-2.0
# USAGE: ssd-test-runner.sh TEST_EXECUTABLE [ARGS...]
# Give tools a writable per-test TMPDIR. Foundation on Darwin can still prefer
# its system directory, so Swift fixtures must explicitly honour TEST_TMPDIR.
set -euo pipefail

[[ "${TEST_TMPDIR:-}" == /Volumes/SSD/cf/bazel/* && -d "$TEST_TMPDIR" && -w "$TEST_TMPDIR" ]] || {
    printf 'Bazel test requires its own writable SSD temporary directory.\n' >&2
    exit 2
}
TEST_TMPDIR="$(cd "$TEST_TMPDIR" && pwd -P)"
[[ "$TEST_TMPDIR" == /Volumes/SSD/cf/bazel/* && "$(cd /Volumes/SSD/cf/bazel && pwd -P)" == /Volumes/SSD/cf/bazel ]] || {
    printf 'Bazel test scratch resolves outside its enrolled storage.\n' >&2
    exit 2
}
export TEST_TMPDIR
export BAZEL_TEST=1
export TMPDIR="$TEST_TMPDIR" TMP="$TEST_TMPDIR" TEMP="$TEST_TMPDIR"
export DEVCONTAINER_TEST_SCRATCH_ROOT=/Volumes/SSD/cf/bazel/
# The Swift parser tests execute the declared Go binary, never `go run`.
if [[ -n "${COMPOSE_NORMALIZER_RUNFILE:-}" ]]; then
    export CONTAINER_COMPOSE_NORMALIZER="${TEST_SRCDIR:?}/${TEST_WORKSPACE:?}/$COMPOSE_NORMALIZER_RUNFILE"
    [[ -x "$CONTAINER_COMPOSE_NORMALIZER" ]] || { printf 'Missing declared normalizer.\n' >&2; exit 2; }
fi
if "$@"; then
    status=0
else
    status=$?
fi
[[ "$status" == 0 ]] || exit "$status"

# rules_swift instruments Swift but this pinned Bazel tuple does not invoke a
# native LLVM collector. Export the profiles from this execution into the
# standard COVERAGE_DIR; Bazel's existing LCOV merger handles source filtering.
if [[ "${COVERAGE:-0}" == 1 && -n "${TEST_BINARIES_FOR_LLVM_COV:-}" ]]; then
    [[ "${COVERAGE_DIR:-}" == /Volumes/SSD/cf/bazel/* ]] || exit 2
    shopt -s nullglob
    profiles=("$COVERAGE_DIR"/*.profraw)
    if [[ ${#profiles[@]} == 0 ]]; then
        # A framework-only probe has no instrumented production sources.
        [[ ! -s "${COVERAGE_MANIFEST:?}" ]] && exit 0
        printf 'Coverage execution produced no LLVM profiles (binary: %s).\n' "$TEST_BINARIES_FOR_LLVM_COV" >&2
        exit 2
    else
        # The LCOV merger rejects mixed .profdata and .dat input. Keep the
        # intermediate profile in test scratch, outside its discovery tree.
        /usr/bin/xcrun llvm-profdata merge -sparse "${profiles[@]}" -o "$TEST_TMPDIR/swift.profdata"
        /usr/bin/xcrun llvm-cov export -format=lcov \
            -instr-profile="$TEST_TMPDIR/swift.profdata" \
            "$TEST_BINARIES_FOR_LLVM_COV" > "$COVERAGE_DIR/swift.dat"
    fi
fi
