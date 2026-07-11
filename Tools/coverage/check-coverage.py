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

"""Check Swift and Go coverage reports against the required minimum."""

import argparse
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def generic_line_coverage(path: Path) -> float:
    """Return line coverage from SonarQube generic coverage XML."""
    covered = 0
    total = 0
    root = ET.parse(path).getroot()
    for line in root.findall(".//lineToCover"):
        total += 1
        if line.attrib.get("covered") == "true":
            covered += 1
    return percentage(covered, total)


def go_statement_coverage(path: Path) -> float:
    """Return statement coverage from a Go coverage profile."""
    blocks: dict[tuple[str, int], int] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        if raw_line.startswith("mode:"):
            continue
        fields = raw_line.split()
        if len(fields) != 3:
            continue
        statements = int(fields[1])
        count = int(fields[2])
        key = (fields[0], statements)
        blocks[key] = max(blocks.get(key, 0), count)
    total = sum(statements for _, statements in blocks)
    covered = sum(
        statements for (_, statements), count in blocks.items() if count > 0
    )
    return percentage(covered, total)


def percentage(covered: int, total: int) -> float:
    """Calculate a percentage, treating an empty report as uncovered."""
    if total == 0:
        return 0.0
    return covered * 100.0 / total


def check(name: str, actual: float, minimum: float) -> bool:
    """Print one coverage result and report whether it meets the threshold."""
    print(f"{name} coverage: {actual:.2f}%")
    if actual + 1e-9 < minimum:
        print(f"{name} coverage is below required {minimum:.2f}%", file=sys.stderr)
        return False
    return True


def main() -> int:
    """Parse arguments and check all configured coverage reports."""
    parser = argparse.ArgumentParser(description="Check generated coverage reports.")
    parser.add_argument("--swift-minimum", type=float, default=90.0)
    parser.add_argument("--go-minimum", type=float, default=85.0)
    parser.add_argument("--swift", type=Path, required=True)
    parser.add_argument("--go", type=Path, required=True)
    args = parser.parse_args()

    ok = True
    ok = check("Swift", generic_line_coverage(args.swift), args.swift_minimum) and ok
    ok = check("Go", go_statement_coverage(args.go), args.go_minimum) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
