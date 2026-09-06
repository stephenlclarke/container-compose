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

"""Focused regression tests for build-secret parity path handling."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import textwrap
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "Tools/parity/check-compose-build-secret-metadata.sh"


FAKE_COMPOSE = r"""#!/usr/bin/env python3
import json
import os
import pathlib
import sys

args = sys.argv[1:]
project_directory = pathlib.Path(args[args.index("--project-directory") + 1])
secret_path = project_directory / "secret.txt"
is_docker = pathlib.Path(sys.argv[0]).name == "docker-compose-fake"
if is_docker:
    secret_path = secret_path.resolve()

if "config" in args:
    if is_docker:
        print(json.dumps({
            "services": {
                "api": {
                    "build": {
                        "secrets": [{
                            "source": "app_secret",
                            "target": "runtime_secret",
                            "uid": "1000",
                            "gid": "1000",
                            "mode": "0440",
                        }],
                    },
                },
            },
        }))
    else:
        print(json.dumps({
            "services": {
                "api": {
                    "build": {
                        "secrets": [{
                            "id": "runtime_secret",
                            "file": str(secret_path),
                        }],
                    },
                },
            },
        }))
elif "--print" in args:
    secret = f"id=runtime_secret,type=file,src={secret_path}"
    if os.environ.get("FAKE_LEAK_METADATA") == "1":
        secret += ",uid=1000"
    print(json.dumps({"target": {"api": {"secret": [secret]}}}))
elif "--dry-run" in args:
    print(f"--secret id=runtime_secret,src={secret_path}")
"""


class ComposeBuildSecretMetadataParityTests(unittest.TestCase):
    def run_check(self, *, leak_metadata: bool = False) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            actual_tmp = root / "actual"
            alias_tmp = root / "alias"
            bin_directory = root / "bin"
            actual_tmp.mkdir()
            alias_tmp.symlink_to(actual_tmp, target_is_directory=True)
            bin_directory.mkdir()

            docker_compose = bin_directory / "docker-compose-fake"
            container_compose = bin_directory / "container-compose-fake"
            for executable in (docker_compose, container_compose):
                executable.write_text(textwrap.dedent(FAKE_COMPOSE), encoding="utf-8")
                executable.chmod(0o755)

            environment = os.environ.copy()
            environment.update(
                {
                    "TMPDIR": str(alias_tmp),
                    "DOCKER_COMPOSE": str(docker_compose),
                    "CONTAINER_COMPOSE": str(container_compose),
                }
            )
            if leak_metadata:
                environment["FAKE_LEAK_METADATA"] = "1"

            return subprocess.run(
                [str(SCRIPT), "--strict"],
                cwd=REPO_ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

    def test_equivalent_filesystem_aliases_pass(self) -> None:
        result = self.run_check()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("build-secret metadata parity passed", result.stdout)

    def test_additional_secret_metadata_still_fails(self) -> None:
        result = self.run_check(leak_metadata=True)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rendered bake secret fields", result.stderr)


if __name__ == "__main__":
    unittest.main()
