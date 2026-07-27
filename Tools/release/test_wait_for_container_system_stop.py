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

"""Tests for release-runner launchd quiescence detection."""

import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[2]
SCRIPT = ROOT / "Tools" / "release" / "wait-for-container-system-stop.sh"


class WaitForContainerSystemStopTests(unittest.TestCase):
    """The recorder starts only after a stable stopped observation window."""

    def run_waiter(
        self,
        launchctl_body: str,
        *,
        environment: dict[str, str] | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], Path]:
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        root = Path(temporary_directory.name)
        fake_launchctl = root / "launchctl"
        fake_launchctl.write_text(
            "#!/usr/bin/env bash\nset -euo pipefail\n"
            + textwrap.dedent(launchctl_body),
            encoding="utf-8",
        )
        fake_launchctl.chmod(0o755)

        result = subprocess.run(
            ["bash", str(SCRIPT)],
            capture_output=True,
            check=False,
            env=os.environ
            | {
                "LAUNCHCTL_BIN": str(fake_launchctl),
                "FAKE_LAUNCHCTL_COUNTER": str(root / "counter"),
                "CONTAINER_SYSTEM_STOP_WAIT_ATTEMPTS": "5",
                "CONTAINER_SYSTEM_STOP_STABLE_OBSERVATIONS": "2",
                "CONTAINER_SYSTEM_STOP_POLL_INTERVAL_SECONDS": "0",
            }
            | (environment or {}),
            text=True,
        )
        return result, root

    def test_requires_consecutive_absent_observations(self) -> None:
        result, root = self.run_waiter(
            """
            count=0
            if [[ -f "${FAKE_LAUNCHCTL_COUNTER}" ]]; then
              count="$(cat "${FAKE_LAUNCHCTL_COUNTER}")"
            fi
            count=$((count + 1))
            printf '%s' "${count}" > "${FAKE_LAUNCHCTL_COUNTER}"
            if (( count <= 2 )); then
              printf '123 0 com.apple.container.apiserver\\n'
            fi
            """
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((root / "counter").read_text(encoding="utf-8"), "4")
        self.assertIn("remained stopped for 2 observations", result.stdout)

    def test_resets_the_stable_window_when_a_service_reappears(self) -> None:
        result, root = self.run_waiter(
            """
            count=0
            if [[ -f "${FAKE_LAUNCHCTL_COUNTER}" ]]; then
              count="$(cat "${FAKE_LAUNCHCTL_COUNTER}")"
            fi
            count=$((count + 1))
            printf '%s' "${count}" > "${FAKE_LAUNCHCTL_COUNTER}"
            if (( count == 2 )); then
              printf '321 0 com.apple.container.machine-apiserver\\n'
            fi
            """
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((root / "counter").read_text(encoding="utf-8"), "4")

    def test_fails_when_the_namespace_never_stops(self) -> None:
        result, root = self.run_waiter(
            """
            count=0
            if [[ -f "${FAKE_LAUNCHCTL_COUNTER}" ]]; then
              count="$(cat "${FAKE_LAUNCHCTL_COUNTER}")"
            fi
            count=$((count + 1))
            printf '%s' "${count}" > "${FAKE_LAUNCHCTL_COUNTER}"
            printf '123 0 com.apple.container.apiserver\\n'
            """
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((root / "counter").read_text(encoding="utf-8"), "5")
        self.assertIn("did not remain stopped", result.stderr)

    def test_fails_when_launchctl_cannot_list_services(self) -> None:
        result, _ = self.run_waiter("exit 1\n")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("failed to query launchd services", result.stderr)

    def test_rejects_an_impossible_stability_window(self) -> None:
        result, _ = self.run_waiter(
            "exit 0\n",
            environment={
                "CONTAINER_SYSTEM_STOP_WAIT_ATTEMPTS": "2",
                "CONTAINER_SYSTEM_STOP_STABLE_OBSERVATIONS": "3",
            },
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("cannot exceed wait attempts", result.stderr)


if __name__ == "__main__":
    unittest.main()
