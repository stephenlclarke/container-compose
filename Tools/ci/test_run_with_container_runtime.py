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

from __future__ import annotations

import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[2]
SCRIPT = ROOT / "scripts" / "run-with-container-runtime.sh"
LOCK_SCRIPT = ROOT / "Tools" / "ci" / "container-runtime-lock.sh"
DEFAULT_INIT_IMAGE = "vminit:container-compose"


class RunWithContainerRuntimeTest(unittest.TestCase):
    def test_configures_default_init_image_only_after_build(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app_root = temporary_root / "app-root"
            init_repo = temporary_root / "container"
            init_repo.mkdir()
            container_log = temporary_root / "container.log"
            init_log = temporary_root / "init.log"
            fake_container = temporary_root / "container-cli"
            fake_container.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                'printf "%s\\n" "$*" >>"${CONTAINER_TEST_LOG:?}"\n',
                encoding="utf-8",
            )
            fake_container.chmod(0o755)
            (init_repo / "Makefile").write_text(
                "init-block:\n"
                '\t@test ! -e "$(CONFIG_TEST_PATH)"\n'
                '\t@printf "%s\\n" "$(CONTAINER_INIT_IMAGE_NAME)" >"$(INIT_TEST_LOG)"\n',
                encoding="utf-8",
            )
            config_path = app_root / "xdg-config" / "container" / "config.toml"
            environment = os.environ.copy()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                    "CONTAINER_RUNTIME_INIT_BLOCK_REPO": str(init_repo),
                    "CONTAINER_RUNTIME_LOCK_FILE": str(temporary_root / "runtime.lock"),
                    "CONTAINER_TEST_LOG": str(container_log),
                    "CONFIG_TEST_PATH": str(config_path),
                    "INIT_TEST_LOG": str(init_log),
                }
            )

            subprocess.run(
                [str(SCRIPT), str(fake_container), "/usr/bin/true"],
                cwd=ROOT,
                env=environment,
                check=True,
                capture_output=True,
                text=True,
            )

            config = config_path.read_text(encoding="utf-8")
            self.assertIn(f'image = "{DEFAULT_INIT_IMAGE}"', config)
            self.assertEqual(init_log.read_text(encoding="utf-8").strip(), DEFAULT_INIT_IMAGE)
            invocations = container_log.read_text(encoding="utf-8")
            self.assertIn("system start", invocations)
            self.assertIn(f"--app-root {app_root}", invocations)
            self.assertGreaterEqual(invocations.count("system stop"), 2)

    def test_loads_retained_init_image_archive_without_rebuilding(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app_root = temporary_root / "app-root"
            init_archive = temporary_root / "vminit.tar"
            init_archive.write_bytes(b"retained init image")
            container_log = temporary_root / "container.log"
            fake_container = temporary_root / "container-cli"
            fake_container.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                'printf "%s\\n" "$*" >>"${CONTAINER_TEST_LOG:?}"\n',
                encoding="utf-8",
            )
            fake_container.chmod(0o755)
            environment = os.environ.copy()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                    "CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE": str(init_archive),
                    "CONTAINER_RUNTIME_LOCK_FILE": str(temporary_root / "runtime.lock"),
                    "CONTAINER_TEST_LOG": str(container_log),
                }
            )

            subprocess.run(
                [str(SCRIPT), str(fake_container), "/usr/bin/true"],
                cwd=ROOT,
                env=environment,
                check=True,
                capture_output=True,
                text=True,
            )

            config_path = app_root / "xdg-config" / "container" / "config.toml"
            self.assertIn(
                f'image = "{DEFAULT_INIT_IMAGE}"',
                config_path.read_text(encoding="utf-8"),
            )
            invocations = container_log.read_text(encoding="utf-8")
            self.assertIn(f"image load --input {init_archive}", invocations)

    def test_restarts_once_after_transient_xpc_start_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app_root = temporary_root / "app-root"
            container_log = temporary_root / "container.log"
            start_count = temporary_root / "start-count"
            fake_container = temporary_root / "container-cli"
            fake_container.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                'printf "%s\\n" "$*" >>"${CONTAINER_TEST_LOG:?}"\n'
                'if [[ "$*" == *"system start"* ]]; then\n'
                "  count=0\n"
                '  if [[ -f "${CONTAINER_START_COUNT:?}" ]]; then\n'
                '    IFS= read -r count <"${CONTAINER_START_COUNT}"\n'
                "  fi\n"
                "  ((count += 1))\n"
                '  printf "%s\\n" "$count" >"${CONTAINER_START_COUNT}"\n'
                '  if [[ "$count" == "1" ]]; then\n'
                '    printf \'Error: interrupted: "XPC connection error: Connection invalid"\\n\' >&2\n'
                "    exit 1\n"
                "  fi\n"
                "fi\n"
                'if [[ "$*" == "list --all --format json" ]]; then\n'
                "  printf '[]\\n'\n"
                "fi\n",
                encoding="utf-8",
            )
            fake_container.chmod(0o755)
            environment = os.environ.copy()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                    "CONTAINER_RUNTIME_LOCK_FILE": str(temporary_root / "runtime.lock"),
                    "CONTAINER_START_COUNT": str(start_count),
                    "CONTAINER_TEST_LOG": str(container_log),
                }
            )

            result = subprocess.run(
                [str(SCRIPT), str(fake_container), "/usr/bin/true"],
                cwd=ROOT,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

            invocations = container_log.read_text(encoding="utf-8")
            self.assertEqual(invocations.count("system start"), 2)
            self.assertEqual(invocations.count("list --all --format json"), 1)


class ContainerRuntimeLockTest(unittest.TestCase):
    def test_serializes_independent_runtime_users(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            lock_file = temporary_root / "runtime.lock"
            holder_ready = temporary_root / "holder-ready"
            holder_release = temporary_root / "holder-release"
            contender_acquired = temporary_root / "contender-acquired"
            environment = os.environ.copy()
            environment.update(
                {
                    "CONTAINER_RUNTIME_LOCK_FILE": str(lock_file),
                    "CONTAINER_RUNTIME_LOCK_TIMEOUT_SECONDS": "5",
                }
            )
            holder_script = (
                f'source "{LOCK_SCRIPT}"; '
                "acquire_container_runtime_lock; "
                f'touch "{holder_ready}"; '
                f'while [[ ! -e "{holder_release}" ]]; do sleep 0.02; done'
            )
            contender_script = (
                f'source "{LOCK_SCRIPT}"; '
                "acquire_container_runtime_lock; "
                f'touch "{contender_acquired}"'
            )

            holder = subprocess.Popen(
                ["/bin/bash", "-c", holder_script],
                cwd=ROOT,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            deadline = time.monotonic() + 5
            while not holder_ready.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            if not holder_ready.exists():
                holder_stdout, holder_stderr = holder.communicate(timeout=5)
                self.fail(
                    "lock holder did not acquire the lock\n"
                    + holder_stdout
                    + holder_stderr
                )

            contender = subprocess.Popen(
                ["/bin/bash", "-c", contender_script],
                cwd=ROOT,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            time.sleep(0.2)
            acquired_before_release = contender_acquired.exists()

            holder_release.touch()
            holder_stdout, holder_stderr = holder.communicate(timeout=5)
            contender_stdout, contender_stderr = contender.communicate(timeout=5)
            self.assertEqual(holder.returncode, 0, holder_stdout + holder_stderr)
            self.assertEqual(contender.returncode, 0, contender_stdout + contender_stderr)
            self.assertFalse(
                acquired_before_release,
                "contender acquired the runtime lock before the holder released it",
            )
            self.assertTrue(contender_acquired.exists())


if __name__ == "__main__":
    unittest.main()
