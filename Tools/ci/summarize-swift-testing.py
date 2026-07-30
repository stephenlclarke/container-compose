#!/usr/bin/env python3
##===----------------------------------------------------------------------===##
## Copyright © 2026 container-compose project authors.
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
##
##   https://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.
##===----------------------------------------------------------------------===##

"""Report explicit executed and skipped counts from Swift Testing output."""

import argparse
import re
from pathlib import Path


TEST_RUN_PATTERN = re.compile(r"^[✔✘] Test run with ([0-9]+) tests?\b")
EXECUTED_TEST_PATTERN = re.compile(r'^[✔✘] Test ".*" (?:passed|failed)\b')
SKIPPED_TEST_PATTERN = re.compile(r'^➜ Test ".*" skipped:')


def testing_counts(log: str) -> tuple[int, int]:
    """Return executed and skipped counts from one Swift test log."""
    total = None
    executed_events = 0
    skipped = 0
    for line in log.splitlines():
        if match := TEST_RUN_PATTERN.match(line):
            total = int(match.group(1))
        if EXECUTED_TEST_PATTERN.match(line):
            executed_events += 1
        if SKIPPED_TEST_PATTERN.match(line):
            skipped += 1

    if total is None:
        return executed_events, skipped
    if skipped > total:
        raise ValueError(
            f"Swift Testing reported {skipped} skipped tests from {total} discovered tests"
        )
    return total - skipped, skipped


def main() -> int:
    """Read one Swift Testing log and print its evidence summary."""
    parser = argparse.ArgumentParser(
        description="Summarize executed and explicitly skipped Swift tests."
    )
    parser.add_argument("log", type=Path)
    args = parser.parse_args()

    executed, skipped = testing_counts(args.log.read_text(encoding="utf-8"))
    print(f"Swift Testing evidence: executed={executed} skipped={skipped}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
