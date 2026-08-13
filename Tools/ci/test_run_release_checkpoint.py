#===----------------------------------------------------------------------===#
# Copyright © 2026 container-compose project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#===----------------------------------------------------------------------===#

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("run-release-checkpoint.py")


class RunReleaseCheckpointTest(unittest.TestCase):
    def run_stage(
        self,
        checkpoint_directory: Path,
        log: Path,
        fingerprint: str,
        status: int = 0,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--checkpoint-dir",
                str(checkpoint_directory),
                "--stage",
                "compose-ci",
                "--fingerprint",
                fingerprint,
                "--seconds",
                "5",
                "--",
                "/bin/sh",
                "-c",
                f'printf "run\\n" >>{log}; exit {status}',
            ],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_reuses_only_an_exact_successful_stage(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            checkpoints = root / "checkpoints"
            log = root / "runs.log"

            first = self.run_stage(checkpoints, log, "tree-a")
            repeated = self.run_stage(checkpoints, log, "tree-a")
            changed = self.run_stage(checkpoints, log, "tree-b")

            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(repeated.returncode, 0, repeated.stderr)
            self.assertEqual(changed.returncode, 0, changed.stderr)
            self.assertEqual(log.read_text(encoding="utf-8"), "run\nrun\n")
            self.assertIn("reusing exact-input release checkpoint", repeated.stdout)
            checkpoint = json.loads(
                (checkpoints / "compose-ci.success.json").read_text(encoding="utf-8")
            )
            self.assertEqual(checkpoint["fingerprint"], "tree-b")
            self.assertEqual(checkpoint["status"], 0)
            self.assertEqual(checkpoint["executable"], "/bin/sh")
            self.assertIn("command_sha256", checkpoint)
            self.assertNotIn("command", checkpoint)

    def test_failure_is_recorded_but_not_reused(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            checkpoints = root / "checkpoints"
            log = root / "runs.log"

            failed = self.run_stage(checkpoints, log, "tree-a", status=9)
            retried = self.run_stage(checkpoints, log, "tree-a", status=0)

            self.assertEqual(failed.returncode, 9, failed.stderr)
            self.assertEqual(retried.returncode, 0, retried.stderr)
            self.assertEqual(log.read_text(encoding="utf-8"), "run\nrun\n")
            last = json.loads(
                (checkpoints / "compose-ci.last.json").read_text(encoding="utf-8")
            )
            self.assertEqual(last["status"], 0)

    def test_rejects_the_filesystem_root_as_checkpoint_storage(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--checkpoint-dir",
                "/",
                "--stage",
                "compose-ci",
                "--fingerprint",
                "fixture",
                "--seconds",
                "5",
                "--",
                "/usr/bin/true",
            ],
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("must not resolve to /", result.stderr)

    def test_recursive_make_can_skip_the_shared_build_prerequisite(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            makefile = root / "Makefile"
            log = root / "runs.log"
            makefile.write_text(
                """\
.PHONY: build parity-contract

parity-contract: build
\t@printf 'parity-contract\\n' >> \"$(LOG)\"

build:
\t@printf 'build\\n' >> \"$(LOG)\"
""",
                encoding="utf-8",
            )

            completed = subprocess.run(
                [
                    "make",
                    "--no-print-directory",
                    "-f",
                    str(makefile),
                    "-o",
                    "build",
                    "parity-contract",
                    f"LOG={log}",
                ],
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(log.read_text(encoding="utf-8"), "parity-contract\n")


if __name__ == "__main__":
    unittest.main()
