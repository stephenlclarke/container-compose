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

"""Resolve the containerization package pin for release metadata."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


DEFAULT_RESOLVED_FILES = [Path("Package.resolved"), Path("../container/Package.resolved")]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--field", choices=("source", "ref"), required=True)
    parser.add_argument("--identity", default="containerization")
    parser.add_argument(
        "--resolved",
        action="append",
        type=Path,
        help="Package.resolved file to inspect; may be supplied more than once.",
    )
    return parser.parse_args()


def load_pin(path: Path, identity: str) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    for pin in data.get("pins", []):
        if pin.get("identity") == identity:
            return pin
    return None


def first_pin(paths: list[Path], identity: str) -> dict[str, Any] | None:
    for path in paths:
        pin = load_pin(path, identity)
        if pin is not None:
            return pin
    return None


def source_value(pin: dict[str, Any] | None) -> str:
    if pin is None:
        return "unspecified"
    location = str(pin.get("location") or "unspecified")
    if location.startswith("https://github.com/"):
        location = location.removeprefix("https://github.com/")
    return location.removesuffix(".git")


def ref_value(pin: dict[str, Any] | None) -> str:
    if pin is None:
        return "unspecified"
    state = pin.get("state") or {}
    return str(state.get("revision") or state.get("branch") or state.get("version") or "unspecified")


def resolved_paths(paths: list[Path] | None) -> list[Path]:
    return paths if paths else DEFAULT_RESOLVED_FILES


def main() -> int:
    args = parse_args()
    pin = first_pin(resolved_paths(args.resolved), args.identity)
    if args.field == "source":
        print(source_value(pin))
    else:
        print(ref_value(pin))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
