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

"""Focused regression tests for commit-parity operation deadlines."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "Tools" / "parity" / "check-compose-commit.sh"


class CheckComposeCommitTests(unittest.TestCase):
    def test_invalid_timeout_fails_before_prerequisite_checks(self) -> None:
        environment = os.environ.copy()
        environment["PARITY_TIMEOUT_SECONDS"] = "invalid"

        completed = subprocess.run(
            [str(SCRIPT), "--strict"],
            cwd=REPO_ROOT,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(completed.returncode, 2)
        self.assertIn(
            "PARITY_TIMEOUT_SECONDS must be a positive integer: invalid",
            completed.stderr,
        )

    def test_blocked_build_is_terminated_at_operation_deadline(self) -> None:
        true_binary = shutil.which("true")
        self.assertIsNotNone(true_binary)
        with tempfile.TemporaryDirectory(prefix="compose-commit-deadline.") as directory:
            fake_docker = Path(directory) / "docker"
            fake_docker.write_text(
                """#!/bin/sh
case "${1:-}" in
    compose|info|image) exit 0 ;;
    build) sleep 30 ;;
esac
exit 0
""",
                encoding="utf-8",
            )
            fake_docker.chmod(0o755)

            environment = os.environ.copy()
            environment.pop("BASH_ENV", None)
            environment.pop("DOCKER_COMPOSE", None)
            environment.update(
                {
                    "CONTAINER_COMPOSE": true_binary or "true",
                    "CONTAINER_COMPOSE_CONTAINER": true_binary or "true",
                    "PARITY_TIMEOUT_SECONDS": "1",
                    "PATH": f"{directory}:/usr/bin:/bin",
                }
            )
            completed = subprocess.run(
                [str(SCRIPT), "--strict"],
                cwd=REPO_ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
                timeout=10,
            )

        self.assertEqual(completed.returncode, 124)
        self.assertIn("command exceeded 1-second deadline: docker", completed.stderr)


if __name__ == "__main__":
    unittest.main()
