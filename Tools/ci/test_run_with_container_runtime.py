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
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[2]
SCRIPT = ROOT / "scripts" / "run-with-container-runtime.sh"
DEFAULT_INIT_IMAGE = "vminit:container-compose"


class RunWithContainerRuntimeTest(unittest.TestCase):
    def test_rejects_invalid_runtime_inputs_before_service_side_effects(
        self,
    ) -> None:
        cases = [
            (
                "builder image without archive",
                {"CONTAINER_RUNTIME_BUILDER_IMAGE": "local/builder:test"},
                "CONTAINER_RUNTIME_BUILDER_IMAGE and "
                "CONTAINER_RUNTIME_BUILDER_IMAGE_TAR must be set together",
            ),
            (
                "missing init archive",
                {"CONTAINER_RUNTIME_INIT_IMAGE_TAR": "/missing/vminit.tar"},
                "container runtime init image archive does not exist",
            ),
        ]
        runtime_environment_names = (
            "CONTAINER_RUNTIME_APP_ROOT",
            "CONTAINER_RUNTIME_INIT_BLOCK_REPO",
            "CONTAINERIZATION_INIT_SOURCE_PATH",
            "CONTAINER_COMPOSE_INIT_IMAGE",
            "CONTAINER_RUNTIME_INIT_IMAGE_TAR",
            "CONTAINER_RUNTIME_BUILDER_IMAGE",
            "CONTAINER_RUNTIME_BUILDER_IMAGE_TAR",
            "CONTAINER_RUNTIME_BOOTSTRAP_IMAGE_TAR",
        )

        for name, overrides, expected_error in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary_directory:
                temporary_root = Path(temporary_directory)
                container_log = temporary_root / "container.log"
                fake_container = temporary_root / "container"
                fake_container.write_text(
                    "#!/usr/bin/env bash\n"
                    'printf "%s\\n" "$*" >>"${CONTAINER_TEST_LOG:?}"\n',
                    encoding="utf-8",
                )
                fake_container.chmod(0o755)
                environment = os.environ.copy()
                for variable in runtime_environment_names:
                    environment.pop(variable, None)
                environment.update(
                    {
                        "CONTAINER_TEST_LOG": str(container_log),
                        **overrides,
                    }
                )

                result = subprocess.run(
                    [str(SCRIPT), str(fake_container), "/usr/bin/true"],
                    cwd=ROOT,
                    env=environment,
                    capture_output=True,
                    text=True,
                )

                self.assertEqual(result.returncode, 2)
                self.assertIn(expected_error, result.stderr)
                self.assertFalse(container_log.exists())

    def test_configures_default_init_image_only_after_build(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app_root = temporary_root / "app-root"
            init_repo = temporary_root / "container"
            init_repo.mkdir()
            container_log = temporary_root / "container.log"
            init_log = temporary_root / "init.log"
            fake_bin = temporary_root / "fake-bin"
            fake_bin.mkdir()
            fake_container = fake_bin / "container"
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
                '\t@test "$(BASH_ENV)" = "/dev/null"\n'
                '\t@test "$$(command -v container)" = "$(EXPECTED_CONTAINER_CLI)"\n'
                '\t@test "$(CONTAINER_INIT_CLI)" = "$(EXPECTED_CONTAINER_CLI)"\n'
                '\t@printf "%s\\n" "$(CONTAINER_INIT_IMAGE_NAME)" >"$(INIT_TEST_LOG)"\n',
                encoding="utf-8",
            )
            config_path = app_root / "xdg-config" / "container" / "config.toml"
            environment = os.environ.copy()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                    "CONTAINER_RUNTIME_INIT_BLOCK_REPO": str(init_repo),
                    "CONTAINER_TEST_LOG": str(container_log),
                    "CONFIG_TEST_PATH": str(config_path),
                    "EXPECTED_CONTAINER_CLI": str(fake_container),
                    "INIT_TEST_LOG": str(init_log),
                }
            )

            result = subprocess.run(
                [str(SCRIPT), str(fake_container), "/usr/bin/true"],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                result.returncode,
                0,
                f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
            )

            config = config_path.read_text(encoding="utf-8")
            self.assertIn(f'image = "{DEFAULT_INIT_IMAGE}"', config)
            self.assertEqual(init_log.read_text(encoding="utf-8").strip(), DEFAULT_INIT_IMAGE)
            invocations = container_log.read_text(encoding="utf-8")
            self.assertIn("system start", invocations)
            self.assertIn(f"--app-root {app_root}", invocations)
            self.assertEqual(invocations.count("system start"), 2)
            self.assertGreaterEqual(invocations.count("system stop"), 2)

    def test_installs_and_configures_unpublished_builder_before_init_build(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app_root = temporary_root / "app-root"
            init_repo = temporary_root / "container"
            init_repo.mkdir()
            builder_archive = temporary_root / "builder.tar"
            builder_archive.touch()
            container_log = temporary_root / "container.log"
            fake_bin = temporary_root / "fake-bin"
            fake_bin.mkdir()
            fake_container = fake_bin / "container"
            fake_container.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                'printf "%s\\n" "$*" >>"${CONTAINER_TEST_LOG:?}"\n',
                encoding="utf-8",
            )
            fake_container.chmod(0o755)

            config_path = app_root / "xdg-config" / "container" / "config.toml"
            (init_repo / "Makefile").write_text(
                "init-block:\n"
                '\t@grep -F \'image = "local/builder:test"\' "$(CONFIG_TEST_PATH)"\n',
                encoding="utf-8",
            )
            environment = os.environ.copy()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                    "CONTAINER_RUNTIME_INIT_BLOCK_REPO": str(init_repo),
                    "CONTAINER_RUNTIME_BUILDER_IMAGE": "local/builder:test",
                    "CONTAINER_RUNTIME_BUILDER_IMAGE_TAR": str(builder_archive),
                    "CONTAINER_TEST_LOG": str(container_log),
                    "CONFIG_TEST_PATH": str(config_path),
                }
            )

            result = subprocess.run(
                [str(SCRIPT), str(fake_container), "/usr/bin/true"],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                result.returncode,
                0,
                f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
            )

            config = config_path.read_text(encoding="utf-8")
            self.assertIn('[build]\nimage = "local/builder:test"', config)
            self.assertIn(f'[vminit]\nimage = "{DEFAULT_INIT_IMAGE}"', config)
            invocations = container_log.read_text(encoding="utf-8")
            self.assertIn(f"image load -i {builder_archive}", invocations)

    def test_installs_bootstrap_image_before_init_build(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app_root = temporary_root / "app-root"
            init_repo = temporary_root / "container"
            init_repo.mkdir()
            bootstrap_archive = temporary_root / "bootstrap.tar"
            bootstrap_archive.touch()
            container_log = temporary_root / "container.log"
            fake_bin = temporary_root / "fake-bin"
            fake_bin.mkdir()
            fake_container = fake_bin / "container"
            fake_container.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                'printf "%s\\n" "$*" >>"${CONTAINER_TEST_LOG:?}"\n',
                encoding="utf-8",
            )
            fake_container.chmod(0o755)
            (init_repo / "Makefile").write_text(
                "init-block:\n"
                '\t@printf "init-block\\n" >>"$(CONTAINER_TEST_LOG)"\n',
                encoding="utf-8",
            )
            environment = os.environ.copy()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                    "CONTAINER_RUNTIME_INIT_BLOCK_REPO": str(init_repo),
                    "CONTAINER_RUNTIME_BOOTSTRAP_IMAGE_TAR": str(
                        bootstrap_archive
                    ),
                    "CONTAINER_TEST_LOG": str(container_log),
                }
            )

            result = subprocess.run(
                [
                    str(SCRIPT),
                    str(fake_container),
                    "/bin/sh",
                    "-c",
                    'printf "command\\n" >>"$CONTAINER_TEST_LOG"',
                ],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                result.returncode,
                0,
                f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
            )

            invocations = container_log.read_text(encoding="utf-8").splitlines()
            start_index = next(
                index
                for index, invocation in enumerate(invocations)
                if "system start" in invocation
            )
            load_index = invocations.index(f"image load -i {bootstrap_archive}")
            init_index = invocations.index("init-block")
            restart_index = next(
                index
                for index, invocation in enumerate(invocations)
                if index > init_index and "system start" in invocation
            )
            command_index = invocations.index("command")
            self.assertLess(start_index, load_index)
            self.assertLess(load_index, init_index)
            self.assertLess(init_index, restart_index)
            self.assertLess(restart_index, command_index)

    def test_installs_prebuilt_init_image_without_source_build(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app_root = temporary_root / "app-root"
            init_archive = temporary_root / "vminit.tar"
            init_archive.touch()
            container_log = temporary_root / "container.log"
            fake_bin = temporary_root / "fake-bin"
            fake_bin.mkdir()
            fake_container = fake_bin / "container"
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
                    "CONTAINER_RUNTIME_INIT_IMAGE_TAR": str(init_archive),
                    "CONTAINER_TEST_LOG": str(container_log),
                }
            )

            result = subprocess.run(
                [
                    str(SCRIPT),
                    str(fake_container),
                    "/bin/sh",
                    "-c",
                    'printf "command\\n" >>"$CONTAINER_TEST_LOG"',
                ],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                result.returncode,
                0,
                f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
            )

            invocations = container_log.read_text(encoding="utf-8").splitlines()
            load_index = invocations.index(f"image load -i {init_archive}")
            restart_index = next(
                index
                for index, invocation in enumerate(invocations)
                if index > load_index and "system start" in invocation
            )
            command_index = invocations.index("command")
            self.assertEqual(
                sum("system start" in invocation for invocation in invocations),
                2,
            )
            self.assertLess(load_index, restart_index)
            self.assertLess(restart_index, command_index)


if __name__ == "__main__":
    unittest.main()
