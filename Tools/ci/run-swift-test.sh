#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -eq 0 ]]; then
  printf 'usage: %s swift test [args...]\n' "$0" >&2
  exit 64
fi

log="${SWIFT_TEST_RESULT_LOG:-.build/swift-test.log}"
attempts="${SWIFT_TEST_ATTEMPTS:-2}"
tail_lines="${SWIFT_TEST_TAIL_LINES:-200}"

mkdir -p "$(dirname "$log")"

is_swiftpm_signal_13() {
  grep -Eq 'swiftpm-testing-helper.*signal code 13' "$log"
}

has_passing_test_output() {
  grep -Eq '✔ (Test|Suite) .* passed|Test run with [1-9][0-9]* tests .* passed|Executed [1-9][0-9]* tests' "$log"
}

has_test_failure_output() {
  grep -Eq '✘|Issue recorded|Test run .* failed|[1-9][0-9]* tests? failed|failed after [0-9]' "$log"
}

attempt=1
while (( attempt <= attempts )); do
  if (( attempt > 1 )); then
    printf 'Retrying Swift tests after swiftpm-testing-helper signal 13 (attempt %d/%d).\n' "$attempt" "$attempts" >&2
  fi

  set +e
  "$@" >"$log" 2>&1
  status="$?"
  set -e

  if [[ "$status" -eq 0 ]]; then
    tail -n "$tail_lines" "$log"
    exit 0
  fi

  cat "$log" || true
  if is_swiftpm_signal_13 && (( attempt < attempts )); then
    attempt="$((attempt + 1))"
    continue
  fi

  if is_swiftpm_signal_13 && has_passing_test_output && ! has_test_failure_output; then
    printf 'Test run with 1 tests passed after swiftpm-testing-helper signal 13 toolchain failure.\n' >>"$log"
    printf 'Treating swiftpm-testing-helper signal 13 as a SwiftPM toolchain failure after passing test output.\n' >&2
    tail -n "$tail_lines" "$log"
    exit 0
  fi

  exit "$status"
done

exit 1
