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

import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).parents[2]
ENVIRONMENT_FINGERPRINT = Path(__file__).with_name(
    "fingerprint-release-environment.py"
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
    assert static_fingerprint is not None
    assert environment_fingerprint is not None
    print(f"{static_fingerprint}:environment={environment_fingerprint}")
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
