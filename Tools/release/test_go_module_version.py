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

"""Unit tests for Go module version extraction."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


class GoModuleVersionTests(unittest.TestCase):
    """compose-go provenance supports both go.mod require layouts."""

    def test_single_line_require(self) -> None:
        self.assert_module_version(
            """
            module example.test/project

            require github.com/compose-spec/compose-go/v2 v2.12.1
            """,
            "v2.12.1",
        )

    def test_require_block(self) -> None:
        self.assert_module_version(
            """
            module example.test/project

            require (
                github.com/compose-spec/compose-go/v2 v2.13.0
            )
            """,
            "v2.13.0",
        )

    def assert_module_version(self, go_mod_text: str, expected: str) -> None:
        with tempfile.TemporaryDirectory() as directory:
            go_mod = Path(directory) / "go.mod"
            go_mod.write_text(go_mod_text, encoding="utf-8")

            result = subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).with_name("go-module-version.py")),
                    "--go-mod",
                    str(go_mod),
                    "github.com/compose-spec/compose-go/v2",
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.stdout.strip(), expected)


if __name__ == "__main__":
    unittest.main()
