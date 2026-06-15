#!/usr/bin/env python3

import argparse
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def generic_line_coverage(path: Path) -> float:
    covered = 0
    total = 0
    root = ET.parse(path).getroot()
    for line in root.findall(".//lineToCover"):
        total += 1
        if line.attrib.get("covered") == "true":
            covered += 1
    return percentage(covered, total)


def go_statement_coverage(path: Path) -> float:
    covered = 0
    total = 0
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        if raw_line.startswith("mode:"):
            continue
        fields = raw_line.split()
        if len(fields) != 3:
            continue
        statements = int(fields[1])
        count = int(fields[2])
        total += statements
        if count > 0:
            covered += statements
    return percentage(covered, total)


def percentage(covered: int, total: int) -> float:
    if total == 0:
        return 100.0
    return covered * 100.0 / total


def check(name: str, actual: float, minimum: float) -> bool:
    print(f"{name} coverage: {actual:.2f}%")
    if actual + 1e-9 < minimum:
        print(f"{name} coverage is below required {minimum:.2f}%", file=sys.stderr)
        return False
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description="Check generated coverage reports.")
    parser.add_argument("--minimum", type=float, default=85.0)
    parser.add_argument("--swift", type=Path, required=True)
    parser.add_argument("--go", type=Path, required=True)
    args = parser.parse_args()

    ok = True
    ok = check("Swift", generic_line_coverage(args.swift), args.minimum) and ok
    ok = check("Go", go_statement_coverage(args.go), args.minimum) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
