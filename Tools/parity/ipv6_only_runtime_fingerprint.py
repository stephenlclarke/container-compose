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

"""Write and verify exact fingerprints for the IPv6-only runtime certificate."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


SCHEMA = "container-compose.ipv6-only-runtime-fingerprint/v1"


class FingerprintError(RuntimeError):
    """Raised when an input cannot establish a reproducible candidate graph."""


def sha256_file(path: Path) -> str:
    """Return the SHA-256 digest for one regular file."""

    if not path.is_file():
        raise FingerprintError(f"required file is unavailable: {path}")
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git_output(root: Path, *arguments: str) -> bytes:
    """Run Git against one local source checkout or fail with the command context."""

    result = subprocess.run(
        ["git", "-C", str(root), *arguments],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise FingerprintError(
            f"cannot fingerprint Git source {root}: {' '.join(arguments)}: {detail}"
        )
    return result.stdout


def package_dependencies(package_resolved: Path) -> list[dict[str, str | None]]:
    """Return the pinned SwiftPM dependency identities in deterministic order."""

    try:
        payload = json.loads(package_resolved.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise FingerprintError(
            f"invalid Package.resolved in {package_resolved}: {error}"
        ) from error
    pins = payload.get("pins")
    if not isinstance(pins, list):
        raise FingerprintError(f"Package.resolved has no pins array: {package_resolved}")
    dependencies: list[dict[str, str | None]] = []
    for pin in pins:
        if not isinstance(pin, dict) or not isinstance(pin.get("identity"), str):
            raise FingerprintError(f"Package.resolved has an invalid pin: {package_resolved}")
        state = pin.get("state")
        if not isinstance(state, dict):
            raise FingerprintError(
                f"Package.resolved pin has no state: {package_resolved}:{pin['identity']}"
            )
        dependencies.append(
            {
                "identity": pin["identity"],
                "kind": pin.get("kind") if isinstance(pin.get("kind"), str) else None,
                "location": (
                    pin.get("location") if isinstance(pin.get("location"), str) else None
                ),
                "revision": (
                    state.get("revision")
                    if isinstance(state.get("revision"), str)
                    else None
                ),
                "version": (
                    state.get("version") if isinstance(state.get("version"), str) else None
                ),
            }
        )
    return sorted(dependencies, key=lambda dependency: dependency["identity"] or "")


def source_fingerprint(path: Path) -> dict[str, Any]:
    """Return the exact source and dependency state of one local checkout."""

    root = path.resolve()
    if not (root / ".git").exists():
        raise FingerprintError(f"required local Git source is unavailable: {root}")
    package_resolved = root / "Package.resolved"
    if not package_resolved.is_file():
        raise FingerprintError(f"required Package.resolved is unavailable: {package_resolved}")
    untracked = git_output(root, "ls-files", "--others", "--exclude-standard")
    untracked_digest = hashlib.sha256()
    for relative_path in untracked.decode("utf-8").splitlines():
        candidate = root / relative_path
        untracked_digest.update(relative_path.encode("utf-8") + b"\0")
        if candidate.is_file():
            untracked_digest.update(candidate.read_bytes())
    return {
        "path": str(root),
        "head": git_output(root, "rev-parse", "HEAD").decode("utf-8").strip(),
        "tracked_diff_sha256": hashlib.sha256(
            git_output(root, "diff", "--binary", "HEAD")
        ).hexdigest(),
        "untracked_sha256": untracked_digest.hexdigest(),
        "package_resolved_sha256": sha256_file(package_resolved),
        "dependencies": package_dependencies(package_resolved),
    }


def parse_assignments(values: list[str], kind: str) -> dict[str, Path]:
    """Parse stable `role=path` command-line input without ambiguous duplicates."""

    parsed: dict[str, Path] = {}
    for value in values:
        role, separator, raw_path = value.partition("=")
        if not separator or not role or not raw_path:
            raise FingerprintError(f"invalid {kind} assignment: {value!r}")
        if role in parsed:
            raise FingerprintError(f"duplicate {kind} role: {role}")
        parsed[role] = Path(raw_path).resolve()
    return dict(sorted(parsed.items()))


def binary_fingerprint(path: Path) -> dict[str, Any]:
    """Return a digest and size for an exact executable input."""

    if not path.is_file() or not path.stat().st_mode & 0o111:
        raise FingerprintError(f"required executable is unavailable: {path}")
    return {
        "path": str(path),
        "sha256": sha256_file(path),
        "size": path.stat().st_size,
    }


def read_required_output(path: Path, description: str) -> str:
    """Read non-empty captured command output retained by the Bash harness."""

    if not path.is_file():
        raise FingerprintError(f"{description} capture is unavailable: {path}")
    content = path.read_text(encoding="utf-8")
    if not content.strip():
        raise FingerprintError(f"{description} capture is empty: {path}")
    return content


def parse_system_status(path: Path) -> dict[str, str]:
    """Extract stable API-service identity fields from `container system status`."""

    fields: dict[str, str] = {}
    for line in read_required_output(path, "container system status").splitlines():
        match = re.match(r"^([A-Za-z0-9_.-]+)\s{2,}(.+)$", line)
        if match:
            fields[match.group(1)] = match.group(2)
    required_fields = ("apiserver.commit", "apiserver.version")
    missing = [field for field in required_fields if not fields.get(field)]
    if missing:
        raise FingerprintError(
            f"container system status lacks required identity fields: {', '.join(missing)}"
        )
    return {field: fields[field] for field in sorted(fields) if field.startswith("apiserver.")}


def assert_runtime_matches_sources(
    sources: dict[str, dict[str, Any]], status_fields: dict[str, str]
) -> None:
    """Fail closed unless the running API service identifies the selected sources."""

    container_head = sources.get("container", {}).get("head")
    containerization_head = sources.get("containerization", {}).get("head")
    if not isinstance(container_head, str) or not isinstance(containerization_head, str):
        raise FingerprintError("container and containerization sources are required")
    if status_fields["apiserver.commit"] != container_head:
        raise FingerprintError(
            "running API-server commit does not match the selected Container source"
        )
    if containerization_head not in status_fields["apiserver.version"]:
        raise FingerprintError(
            "running API-server version does not identify the selected Containerization source"
        )


def test_root_fingerprint(root: Path, marker_name: str, marker_value: str) -> dict[str, str]:
    """Validate the disposable-root ownership marker before writing evidence."""

    marker = root.resolve() / marker_name
    if not marker.is_file():
        raise FingerprintError(f"test root ownership marker is unavailable: {marker}")
    if marker.read_text(encoding="utf-8").rstrip("\n") != marker_value:
        raise FingerprintError(f"test root ownership marker is invalid: {marker}")
    return {"path": str(root.resolve()), "marker_sha256": sha256_file(marker)}


def build_fingerprint(arguments: argparse.Namespace) -> dict[str, Any]:
    """Build the immutable portion shared by preflight and completion records."""

    source_paths = parse_assignments(arguments.source, "source")
    binary_paths = parse_assignments(arguments.binary, "binary")
    sources = {
        role: source_fingerprint(path) for role, path in source_paths.items()
    }
    binaries = {
        role: binary_fingerprint(path) for role, path in binary_paths.items()
    }
    status_fields = parse_system_status(Path(arguments.system_status))
    assert_runtime_matches_sources(sources, status_fields)
    guest_image_capture = Path(arguments.guest_image_inspect)
    read_required_output(guest_image_capture, "guest init image inspection")
    compose_version = Path(arguments.compose_version)
    container_version = Path(arguments.container_version)
    return {
        "sources": sources,
        "binaries": binaries,
        "compose_version_sha256": sha256_file(compose_version),
        "container_version_sha256": sha256_file(container_version),
        "guest_init_image": {
            "name": arguments.guest_image_name,
            "inspect_sha256": sha256_file(guest_image_capture),
        },
        "runtime": {"apiserver": status_fields},
        "builder_reference": arguments.builder_reference,
        "test_root": test_root_fingerprint(
            Path(arguments.test_root),
            arguments.root_marker_name,
            arguments.root_marker_value,
        ),
    }


def write_json(path: Path, payload: dict[str, Any]) -> None:
    """Atomically write one new deterministic evidence record."""

    if path.exists():
        raise FingerprintError(f"refusing to overwrite fingerprint evidence: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def parse_arguments(arguments: list[str]) -> argparse.Namespace:
    """Parse the narrow fingerprint-writer command line."""

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--phase", required=True, choices=("preflight", "complete"))
    parser.add_argument("--preflight", type=Path)
    parser.add_argument("--candidate-status", choices=("passed",))
    parser.add_argument("--source", action="append", default=[], required=True)
    parser.add_argument("--binary", action="append", default=[], required=True)
    parser.add_argument("--compose-version", required=True)
    parser.add_argument("--container-version", required=True)
    parser.add_argument("--guest-image-name", required=True)
    parser.add_argument("--guest-image-inspect", required=True)
    parser.add_argument("--system-status", required=True)
    parser.add_argument("--builder-reference", required=True)
    parser.add_argument("--test-root", required=True)
    parser.add_argument("--root-marker-name", required=True)
    parser.add_argument("--root-marker-value", required=True)
    parsed = parser.parse_args(arguments)
    if parsed.phase == "preflight" and (parsed.preflight or parsed.candidate_status):
        parser.error("preflight records cannot declare a prior fingerprint or candidate status")
    if parsed.phase == "complete" and (
        parsed.preflight is None or parsed.candidate_status != "passed"
    ):
        parser.error("completion records require --preflight and --candidate-status passed")
    return parsed


def main(arguments: list[str]) -> int:
    """Write a preflight record or prove an unchanged successful completion."""

    parsed = parse_arguments(arguments)
    try:
        fingerprint = build_fingerprint(parsed)
        payload: dict[str, Any] = {
            "schema": SCHEMA,
            "phase": parsed.phase,
            "fingerprint": fingerprint,
        }
        if parsed.phase == "complete":
            assert parsed.preflight is not None
            try:
                preflight = json.loads(parsed.preflight.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as error:
                raise FingerprintError(
                    f"cannot read preflight fingerprint: {parsed.preflight}: {error}"
                ) from error
            if (
                preflight.get("schema") != SCHEMA
                or preflight.get("phase") != "preflight"
                or preflight.get("fingerprint") != fingerprint
            ):
                raise FingerprintError(
                    "completion fingerprint does not match its exact preflight inputs"
                )
            payload["preflight_sha256"] = sha256_file(parsed.preflight)
            payload["candidate_status"] = parsed.candidate_status
        write_json(parsed.output, payload)
    except FingerprintError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
