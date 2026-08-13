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

"""Regression tests for release builds against a local Container stack."""

from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[2]


class BuildReleaseLocalStackTests(unittest.TestCase):
    """`build-release` must preserve the local-stack behavior of `build`."""

    def test_uses_local_overlays_and_restores_package_resolution(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            container = temporary_root / "container"
            containerization = temporary_root / "containerization"
            engine_api = temporary_root / "container-engine-api"

            result = subprocess.run(
                [
                    "make",
                    "-n",
                    f"CONTAINER_PACKAGE_PATH={container}",
                    f"CONTAINERIZATION_PACKAGE_PATH={containerization}",
                    f"CONTAINER_ENGINE_API_PACKAGE_PATH={engine_api}",
                    "build-release",
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f'CONTAINER_PACKAGE_PATH="{container}"', result.stdout)
            self.assertIn(
                f'CONTAINERIZATION_PACKAGE_PATH="{containerization}"', result.stdout
            )
            self.assertIn(
                f'CONTAINER_ENGINE_API_PACKAGE_PATH="{engine_api}"', result.stdout
            )
            self.assertIn('cp Package.resolved "$lock_backup"', result.stdout)
            self.assertIn("trap restore_lock EXIT HUP INT QUIT TERM", result.stdout)
            branch_separator = "else " + chr(92) + "\n"
            local_branch, separator, fallback_branch = result.stdout.partition(
                branch_separator
            )
            self.assertTrue(separator, result.stdout)
            self.assertIn("swift build -c release --product compose", local_branch)
            self.assertNotIn(
                "swift build --disable-automatic-resolution -c release", local_branch
            )
            self.assertIn(
                "swift build --disable-automatic-resolution -c release",
                fallback_branch,
            )

    def test_uses_resolved_remote_dependencies_without_local_overlays(self) -> None:
        result = subprocess.run(
            [
                "make",
                "-n",
                "CONTAINER_PACKAGE_PATH=",
                "CONTAINERIZATION_PACKAGE_PATH=",
                "CONTAINER_ENGINE_API_PACKAGE_PATH=",
                "build-release",
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "swift build --disable-automatic-resolution -c release --product compose",
            result.stdout,
        )


if __name__ == "__main__":
    unittest.main()
