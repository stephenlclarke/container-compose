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

"""Validate checked-in stack release metadata against lockfiles."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
STACK_REFS = ROOT / "Tools" / "release" / "stack-refs.json"
CONTAINER_PACKAGE = ROOT.parent / "container" / "Package.swift"
PACKAGE_SWIFT_FILES = [
    ROOT / "Package.swift",
    CONTAINER_PACKAGE,
]
PACKAGE_RESOLVED_FILES = [
    ROOT / "Package.resolved",
    ROOT.parent / "container" / "Package.resolved",
]


def load_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise SystemExit(f"missing required file: {path}") from error
    except json.JSONDecodeError as error:
        raise SystemExit(f"invalid JSON in {path}: {error}") from error


def normalize_repository(location: str) -> str:
    if location.startswith("https://github.com/"):
        location = location.removeprefix("https://github.com/")
    return location.removesuffix(".git")


def containerization_pins() -> list[tuple[Path, dict[str, Any]]]:
    pins: list[tuple[Path, dict[str, Any]]] = []
    for path in PACKAGE_RESOLVED_FILES:
        if not path.exists():
            continue
        data = load_json(path)
        for pin in data.get("pins", []):
            if pin.get("identity") == "containerization":
                pins.append((path, pin))
    return pins


def containerization_dependencies() -> list[tuple[Path, str, str, str]]:
    dependencies: list[tuple[Path, str, str, str]] = []
    pattern = re.compile(
        r'\.package\(\s*url:\s*"([^"]*containerization\.git)"\s*,\s*'
        r'(branch|revision|exact|from):\s*"([^"]*)"',
        re.MULTILINE,
    )
    for path in PACKAGE_SWIFT_FILES:
        try:
            text = path.read_text(encoding="utf-8")
        except FileNotFoundError as error:
            raise SystemExit(f"missing required file: {path}") from error
        match = pattern.search(text)
        if not match:
            raise SystemExit(f"{path} is missing a containerization package dependency")
        dependencies.append((path, match.group(1), match.group(2), match.group(3)))
    return dependencies


def require_match(label: str, actual: str, expected: str) -> None:
    if actual != expected:
        raise SystemExit(f"{label} mismatch: expected {expected}, got {actual}")


def read_swift_default(path: Path, name: str) -> str:
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError as error:
        raise SystemExit(f"missing required file: {path}") from error
    match = re.search(rf'let {name} = .*?\?\? "([^"]*)"', text)
    if not match:
        raise SystemExit(f"{path} is missing {name} default")
    return match.group(1)


def validate_builder_image(stack_refs: dict[str, Any]) -> None:
    components = stack_refs.get("components", {})
    builder = components.get("container-builder-shim")
    if not isinstance(builder, dict):
        raise SystemExit("stack-refs.json is missing components.container-builder-shim")
    image = builder.get("image")
    if not isinstance(image, dict):
        raise SystemExit("stack-refs.json container-builder-shim entry needs image metadata")

    expected_repository = str(image.get("repository", ""))
    expected_tag = str(image.get("tag", ""))
    expected_digest = str(image.get("digest", ""))
    if not expected_repository or not expected_tag or not expected_digest:
        raise SystemExit("stack-refs.json container-builder-shim image needs repository, tag, and digest")

    require_match(
        "container Package.swift builder repository",
        read_swift_default(CONTAINER_PACKAGE, "builderShimRepository"),
        expected_repository,
    )
    require_match(
        "container Package.swift builder tag",
        read_swift_default(CONTAINER_PACKAGE, "builderShimVersion"),
        expected_tag,
    )
    require_match(
        "container Package.swift builder digest",
        read_swift_default(CONTAINER_PACKAGE, "builderShimDigest"),
        expected_digest,
    )


def main() -> int:
    stack_refs = load_json(STACK_REFS)
    validate_builder_image(stack_refs)
    components = stack_refs.get("components", {})
    containerization = components.get("containerization")
    if not isinstance(containerization, dict):
        raise SystemExit("stack-refs.json is missing components.containerization")

    expected_source = str(containerization.get("repository", ""))
    expected_ref = str(containerization.get("ref", ""))
    if not expected_source or not expected_ref:
        raise SystemExit("stack-refs.json containerization entry needs repository and ref")

    for path, location, requirement, value in containerization_dependencies():
        source = normalize_repository(location)
        require_match(f"{path} containerization source", source, expected_source)
        if requirement != "revision":
            raise SystemExit(
                f"{path} containerization dependency must use revision, not {requirement}"
            )
        require_match(f"{path} containerization revision", value, expected_ref)

    pins = containerization_pins()
    if not pins:
        raise SystemExit("no checked-in Package.resolved contains a containerization pin")

    for path, pin in pins:
        source = normalize_repository(str(pin.get("location", "")))
        state = pin.get("state", {})
        revision = str(state.get("revision", ""))
        if "branch" in state:
            raise SystemExit(f"{path} containerization pin must not include a branch")
        require_match(f"{path} containerization source", source, expected_source)
        require_match(f"{path} containerization revision", revision, expected_ref)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
