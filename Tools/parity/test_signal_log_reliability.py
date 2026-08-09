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

"""Focused tests for the Compose signal and logging reliability harness."""

from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).parents[2]
HARNESS = REPOSITORY / "Tools" / "parity" / "check-compose-signal-log-reliability.sh"


class ScaledIdentifierTests(unittest.TestCase):
    def test_accepts_complete_docker_and_container_compose_hostnames(self) -> None:
        for identifiers in (
            ("01ab", "02cd", "03ef"),
            (
                "cc-sl-a-demo-scaled-log-1",
                "cc-sl-a-demo-scaled-log-2",
                "cc-sl-a-demo-scaled-log-3",
            ),
        ):
            with self.subTest(identifiers=identifiers):
                result = self.run_assertion(identifiers, identifiers)

            self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_duplicate_complete_hostnames(self) -> None:
        identifiers = ("cc-sl-a-demo-scaled-log-1",) * 3

        result = self.run_assertion(identifiers, identifiers)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected 3 unique", result.stderr)

    def run_assertion(
        self,
        foreground_identifiers: tuple[str, ...],
        history_identifiers: tuple[str, ...],
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory(prefix="compose-scale-identifiers-") as directory:
            root = Path(directory)
            foreground = root / "foreground.log"
            history = root / "history.log"
            foreground.write_text(
                "".join(f"SCALE:{value}\n" for value in foreground_identifiers),
                encoding="utf-8",
            )
            history.write_text(
                "".join(f"SCALE:{value}\n" for value in history_identifiers),
                encoding="utf-8",
            )
            return subprocess.run(
                [
                    "bash",
                    "-c",
                    'source "$1"; assert_scaled_identifiers test "$2" "$3"',
                    "_",
                    HARNESS,
                    foreground,
                    history,
                ],
                cwd=REPOSITORY,
                capture_output=True,
                check=False,
                text=True,
            )


class MatchedPackagePathTests(unittest.TestCase):
    def test_make_target_passes_the_local_engine_api_package(self) -> None:
        result = subprocess.run(
            [
                "make",
                "--dry-run",
                "docker-compose-signal-log-reliability-parity",
                "CONTAINER_ENGINE_API_STACK_REPO=/tmp/matched-engine-api",
                "CONTAINER_ENGINE_API_PACKAGE_PATH=/tmp/matched-engine-api",
                "PARITY_CONTAINER_ENGINE_API_REF=fixture-engine-api-ref",
            ],
            cwd=REPOSITORY,
            capture_output=True,
            check=False,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            'CONTAINER_ENGINE_API_PACKAGE_PATH="/tmp/matched-engine-api"',
            result.stdout,
        )
        self.assertIn(
            'CONTAINER_ENGINE_API_REF="fixture-engine-api-ref"',
            result.stdout,
        )
        self.assertIn(
            'CONTAINER_ENGINE_API_STACK_REPO="/tmp/matched-engine-api"',
            result.stdout,
        )


if __name__ == "__main__":
    unittest.main()
