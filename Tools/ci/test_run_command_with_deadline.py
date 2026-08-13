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
                    "1",
                    "--",
                    "/bin/sh",
                    "-c",
                    f'sleep 30 & printf "%s\\n" "$!" >{child_pid}; '
                    f'touch {ready}; wait',
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
            process_state = subprocess.run(
                ["ps", "-p", str(pid), "-o", "state="],
                capture_output=True,
                text=True,
                check=False,
            ).stdout.strip()
            self.assertIn(process_state, ("", "Z"))


if __name__ == "__main__":
    unittest.main()
