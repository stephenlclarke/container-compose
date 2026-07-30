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

"""Reject Apple package dependencies and imports from ComposeCore and its SPI."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Sequence


ALLOWED_DEPENDENCIES = {
    "ComposeCore": {"ComposeRuntimeSPI"},
    "ComposeRuntimeSPI": set(),
}
APPLE_IMPORT = re.compile(
    r"^\s*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s+)*"
    r"(?:(?:public|package|internal|private|fileprivate)\s+)?"
    r"import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?"
    r"(Container[A-Za-z0-9_]*)\b",
)


def dependency_name(dependency: dict[str, Any]) -> str:
    for kind in ("byName", "product", "target"):
        value = dependency.get(kind)
        if isinstance(value, list) and value:
            return str(value[0])
    return json.dumps(dependency, sort_keys=True)


def package_dependency_errors(package: dict[str, Any]) -> list[str]:
    failures: list[str] = []
    for name, allowed in ALLOWED_DEPENDENCIES.items():
        targets = [
            target
            for target in package.get("targets", [])
            if target.get("name") == name
        ]
        if len(targets) != 1:
            failures.append(f"expected one {name} target, found {len(targets)}")
            continue
        dependencies = {
            dependency_name(dependency)
            for dependency in targets[0].get("dependencies", [])
        }
        if dependencies != allowed:
            failures.append(
                f"{name} dependencies must be exactly "
                f"{sorted(allowed)}, found {sorted(dependencies)}"
            )
    return failures


def forbidden_imports(source_root: Path) -> list[str]:
    failures: list[str] = []
    for source in sorted(source_root.rglob("*.swift")):
        for line_number, line in enumerate(
            source.read_text(encoding="utf-8").splitlines(),
            start=1,
        ):
            match = APPLE_IMPORT.match(line)
            if match:
                failures.append(
                    f"{source}:{line_number}: forbidden Apple import {match.group(1)}"
                )
    return failures


def dump_package(root: Path, swift: str) -> dict[str, Any]:
    result = subprocess.run(
        [swift, "package", "dump-package"],
        cwd=root,
        capture_output=True,
        check=False,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "swift package dump-package failed")
    return json.loads(result.stdout)


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repository",
        type=Path,
        default=Path(__file__).resolve().parents[2],
    )
    parser.add_argument("--swift", default="swift")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    root = args.repository.resolve()
    try:
        failures = package_dependency_errors(dump_package(root, args.swift))
    except (OSError, RuntimeError, json.JSONDecodeError) as error:
        print(f"core runtime-neutrality check failed: {error}", file=sys.stderr)
        return 2
    failures.extend(forbidden_imports(root / "Sources" / "ComposeCore"))
    failures.extend(forbidden_imports(root / "Sources" / "ComposeRuntimeSPI"))
    if failures:
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1
    print("ComposeCore and ComposeRuntimeSPI runtime-neutrality check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
