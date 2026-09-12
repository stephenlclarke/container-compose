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

"""Protect release tooling that runs with macOS's system Python 3.9."""

from __future__ import annotations

import ast
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
class Python39CompatibilityTests(unittest.TestCase):
    def test_tools_do_not_use_path_stat_follow_symlinks(self) -> None:
        offenders = []
        for script in sorted((ROOT / "Tools").rglob("*.py")):
            if script.name.startswith("test_"):
                continue
            tree = ast.parse(script.read_text(encoding="utf-8"), filename=str(script))
            for node in ast.walk(tree):
                if not isinstance(node, ast.Call):
                    continue
                function = node.func
                if not isinstance(function, ast.Attribute) or function.attr != "stat":
                    continue
                if isinstance(function.value, ast.Name) and function.value.id == "os":
                    continue
                if any(keyword.arg == "follow_symlinks" for keyword in node.keywords):
                    offenders.append(
                        f"{script.relative_to(ROOT)}:{node.lineno}"
                    )

        self.assertEqual(
            offenders,
            [],
            "Path.stat(follow_symlinks=...) requires Python 3.10; use "
            "Path.lstat() for the macOS system Python 3.9 release path",
        )


if __name__ == "__main__":
    unittest.main()
