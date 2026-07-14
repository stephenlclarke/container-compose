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
import os
import re
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
STACK_REFS = ROOT / "Tools" / "release" / "stack-refs.json"
CONTAINER_REPO = Path(os.environ.get("CONTAINER_STACK_REPO", ROOT.parent / "container"))
CONTAINER_PACKAGE = CONTAINER_REPO / "Package.swift"
COMPOSE_PACKAGE = ROOT / "Package.swift"
COMPOSE_RESOLVED = ROOT / "Package.resolved"
PACKAGE_SWIFT_FILES = [
    COMPOSE_PACKAGE,
]
if CONTAINER_PACKAGE.is_file():
    PACKAGE_SWIFT_FILES.append(CONTAINER_PACKAGE)
PACKAGE_RESOLVED_FILES = [ROOT / "Package.resolved", CONTAINER_REPO / "Package.resolved"]


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


def container_dependency() -> tuple[str, str, str]:
    """Return the Compose runtime dependency source, requirement, and revision."""
    package = COMPOSE_PACKAGE
    try:
        text = package.read_text(encoding="utf-8")
    except FileNotFoundError as error:
        raise SystemExit(f"missing required file: {package}") from error

    match = re.search(
        r'\.package\(\s*url:\s*"([^"]*container\.git)"\s*,\s*'
        r'(branch|revision|exact|from):\s*"([^"]*)"',
        text,
        re.MULTILINE,
    )
    if not match:
        raise SystemExit(f"{package} is missing a remote container package dependency")
    return match.group(1), match.group(2), match.group(3)


def container_pin() -> dict[str, Any]:
    package_resolved = COMPOSE_RESOLVED
    data = load_json(package_resolved)
    for pin in data.get("pins", []):
        if pin.get("identity") == "container":
            return pin
    raise SystemExit(f"{package_resolved} is missing a container pin")


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
    # A standalone Compose checkout does not need a sibling container source
    # tree. The container repository validates its own builder image pin during
    # the full stack gate; validate it here when that checkout is available.
    if not CONTAINER_PACKAGE.is_file():
        return

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
    container = components.get("container")
    if not isinstance(container, dict):
        raise SystemExit("stack-refs.json is missing components.container")

    expected_container_source = str(container.get("repository", ""))
    expected_container_ref = str(container.get("ref", ""))
    if not expected_container_source or not expected_container_ref:
        raise SystemExit("stack-refs.json container entry needs repository and ref")

    container_location, container_requirement, container_revision = container_dependency()
    require_match(
        "Package.swift container source",
        normalize_repository(container_location),
        expected_container_source,
    )
    if container_requirement != "revision":
        raise SystemExit(
            "Package.swift container dependency must use revision, "
            f"not {container_requirement}"
        )
    require_match("Package.swift container revision", container_revision, expected_container_ref)

    pin = container_pin()
    pin_source = normalize_repository(str(pin.get("location", "")))
    pin_state = pin.get("state", {})
    pin_revision = str(pin_state.get("revision", ""))
    if "branch" in pin_state:
        raise SystemExit("Package.resolved container pin must not include a branch")
    require_match("Package.resolved container source", pin_source, expected_container_source)
    require_match("Package.resolved container revision", pin_revision, expected_container_ref)

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
