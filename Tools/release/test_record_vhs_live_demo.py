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

"""Tests for fail-closed recovery of the live Current VHS recorder."""

import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[2]
SCRIPT = ROOT / "Tools" / "release" / "record-vhs-live-demo.sh"


class RecordVHSLiveDemoTests(unittest.TestCase):
    """Only a pre-command ttyd reset may receive a fresh live session."""

    def run_recorder(self, vhs_body: str) -> tuple[subprocess.CompletedProcess[str], Path]:
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        root = Path(temporary_directory.name)
        tape = root / "demo.tape"
        output = root / "demo.gif"
        counter = root / "attempts"
        stop_log = root / "stops"
        fake_vhs = root / "vhs"
        fake_container = root / "container"
        tape.write_text("Output demo.gif\n", encoding="utf-8")
        fake_vhs.write_text(
            "#!/usr/bin/env bash\nset -euo pipefail\n" + textwrap.dedent(vhs_body),
            encoding="utf-8",
        )
        fake_container.write_text(
            "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >> \"${FAKE_STOP_LOG}\"\n",
            encoding="utf-8",
        )
        fake_vhs.chmod(0o755)
        fake_container.chmod(0o755)

        environment = os.environ | {
            "VHS_BIN": str(fake_vhs),
            "VHS_TRANSPORT_RETRIES": "3",
            "RUNNER_TEMP": str(root),
            "FAKE_ATTEMPT_COUNTER": str(counter),
            "FAKE_VHS_OUTPUT": str(output),
            "FAKE_STOP_LOG": str(stop_log),
        }
        result = subprocess.run(
            ["bash", str(SCRIPT), str(tape), str(output), str(fake_container)],
            capture_output=True,
            check=False,
            env=environment,
            text=True,
        )
        return result, root

    def test_retries_a_ttyd_reset_with_a_clean_live_session(self) -> None:
        result, root = self.run_recorder(
            """
            attempt=0
            if [[ -f "${FAKE_ATTEMPT_COUNTER}" ]]; then
              attempt="$(cat "${FAKE_ATTEMPT_COUNTER}")"
            fi
            attempt=$((attempt + 1))
            printf '%s' "${attempt}" > "${FAKE_ATTEMPT_COUNTER}"
            if (( attempt == 1 )); then
              printf 'could not open ttyd: navigation failed: net::ERR_CONNECTION_RESET\\n' >&2
              exit 1
            fi
            printf 'typed command and live output\\n'
            printf 'GIF89a' > "${FAKE_VHS_OUTPUT}"
            """
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((root / "attempts").read_text(encoding="utf-8"), "2")
        self.assertEqual((root / "stops").read_text(encoding="utf-8"), "system stop\n")
        self.assertTrue((root / "demo.gif").is_file())
        self.assertIn("typed command and live output", result.stdout)

    def test_does_not_retry_a_live_command_failure(self) -> None:
        result, root = self.run_recorder(
            """
            printf 'Wait+Screen timed out after typed command\\n' >&2
            printf '1' > "${FAKE_ATTEMPT_COUNTER}"
            exit 1
            """
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((root / "attempts").read_text(encoding="utf-8"), "1")
        self.assertFalse((root / "stops").exists())
        self.assertIn("refusing to retry a live-demo failure", result.stderr)

    def test_does_not_accept_a_successful_recorder_without_an_asset(self) -> None:
        result, root = self.run_recorder(
            """
            printf 'typed command and live output\\n'
            printf '1' > "${FAKE_ATTEMPT_COUNTER}"
            """
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((root / "attempts").read_text(encoding="utf-8"), "1")
        self.assertFalse((root / "stops").exists())
        self.assertIn("VHS completed without producing", result.stderr)

    def test_stops_after_the_bounded_transport_retry_count(self) -> None:
        result, root = self.run_recorder(
            """
            attempt=0
            if [[ -f "${FAKE_ATTEMPT_COUNTER}" ]]; then
              attempt="$(cat "${FAKE_ATTEMPT_COUNTER}")"
            fi
            attempt=$((attempt + 1))
            printf '%s' "${attempt}" > "${FAKE_ATTEMPT_COUNTER}"
            printf 'could not open ttyd: navigation failed: net::ERR_CONNECTION_RESET\\n' >&2
            exit 1
            """
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((root / "attempts").read_text(encoding="utf-8"), "3")
        self.assertEqual(
            (root / "stops").read_text(encoding="utf-8"),
            "system stop\nsystem stop\n",
        )
        self.assertIn("VHS terminal transport did not recover after 3 attempts", result.stderr)

    def test_rejects_invalid_retry_count(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            result = subprocess.run(
                ["bash", str(SCRIPT), "tape", "output", "container"],
                capture_output=True,
                check=False,
                env=os.environ
                | {
                    "VHS_TRANSPORT_RETRIES": "0",
                    "RUNNER_TEMP": str(root),
                },
                text=True,
            )

        self.assertEqual(result.returncode, 2)
        self.assertIn("VHS_TRANSPORT_RETRIES must be a positive integer", result.stderr)


if __name__ == "__main__":
    unittest.main()
