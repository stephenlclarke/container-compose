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

"""Focused tests for recoverable Current-demo runtime teardown."""

import os
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[2]
SCRIPT = ROOT / "Tools" / "release" / "stop-current-demo-runtime.sh"


class StopCurrentDemoRuntimeTests(unittest.TestCase):
    def run_cleanup(
        self, *, loaded_plist: str | None
    ) -> tuple[subprocess.CompletedProcess[str], Path]:
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        root = Path(temporary_directory.name)
        session = root / "session"
        app_root = session / "app"
        container = session / "install" / "bin" / "container"
        marker = session / ".container-compose-current-demo-root"
        launchctl = root / "launchctl"
        waiter = root / "waiter"
        state = root / "loaded"
        stop_log = root / "stop.log"
        bootout_log = root / "bootout.log"

        container.parent.mkdir(parents=True)
        app_root.mkdir(parents=True)
        session.chmod(0o700)
        marker.write_text("container-compose-current-demo-v1\n", encoding="utf-8")
        container.write_text(
            "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >> \"${STOP_LOG}\"\n",
            encoding="utf-8",
        )
        container.chmod(0o755)
        if loaded_plist == "DEMO":
            loaded_plist = str(app_root / "apiserver" / "apiserver.plist")
        if loaded_plist is not None:
            state.write_text(loaded_plist, encoding="utf-8")
        launchctl.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  print)
    [[ -f "${SERVICE_STATE}" ]] || exit 113
    printf 'path = %s\n' "$(cat "${SERVICE_STATE}")"
    ;;
  bootout)
    printf '%s\n' "$2" >> "${BOOTOUT_LOG}"
    rm -f "${SERVICE_STATE}"
    ;;
  list)
    printf 'PID Status Label\n'
    ;;
  *)
    exit 114
    ;;
esac
""",
            encoding="utf-8",
        )
        waiter.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
        launchctl.chmod(0o755)
        waiter.chmod(0o755)
        environment = os.environ | {
            "BOOTOUT_LOG": str(bootout_log),
            "CONTAINER_DEMO_LAUNCHCTL": str(launchctl),
            "CONTAINER_SYSTEM_STOP_WAITER": str(waiter),
            "SERVICE_STATE": str(state),
            "STOP_LOG": str(stop_log),
        }
        result = subprocess.run(
            ["bash", str(SCRIPT), str(session), str(container)],
            capture_output=True,
            check=False,
            env=environment,
            text=True,
        )
        return result, root

    def test_boots_out_only_the_demo_owned_service_after_cli_stop(self) -> None:
        result, root = self.run_cleanup(loaded_plist="DEMO")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            (root / "stop.log").read_text(encoding="utf-8"), "system stop\n"
        )
        self.assertIn(
            "com.apple.container.apiserver",
            (root / "bootout.log").read_text(encoding="utf-8"),
        )
        self.assertFalse((root / "loaded").exists())

    def test_refuses_to_boot_out_an_unrelated_service(self) -> None:
        result, root = self.run_cleanup(
            loaded_plist=(
                "/Users/example/Library/Application Support/container/apiserver.plist"
            )
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn(
            "refusing to boot out unrelated Container launch agent", result.stderr
        )
        self.assertFalse((root / "stop.log").exists())
        self.assertFalse((root / "bootout.log").exists())
        self.assertTrue((root / "loaded").exists())

    def test_ignores_termination_until_demo_teardown_completes(self) -> None:
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        root = Path(temporary_directory.name)
        session = root / "session"
        app_root = session / "app"
        container = session / "install" / "bin" / "container"
        marker = session / ".container-compose-current-demo-root"
        launchctl = root / "launchctl"
        waiter = root / "waiter"
        state = root / "loaded"
        bootout_log = root / "bootout.log"

        container.parent.mkdir(parents=True)
        app_root.mkdir(parents=True)
        session.chmod(0o700)
        marker.write_text("container-compose-current-demo-v1\n", encoding="utf-8")
        container.write_text("#!/usr/bin/env bash\nsleep 0.3\n", encoding="utf-8")
        container.chmod(0o755)
        state.write_text(
            str(app_root / "apiserver" / "apiserver.plist"), encoding="utf-8"
        )
        launchctl.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == print ]]; then
  [[ -f "${SERVICE_STATE}" ]] || exit 113
  printf 'path = %s\n' "$(cat "${SERVICE_STATE}")"
elif [[ "$1" == bootout ]]; then
  printf '%s\n' "$2" > "${BOOTOUT_LOG}"
  rm -f "${SERVICE_STATE}"
else
  exit 114
fi
""",
            encoding="utf-8",
        )
        waiter.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
        launchctl.chmod(0o755)
        waiter.chmod(0o755)
        process = subprocess.Popen(
            ["bash", str(SCRIPT), str(session), str(container)],
            env=os.environ
            | {
                "BOOTOUT_LOG": str(bootout_log),
                "CONTAINER_DEMO_LAUNCHCTL": str(launchctl),
                "CONTAINER_SYSTEM_STOP_WAITER": str(waiter),
                "SERVICE_STATE": str(state),
            },
            stderr=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        )
        time.sleep(0.1)
        process.send_signal(signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=5)

        self.assertEqual(process.returncode, 0, stdout + stderr)
        self.assertTrue(bootout_log.is_file())
        self.assertFalse(state.exists())


if __name__ == "__main__":
    unittest.main()
