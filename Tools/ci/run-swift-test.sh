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
  if grep -Eq 'swiftpm-testing-helper.*signal code 13' "$log" && (( attempt < attempts )); then
    attempt="$((attempt + 1))"
    continue
  fi

  exit "$status"
done

exit 1
