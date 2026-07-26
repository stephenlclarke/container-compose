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


if __name__ == "__main__":
    unittest.main()
