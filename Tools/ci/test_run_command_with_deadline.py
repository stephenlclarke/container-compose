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

import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("run-command-with-deadline.py")


def process_state(pid: int) -> str:
    return subprocess.run(
        ["ps", "-p", str(pid), "-o", "state="],
        capture_output=True,
        text=True,
        check=False,
    ).stdout.strip()


class RunCommandWithDeadlineTest(unittest.TestCase):
    def test_returns_the_child_status_and_output(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--seconds",
                "5",
                "--",
                "/bin/sh",
                "-c",
                'printf "complete\\n"; exit 7',
            ],
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(result.stdout, "complete\n")

    def test_timeout_terminates_the_entire_child_process_group(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ready = root / "ready"
            child_pid = root / "child-pid"
            started = time.monotonic()
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--seconds",
                    "0.2",
                    "--grace-seconds",
                    "0.3",
                    "--",
                    "/bin/sh",
                    "-c",
                    "trap 'exit 0' TERM; "
                    f"(trap '' TERM; exec sleep 30) & "
                    f'printf "%s\\n" "$!" >{child_pid}; '
                    f'touch {ready}; while :; do sleep 1; done',
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=5,
            )

            self.assertEqual(result.returncode, 124, result.stderr)
            self.assertLess(time.monotonic() - started, 3)
            self.assertTrue(ready.exists())
            self.assertIn("command exceeded 0.2-second deadline", result.stderr)
            self.assertNotIn("sleep 30", result.stderr)
            pid = int(child_pid.read_text(encoding="utf-8").strip())
            self.assertIn(process_state(pid), ("", "Z"))

    def test_outer_timeout_cleans_a_nested_runner_child_group(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            child_pid = root / "child-pid"
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--seconds",
                    "0.2",
                    "--grace-seconds",
                    "0.2",
                    "--",
                    sys.executable,
                    str(SCRIPT),
                    "--seconds",
                    "30",
                    "--grace-seconds",
                    "0.8",
                    "--",
                    "/bin/sh",
                    "-c",
                    "trap 'exit 0' TERM; "
                    f"(trap '' TERM; exec sleep 30) & "
                    f'printf "%s\\n" "$!" >{child_pid}; '
                    "while :; do sleep 1; done",
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=5,
            )

            self.assertEqual(result.returncode, 124, result.stderr)
            self.assertTrue(child_pid.exists())
            pid = int(child_pid.read_text(encoding="utf-8").strip())
            cleanup_deadline = time.monotonic() + 2
            while process_state(pid) not in ("", "Z"):
                if time.monotonic() >= cleanup_deadline:
                    self.fail(f"nested deadline child {pid} survived cleanup")
                time.sleep(0.05)

    def test_signal_after_spawn_is_forwarded_without_a_race(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            process_group_file = root / "process-group"
            harness = root / "signal-race.py"
            harness.write_text(
                f"""\
import importlib.util
import os
import signal
import subprocess

spec = importlib.util.spec_from_file_location("deadline_runner", {str(SCRIPT)!r})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
original_popen = module.subprocess.Popen

def signaling_popen(*args, **kwargs):
    process = original_popen(*args, **kwargs)
    with open({str(process_group_file)!r}, "w", encoding="utf-8") as stream:
        stream.write(str(process.pid))
    os.kill(os.getpid(), signal.SIGTERM)
    return process

module.subprocess.Popen = signaling_popen
raise SystemExit(module.run([
    "--seconds", "30", "--grace-seconds", "0.2", "--",
    "/bin/sh", "-c", "trap '' TERM; while :; do sleep 1; done",
]))
""",
                encoding="utf-8",
            )

            result = subprocess.run(
                [sys.executable, str(harness)],
                capture_output=True,
                text=True,
                check=False,
                timeout=5,
            )

            self.assertEqual(result.returncode, 143, result.stderr)
            process_group = int(process_group_file.read_text(encoding="utf-8"))
            group_state = subprocess.run(
                ["pgrep", "-g", str(process_group)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(group_state.returncode, 1, group_state.stdout)


if __name__ == "__main__":
    unittest.main()
