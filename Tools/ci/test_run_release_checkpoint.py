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

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("run-release-checkpoint.py")
ROOT = SCRIPT.parents[2]
STACK_SCRIPT = SCRIPT.with_name("run-stack-release-validation.sh")


class RunReleaseCheckpointTest(unittest.TestCase):
    def stack_validation_fingerprints(
        self, stack_timeout: int, tool_fingerprint: str = "tools-a"
    ) -> tuple[str, ...]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repositories = [
                root / name
                for name in ("compose", "builder", "containerization", "container")
            ]
            for repository in repositories:
                repository.mkdir()
                (repository / "Makefile").touch()
            tap = root / "tap"
            (tap / "Formula").mkdir(parents=True)
            (tap / "Formula" / "container-compose.rb").write_text(
                "class ContainerCompose < Formula\nend\n", encoding="utf-8"
            )
            fake_bin = root / "bin"
            fake_bin.mkdir()
            fake_make = fake_bin / "make"
            fake_make.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            fake_make.chmod(0o755)
            environment = os.environ.copy()
            environment.update(
                {
                    "CONTAINER_STACK_VALIDATION_CHECKPOINT_DIR": str(
                        root / "checkpoints"
                    ),
                    "CONTAINER_STACK_VALIDATION_SCRATCH_ROOT": str(root / "scratch"),
                    "RELEASE_GATE_STACK_TIMEOUT_SECONDS": str(stack_timeout),
                    "RELEASE_GATE_TOOL_FINGERPRINT": tool_fingerprint,
                    "PATH": f"{fake_bin}:{environment['PATH']}",
                }
            )
            completed = subprocess.run(
                [
                    str(STACK_SCRIPT),
                    "hosted",
                    *(str(repository) for repository in repositories),
                    str(tap),
                ],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            return tuple(
                line.rsplit("=", 1)[-1]
                for line in completed.stdout.splitlines()
                if line.startswith("stack validation exact-input fingerprint:")
            )

    def release_gate_fingerprint(
        self,
        release_stack_timeout: int = 14400,
        release_parity_timeout: int = 14400,
        parity_stage_timeout: int = 900,
        runtime_start_deadline: int = 300,
        python: str = "/usr/bin/true",
    ) -> str:
        with tempfile.TemporaryDirectory() as directory:
            supplemental_makefile = Path(directory) / "fingerprint.mk"
            supplemental_makefile.write_text(
                "print-release-gate-fingerprint:\n"
                "\t@printf '%s\\n' \"$(RELEASE_GATE_FINGERPRINT)\"\n",
                encoding="utf-8",
            )
            completed = subprocess.run(
                [
                    "make",
                    "--no-print-directory",
                    "-s",
                    "-f",
                    str(ROOT / "Makefile"),
                    "-f",
                    str(supplemental_makefile),
                    "print-release-gate-fingerprint",
                    f"RELEASE_GATE_STACK_TIMEOUT_SECONDS={release_stack_timeout}",
                    f"RELEASE_GATE_PARITY_TIMEOUT_SECONDS={release_parity_timeout}",
                    f"PARITY_STAGE_TIMEOUT_SECONDS={parity_stage_timeout}",
                    f"CONTAINER_RUNTIME_START_DEADLINE_SECONDS={runtime_start_deadline}",
                    "RELEASE_GATE_INIT_ARCHIVE_FINGERPRINT=fixture-init",
                    "RELEASE_GATE_TOOL_FINGERPRINT=fixture-tools",
                    "DOCKER_COMPOSE_REFERENCE=/usr/bin/true",
                    f"PYTHON={python}",
                    "SWIFT=/usr/bin/true",
                    "GO=/usr/bin/true",
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            return completed.stdout.strip()

    def run_stage(
        self,
        checkpoint_directory: Path,
        log: Path,
        fingerprint: str,
        status: int = 0,
        seconds: int = 5,
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
                str(seconds),
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

    def test_tightening_the_deadline_invalidates_the_checkpoint(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            checkpoints = root / "checkpoints"
            log = root / "runs.log"

            first = self.run_stage(checkpoints, log, "tree-a", seconds=5)
            tightened = self.run_stage(checkpoints, log, "tree-a", seconds=4)

            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(tightened.returncode, 0, tightened.stderr)
            self.assertEqual(log.read_text(encoding="utf-8"), "run\nrun\n")
            checkpoint = json.loads(
                (checkpoints / "compose-ci.success.json").read_text(encoding="utf-8")
            )
            self.assertEqual(checkpoint["seconds"], 4)

    def test_outer_fingerprint_tracks_nested_deadline_controls(self) -> None:
        baseline = self.release_gate_fingerprint()
        tighter_stack = self.release_gate_fingerprint(release_stack_timeout=14399)
        tighter_outer_parity = self.release_gate_fingerprint(
            release_parity_timeout=14399
        )
        tighter_parity = self.release_gate_fingerprint(parity_stage_timeout=899)
        tighter_start = self.release_gate_fingerprint(runtime_start_deadline=299)

        self.assertIn("release-stack-timeout=14400", baseline)
        self.assertIn("release-parity-timeout=14400", baseline)
        self.assertIn("parity-stage-timeout=900", baseline)
        self.assertIn("runtime-start-deadline=300", baseline)
        self.assertNotEqual(tighter_stack, baseline)
        self.assertNotEqual(tighter_outer_parity, baseline)
        self.assertNotEqual(tighter_parity, baseline)
        self.assertNotEqual(tighter_start, baseline)

    def test_outer_fingerprint_tracks_the_selected_python(self) -> None:
        baseline = self.release_gate_fingerprint(python="/usr/bin/true")
        changed = self.release_gate_fingerprint(python="/usr/bin/false")

        self.assertNotEqual(changed, baseline)

    def test_child_stack_fingerprints_track_the_outer_deadline(self) -> None:
        baseline = self.stack_validation_fingerprints(14400)
        tightened = self.stack_validation_fingerprints(14399)

        self.assertEqual(len(baseline), 4)
        self.assertEqual(len(tightened), 4)
        self.assertNotEqual(tightened, baseline)

    def test_child_stack_fingerprints_track_the_outer_tools(self) -> None:
        baseline = self.stack_validation_fingerprints(14400, "tools-a")
        changed = self.stack_validation_fingerprints(14400, "tools-b")

        self.assertEqual(len(baseline), 4)
        self.assertEqual(len(changed), 4)
        self.assertNotEqual(changed, baseline)

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
