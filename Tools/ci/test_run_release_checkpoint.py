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

import hashlib
import json
import os
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("run-release-checkpoint.py")
ROOT = SCRIPT.parents[2]
STACK_SCRIPT = SCRIPT.with_name("run-stack-release-validation.sh")


class RunReleaseCheckpointTest(unittest.TestCase):
    def stack_validation_fingerprints(
        self,
        stack_timeout: int,
        tool_fingerprint: str = "tools-a",
        environment_fingerprint: str = "environment-a",
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
                    "RELEASE_GATE_INHERITED_ENVIRONMENT_FINGERPRINT": (
                        environment_fingerprint
                    ),
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
        python: str = sys.executable,
        compose_test_binary: str = "/usr/bin/true",
        compose_container: str | None = None,
        normalizer: str | None = None,
        environment: dict[str, str] | None = None,
        make: str = "make",
    ) -> str:
        command = [
            make,
            "--no-print-directory",
            "-s",
            "-f",
            str(ROOT / "Makefile"),
            "print-release-gate-fingerprint",
            f"RELEASE_GATE_STACK_TIMEOUT_SECONDS={release_stack_timeout}",
            f"RELEASE_GATE_PARITY_TIMEOUT_SECONDS={release_parity_timeout}",
            f"PARITY_STAGE_TIMEOUT_SECONDS={parity_stage_timeout}",
            f"CONTAINER_RUNTIME_START_DEADLINE_SECONDS={runtime_start_deadline}",
            "RELEASE_GATE_INIT_ARCHIVE_FINGERPRINT=fixture-init",
            "RELEASE_GATE_TOOL_FINGERPRINT=fixture-tools",
            "DOCKER_COMPOSE_REFERENCE=/usr/bin/true",
            f"PYTHON={python}",
            f"COMPOSE_TEST_BINARY={compose_test_binary}",
            "SWIFT=/usr/bin/true",
            "GO=/usr/bin/true",
        ]
        if normalizer is not None:
            command.append(f"CONTAINER_COMPOSE_NORMALIZER={normalizer}")
        if compose_container is not None:
            command.append(f"CONTAINER_COMPOSE_CONTAINER={compose_container}")
        completed = subprocess.run(
            command,
            cwd=ROOT,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return completed.stdout.strip()

    def test_release_gate_fingerprints_selected_normalizer_content(self) -> None:
        make_executables = [shutil.which("make") or "make"]
        system_make = Path("/usr/bin/make")
        if system_make.is_file() and str(system_make) not in make_executables:
            make_executables.append(str(system_make))

        for make in make_executables:
            with self.subTest(make=make), tempfile.TemporaryDirectory() as directory:
                normalizer = Path(directory) / "compose normalizer's tool"
                normalizer.write_bytes(b"first normalizer")

                initial = self.release_gate_fingerprint(
                    python=sys.executable,
                    normalizer=str(normalizer),
                    make=make,
                )
                normalizer.write_bytes(b"second normalizer")
                changed = self.release_gate_fingerprint(
                    python=sys.executable,
                    normalizer=str(normalizer),
                    make=make,
                )

                self.assertNotEqual(initial, changed)

    def test_release_gate_fingerprint_reuses_relocated_runtime_content(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def runtime_inputs(name: str) -> tuple[dict[str, str], Path]:
                runtime = root / name
                binary = runtime / "candidate" / "bin" / "container"
                binary.parent.mkdir(parents=True)
                binary.write_bytes(b"immutable candidate")
                config = runtime / "app" / "xdg-config" / "container" / "config.toml"
                config.parent.mkdir(parents=True)
                config.write_text('[build]\nimage = "fixture"\n', encoding="utf-8")
                # This unit proves relocation normalization, so give both
                # invocations the same controlled inputs. Hosted CI exposes
                # bookkeeping files whose contents can change while the test
                # runs; inheriting those values would test runner activity
                # instead of runtime-content identity.
                environment = {
                    "CONTAINER_RUNTIME_CANDIDATE_SHA256": "a" * 64,
                    "CONTAINER_RUNTIME_CLI": str(binary),
                    "CONTAINER_RUNTIME_CLI_SHA256": hashlib.sha256(
                        binary.read_bytes()
                    ).hexdigest(),
                    "PATH": f"{binary.parent}{os.pathsep}{os.environ['PATH']}",
                    "XDG_CONFIG_HOME": str(config.parents[1]),
                }
                return environment, binary

            first_environment, first_binary = runtime_inputs("first-run")
            second_environment, second_binary = runtime_inputs("second-run")

            first = self.release_gate_fingerprint(
                environment=first_environment,
                compose_container=str(first_binary),
            )
            second = self.release_gate_fingerprint(
                environment=second_environment,
                compose_container=str(second_binary),
            )

            self.assertEqual(first, second)

    def test_release_fingerprint_cannot_be_replaced_by_a_caller(self) -> None:
        completed = subprocess.run(
            [
                "make",
                "--no-print-directory",
                "-s",
                "-f",
                str(ROOT / "Makefile"),
                "print-release-gate-fingerprint",
                "RELEASE_GATE_STATIC_FINGERPRINT=forged",
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertNotEqual(completed.stdout.strip(), "forged")

    def test_release_gate_rejects_an_empty_derived_environment_identity(self) -> None:
        completed = subprocess.run(
            [
                "make",
                "--no-print-directory",
                "release-gate-environment-fingerprint-check",
                "PYTHON=/usr/bin/true",
                "RELEASE_GATE_INHERITED_ENVIRONMENT_FINGERPRINT=" + ("a" * 64),
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertEqual(completed.returncode, 2)
        self.assertIn(
            "could not fingerprint the inherited release-gate environment",
            completed.stderr,
        )

    def release_gate_tool_fingerprint(
        self,
        swift: str = "/usr/bin/true",
        go: str = "/usr/bin/true",
        python: str = "/usr/bin/true",
        markdownlint: str = "/usr/bin/true",
        hawkeye: str = "/usr/bin/true",
        llvm_cov: str = "/usr/bin/true",
        llvm_profdata: str = "/usr/bin/true",
        docker_compose: str = "/usr/bin/true compose",
    ) -> str:
        with tempfile.TemporaryDirectory() as directory:
            supplemental_makefile = Path(directory) / "tool-fingerprint.mk"
            supplemental_makefile.write_text(
                "print-release-gate-tool-fingerprint:\n"
                "\t@printf '%s\\n' \"$(RELEASE_GATE_TOOL_FINGERPRINT)\"\n",
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
                    "print-release-gate-tool-fingerprint",
                    f"SWIFT={swift}",
                    f"GO={go}",
                    f"PYTHON={python}",
                    f"MARKDOWNLINT={markdownlint}",
                    f"HAWKEYE={hawkeye}",
                    f"SWIFT_LLVM_COV={llvm_cov}",
                    f"SWIFT_LLVM_PROFDATA={llvm_profdata}",
                    f"DOCKER_COMPOSE_REFERENCE={docker_compose}",
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

    def test_stage_output_is_durable_and_not_forwarded_to_controller(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            checkpoints = Path(directory) / "checkpoints"
            completed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--checkpoint-dir",
                    str(checkpoints),
                    "--stage",
                    "compose-ci",
                    "--fingerprint",
                    "tree-a",
                    "--seconds",
                    "5",
                    "--",
                    "/bin/sh",
                    "-c",
                    "printf 'durable stage output\\n'",
                ],
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertNotIn("durable stage output", completed.stdout)
            output_paths = tuple(checkpoints.glob("compose-ci.*.log"))
            self.assertEqual(len(output_paths), 1)
            output_path = output_paths[0]
            self.assertEqual(
                output_path.read_text(encoding="utf-8"), "durable stage output\n"
            )
            checkpoint = json.loads(
                (checkpoints / "compose-ci.success.json").read_text(encoding="utf-8")
            )
            self.assertEqual(checkpoint["output_file"], output_path.name)
            self.assertEqual(
                checkpoint["output_sha256"],
                hashlib.sha256(output_path.read_bytes()).hexdigest(),
            )

    def test_missing_or_modified_output_invalidates_success_checkpoint(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            checkpoints = root / "checkpoints"
            run_log = root / "runs.log"

            first = self.run_stage(checkpoints, run_log, "tree-a")
            output_path = next(checkpoints.glob("compose-ci.*.log"))
            output_path.write_text("modified\n", encoding="utf-8")
            modified = self.run_stage(checkpoints, run_log, "tree-a")
            output_path.unlink()
            missing = self.run_stage(checkpoints, run_log, "tree-a")

            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(modified.returncode, 0, modified.stderr)
            self.assertEqual(missing.returncode, 0, missing.stderr)
            self.assertEqual(run_log.read_text(encoding="utf-8"), "run\n" * 3)
            self.assertIn("invalidating release checkpoint", modified.stdout)
            self.assertIn("invalidating release checkpoint", missing.stdout)

    def test_failed_rerun_cannot_revalidate_an_invalidated_checkpoint(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            checkpoints = root / "checkpoints"
            command = root / "stage.sh"
            command.write_text("#!/bin/sh\nprintf 'same output\\n'\n", encoding="utf-8")
            command.chmod(0o700)
            arguments = [
                sys.executable,
                str(SCRIPT),
                "--checkpoint-dir",
                str(checkpoints),
                "--stage",
                "compose-ci",
                "--fingerprint",
                "tree-a",
                "--seconds",
                "5",
                "--",
                str(command),
            ]

            first = subprocess.run(
                arguments, capture_output=True, text=True, check=False
            )
            output_path = next(checkpoints.glob("compose-ci.*.log"))
            output_path.write_text("corrupt\n", encoding="utf-8")
            command.write_text(
                "#!/bin/sh\nprintf 'same output\\n'\nexit 9\n", encoding="utf-8"
            )
            failed = subprocess.run(
                arguments, capture_output=True, text=True, check=False
            )
            repeated = subprocess.run(
                arguments, capture_output=True, text=True, check=False
            )

            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(failed.returncode, 9, failed.stderr)
            self.assertEqual(repeated.returncode, 9, repeated.stderr)
            self.assertIn("invalidating release checkpoint", failed.stdout)
            self.assertNotIn("reusing exact-input release checkpoint", repeated.stdout)
            self.assertFalse((checkpoints / "compose-ci.success.json").exists())

    def test_failure_report_contains_only_the_bounded_output_tail(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            checkpoints = Path(directory) / "checkpoints"
            completed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--checkpoint-dir",
                    str(checkpoints),
                    "--stage",
                    "compose-ci",
                    "--fingerprint",
                    "tree-a",
                    "--seconds",
                    "5",
                    "--",
                    sys.executable,
                    "-c",
                    "import sys\n"
                    "for number in range(1, 201):\n"
                    "    print(number)\n"
                    "sys.exit(9)\n",
                ],
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(completed.returncode, 9)
            self.assertIn("last 80 output lines", completed.stderr)
            self.assertNotIn("\n120\n", completed.stderr)
            self.assertIn("\n121\n", completed.stderr)
            self.assertTrue(completed.stderr.endswith("200\n"))

    def test_failure_report_is_also_bounded_by_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            completed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--checkpoint-dir",
                    str(Path(directory) / "checkpoints"),
                    "--stage",
                    "compose-ci",
                    "--fingerprint",
                    "tree-a",
                    "--seconds",
                    "5",
                    "--",
                    sys.executable,
                    "-c",
                    "import sys\n"
                    "print('x' * 131072)\n"
                    "print('final diagnostic')\n"
                    "sys.exit(9)\n",
                ],
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(completed.returncode, 9)
            self.assertIn("limited to 32768 bytes", completed.stderr)
            self.assertIn("[earlier output omitted]", completed.stderr)
            self.assertTrue(completed.stderr.endswith("final diagnostic\n"))
            self.assertLess(len(completed.stderr.encode("utf-8")), 34 * 1024)

    def test_stage_timeout_reports_the_durable_output_tail(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            completed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--checkpoint-dir",
                    str(Path(directory) / "checkpoints"),
                    "--stage",
                    "compose-ci",
                    "--fingerprint",
                    "tree-a",
                    "--seconds",
                    "1",
                    "--",
                    sys.executable,
                    "-c",
                    "import time\n"
                    "print('timeout diagnostic', flush=True)\n"
                    "time.sleep(30)\n",
                ],
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(completed.returncode, 124)
            self.assertIn("exceeded 1-second deadline", completed.stderr)
            self.assertIn("timeout diagnostic", completed.stderr)

    @unittest.skipUnless(hasattr(os, "mkfifo"), "requires FIFO support")
    def test_timeout_diagnostic_rejects_a_fifo_without_blocking(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            checkpoints = Path(directory) / "checkpoints"
            completed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--checkpoint-dir",
                    str(checkpoints),
                    "--stage",
                    "compose-ci",
                    "--fingerprint",
                    "tree-a",
                    "--seconds",
                    "1",
                    "--",
                    sys.executable,
                    "-c",
                    "import glob, os, sys, time\n"
                    "active = glob.glob(os.path.join(sys.argv[1], "
                    "'.compose-ci.active-*.log'))[0]\n"
                    "os.unlink(active)\n"
                    "os.mkfifo(active)\n"
                    "time.sleep(30)\n",
                    str(checkpoints),
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=5,
            )

            self.assertEqual(completed.returncode, 124, completed.stderr)

    def test_controller_signal_cleans_up_the_deadline_worker_session(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ready = root / "ready"
            cleanup = root / "cleanup"
            process = subprocess.Popen(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--checkpoint-dir",
                    str(root / "checkpoints"),
                    "--stage",
                    "compose-ci",
                    "--fingerprint",
                    "tree-a",
                    "--seconds",
                    "30",
                    "--",
                    "/bin/sh",
                    "-c",
                    f"trap 'touch {cleanup}; exit 0' TERM; "
                    f"touch {ready}; while :; do sleep 1; done",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            ready_deadline = time.monotonic() + 3
            while not ready.exists():
                if time.monotonic() >= ready_deadline:
                    process.kill()
                    process.communicate(timeout=2)
                    self.fail("checkpoint worker did not become ready")
                time.sleep(0.01)

            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=8)

            self.assertEqual(process.returncode, 143, stdout + stderr)
            self.assertTrue(cleanup.exists(), stdout + stderr)

    def test_stage_cannot_succeed_after_removing_its_durable_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            checkpoints = root / "checkpoints"
            completed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--checkpoint-dir",
                    str(checkpoints),
                    "--stage",
                    "compose-ci",
                    "--fingerprint",
                    "tree-a",
                    "--seconds",
                    "5",
                    "--",
                    "/bin/sh",
                    "-c",
                    'rm "$1"/.compose-ci.active-*.log',
                    "remove-output",
                    str(checkpoints),
                ],
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(completed.returncode, 74, completed.stderr)
            self.assertIn("could not verify release checkpoint output", completed.stderr)
            self.assertFalse((checkpoints / "compose-ci.success.json").exists())

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

    def test_fingerprint_command_and_stage_share_one_deadline(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fingerprint_started = root / "fingerprint-started"
            stage_started = root / "stage-started"
            fingerprint = root / "fingerprint"
            fingerprint.write_text(
                "#!/bin/sh\n"
                f"touch '{fingerprint_started}'\n"
                "sleep 30\n"
                "printf 'fingerprint\\n'\n",
                encoding="utf-8",
            )
            fingerprint.chmod(0o755)

            started = time.monotonic()
            completed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--stage",
                    "compose-ci",
                    "--fingerprint-command",
                    str(fingerprint),
                    "--seconds",
                    "1",
                    "--",
                    "/usr/bin/touch",
                    str(stage_started),
                ],
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(completed.returncode, 124, completed.stderr)
            self.assertLess(time.monotonic() - started, 5)
            self.assertTrue(fingerprint_started.exists())
            self.assertFalse(stage_started.exists())

    def test_release_gate_starts_deadline_before_make_fingerprinting(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fingerprint_started = root / "fingerprint-started"
            stalled_tool = root / "stalled-tool"
            stalled_tool.write_text(
                "#!/bin/sh\n"
                f"touch '{fingerprint_started}'\n"
                "sleep 30\n",
                encoding="utf-8",
            )
            stalled_tool.chmod(0o755)

            started = time.monotonic()
            completed = subprocess.run(
                [
                    "make",
                    "--no-print-directory",
                    "-f",
                    str(ROOT / "Makefile"),
                    "release-gate",
                    "RELEASE_GATE_STACK_TIMEOUT_SECONDS=5",
                    "RELEASE_GATE_STAGE_TIMEOUT_SECONDS=5",
                    "RELEASE_GATE_PARITY_TIMEOUT_SECONDS=5",
                    "RELEASE_GATE_CHECKPOINT_DIR=",
                    "RELEASE_GATE_INIT_ARCHIVE_FINGERPRINT=fixture-init",
                    "RELEASE_GATE_TOOL_FINGERPRINT=fixture-tools",
                    "DOCKER_COMPOSE_REFERENCE=/usr/bin/true",
                    "PYTHON=/usr/bin/python3",
                    f"SWIFT={stalled_tool}",
                    "GO=/usr/bin/true",
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertLess(time.monotonic() - started, 9)
            self.assertTrue(fingerprint_started.exists())
            self.assertIn("exceeded 5-second deadline", completed.stderr)

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

    def test_tool_fingerprint_tracks_selected_gate_executables(self) -> None:
        baseline = self.release_gate_tool_fingerprint()
        selectors = {
            "swift": {"swift": "/usr/bin/false"},
            "go": {"go": "/usr/bin/false"},
            "python": {"python": "/usr/bin/false"},
            "markdownlint": {"markdownlint": "/usr/bin/false"},
            "hawkeye": {"hawkeye": "/usr/bin/false"},
            "llvm-cov": {"llvm_cov": "/usr/bin/false"},
            "llvm-profdata": {"llvm_profdata": "/usr/bin/false"},
            "docker-compose": {"docker_compose": "/usr/bin/false compose"},
        }

        for name, overrides in selectors.items():
            with self.subTest(tool=name):
                self.assertNotEqual(
                    self.release_gate_tool_fingerprint(**overrides), baseline
                )

    def test_outer_fingerprint_tracks_runtime_compose_binary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            first_binary = Path(directory) / "compose-first"
            second_binary = Path(directory) / "compose-second"
            first_binary.write_bytes(b"first executable")
            second_binary.write_bytes(b"second executable")

            baseline = self.release_gate_fingerprint(
                compose_test_binary=str(first_binary)
            )
            first_binary.write_bytes(b"replaced executable")
            changed_content = self.release_gate_fingerprint(
                compose_test_binary=str(first_binary)
            )
            changed_selector = self.release_gate_fingerprint(
                compose_test_binary=str(second_binary)
            )

            self.assertNotEqual(changed_content, baseline)
            self.assertNotEqual(changed_selector, changed_content)
            self.assertNotIn(str(first_binary), baseline)
            self.assertNotIn(str(second_binary), changed_selector)

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

    def test_child_stack_fingerprints_track_inherited_release_inputs(self) -> None:
        baseline = self.stack_validation_fingerprints(
            14400, environment_fingerprint="environment-a"
        )
        changed = self.stack_validation_fingerprints(
            14400, environment_fingerprint="environment-b"
        )

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
