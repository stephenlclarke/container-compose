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

"""Unit tests for the container-compose build metadata writer."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


class BuildInfoWriterTests(unittest.TestCase):
    """Package provenance must include every externally relevant component."""

    def test_write_build_info_includes_compose_go_version(self) -> None:
        """Release archives need the compose-go module version in build-info.json."""
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "build-info.json"

            subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).with_name("write-build-info.py")),
                    "--output",
                    str(output),
                    "--version",
                    "0.1.0",
                    "--source",
                    "stephenlclarke/container-compose",
                    "--branch",
                    "main",
                    "--lane",
                    "main",
                    "--commit",
                    "abc123",
                    "--build-type",
                    "release",
                    "--container-source",
                    "stephenlclarke/container",
                    "--container-ref",
                    "container-ref",
                    "--containerization-source",
                    "stephenlclarke/containerization",
                    "--containerization-ref",
                    "containerization-ref",
                    "--compose-go-version",
                    "v2.12.1",
                ],
                check=True,
            )

            payload = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(payload["composeGoVersion"], "v2.12.1")


if __name__ == "__main__":
    unittest.main()
