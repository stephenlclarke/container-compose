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

    def test_uses_recoverable_local_stack_session(self) -> None:
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
            self.assertIn(f'--container "{container}"', result.stdout)
            self.assertIn(
                f'--containerization "{containerization}"', result.stdout
            )
            self.assertIn(
                f'--engine-api "{engine_api}"', result.stdout
            )
            self.assertIn("Tools/ci/run-with-local-swift-stack.py", result.stdout)
            self.assertIn("--retain-edits", result.stdout)
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
        self.assertIn("Tools/ci/run-with-local-swift-stack.py", result.stdout)

    def test_clean_restores_local_stack_before_removing_products(self) -> None:
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")

        self.assertIn("local-swift-stack-clean:\n", makefile)
        self.assertIn("--cleanup", makefile)
        self.assertIn("clean: local-swift-stack-clean\n", makefile)

    def test_full_parity_uses_the_release_compose_binary(self) -> None:
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        parity = makefile[
            makefile.index("docker-compose-parity:") : makefile.index(
                "docker-compose-parity-stages:"
            )
        ]

        self.assertTrue(
            parity.startswith(
                "docker-compose-parity: build-release release-parity-build-info "
                "container-stack-build-if-needed docker-compose-reference"
            ),
            parity,
        )
        self.assertIn(
            'CONTAINER_COMPOSE="$(RELEASE_PARITY_COMPOSE_BINARY)"', parity
        )
        self.assertIn(
            'CONTAINER_COMPOSE_BUILD_INFO="$(RELEASE_PARITY_BUILD_INFO)"', parity
        )

        build_info = makefile[
            makefile.index("release-parity-build-info:") : makefile.index(
                "\nrun:", makefile.index("release-parity-build-info:")
            )
        ]
        self.assertIn('--commit "$(CONTAINER_COMPOSE_COMMIT)"', build_info)
        self.assertIn('--container-ref "$(PARITY_CONTAINER_REF)"', build_info)
        self.assertIn(
            '--containerization-ref "$(PARITY_CONTAINERIZATION_REF)"', build_info
        )


if __name__ == "__main__":
    unittest.main()
