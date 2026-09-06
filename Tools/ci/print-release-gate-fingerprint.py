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

"""Print the Make-derived release fingerprint inside a supervised stage."""

from __future__ import annotations

import hashlib
import os
import re
import subprocess
import sys
from collections.abc import Mapping
from pathlib import Path

ROOT = Path(__file__).parents[2]
ENVIRONMENT_FINGERPRINT = Path(__file__).with_name(
    "fingerprint-release-environment.py"
)
PARITY_STAGE_PATTERN = re.compile(r"docker-compose-([a-z0-9-]+)-parity")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_repository_files(paths: list[Path], root: Path) -> str:
    digest = hashlib.sha256()
    for path in paths:
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"parity fingerprint input is not a regular file: {path}")
        try:
            relative = path.relative_to(root)
        except ValueError as error:
            raise ValueError(
                f"parity fingerprint input escaped the repository: {path}"
            ) from error
        digest.update(relative.as_posix().encode("utf-8"))
        digest.update(b"\0")
        digest.update(sha256_file(path).encode("ascii"))
        digest.update(b"\0")
    return digest.hexdigest()


def parity_scoped_static_fingerprint(
    static_fingerprint: str,
    environment: Mapping[str, str],
    root: Path = ROOT,
) -> str:
    stage = environment.get("RELEASE_GATE_PARITY_STAGE", "")
    binary_selector = environment.get("RELEASE_GATE_PARITY_COMPOSE_BINARY", "")
    if not stage and not binary_selector:
        return static_fingerprint
    if not stage or not binary_selector:
        raise ValueError(
            "RELEASE_GATE_PARITY_STAGE and RELEASE_GATE_PARITY_COMPOSE_BINARY "
            "must be provided together"
        )

    match = PARITY_STAGE_PATTERN.fullmatch(stage)
    if match is None:
        raise ValueError(f"invalid parity checkpoint stage: {stage}")
    stage_script = root / "Tools/parity" / f"check-compose-{match.group(1)}.sh"
    binary = Path(binary_selector)
    if not binary.is_absolute():
        binary = root / binary
    if binary.is_symlink() or not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError(
            f"parity Compose binary is not an executable regular file: {binary}"
        )
    if (
        stage_script.is_symlink()
        or not stage_script.is_file()
        or not os.access(stage_script, os.X_OK)
    ):
        raise ValueError(
            f"parity stage harness is not an executable regular file: {stage_script}"
        )

    compose_tree, separator, remainder = static_fingerprint.partition(":")
    if not separator or not compose_tree.startswith("compose="):
        raise ValueError("static release fingerprint is missing the Compose tree")

    controller_digest = sha256_repository_files(
        [
            root / "Makefile",
            root / "Tools/ci/fingerprint-release-environment.py",
            root / "Tools/ci/print-release-gate-fingerprint.py",
            root / "Tools/ci/run-release-checkpoint.py",
        ],
        root,
    )
    stage_digest = sha256_repository_files([stage_script], root)
    return (
        f"compose-binary={sha256_file(binary)}"
        f":parity-stage={stage}"
        f":parity-harness={stage_digest}"
        f":checkpoint-controller={controller_digest}"
        f":{remainder}"
    )


def output_line(output: str, label: str) -> tuple[int, str | None]:
    lines = [line for line in output.splitlines() if line]
    if len(lines) != 1:
        print(f"{label} must emit exactly one non-empty line", file=sys.stderr)
        return 2, None
    return 0, lines[0]


def run() -> int:
    make = os.environ.get("RELEASE_GATE_MAKE", "make")
    if not make:
        print("RELEASE_GATE_MAKE must not be empty", file=sys.stderr)
        return 2
    try:
        static = subprocess.run(
            [
                make,
                "--no-print-directory",
                "-s",
                "print-release-gate-static-fingerprint",
            ],
            cwd=ROOT,
            check=False,
            stdout=subprocess.PIPE,
            text=True,
        )
    except FileNotFoundError:
        print(f"release fingerprint make was not found: {make}", file=sys.stderr)
        return 127
    except PermissionError:
        print(f"release fingerprint make is not executable: {make}", file=sys.stderr)
        return 126
    if static.returncode != 0:
        return static.returncode
    static_status, static_fingerprint = output_line(
        static.stdout, "static release fingerprint command"
    )
    if static_status != 0:
        return static_status
    assert static_fingerprint is not None
    try:
        static_fingerprint = parity_scoped_static_fingerprint(
            static_fingerprint,
            os.environ,
        )
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 2

    environment = subprocess.run(
        [sys.executable, str(ENVIRONMENT_FINGERPRINT)],
        cwd=ROOT,
        check=False,
        stdout=subprocess.PIPE,
        text=True,
    )
    if environment.returncode != 0:
        return environment.returncode
    environment_status, environment_fingerprint = output_line(
        environment.stdout, "environment fingerprint command"
    )
    if environment_status != 0:
        return environment_status
    assert environment_fingerprint is not None
    print(f"{static_fingerprint}:environment={environment_fingerprint}")
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
