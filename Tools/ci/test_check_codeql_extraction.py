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

"""Focused fixtures for CodeQL source-extraction evidence."""

import json
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


CHECKER = Path(__file__).with_name("check-codeql-extraction.py")
GO_INVENTORY = Path(__file__).with_name("write-go-codeql-inventory.py")


class ExtractionInventoryTests(unittest.TestCase):
    def check(self, language: str, paths: list[str], invocations: list[dict],
              *, require_clean: bool = False, alerts: list[dict] | None = None) -> tuple[int, dict]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            sarif = root / "results.sarif"
            inventory = root / "inventory.txt"
            output = root / "report.json"
            sarif.write_text(json.dumps({"runs": [{"invocations": invocations, "results": alerts or []}]}))
            inventory.write_text("\n".join(paths) + "\n")
            command = [sys.executable, str(CHECKER), "--language", language,
                       "--sarif", str(sarif), "--inventory", str(inventory),
                       "--output", str(output)]
            if require_clean:
                command.append("--require-clean")
            result = subprocess.run(
                command,
                capture_output=True, text=True, check=False,
            )
            return result.returncode, json.loads(output.read_text())

    @staticmethod
    def invocation(language: str, paths: list[str], succeeded: bool = True) -> dict:
        return {
            "executionSuccessful": succeeded,
            "toolExecutionNotifications": [{
                "descriptor": {"id": f"{language}/diagnostics/successfully-extracted-files"},
                "locations": [{"physicalLocation": {"artifactLocation": {
                    "uri": path, "uriBaseId": "%SRCROOT%"
                }}} for path in paths],
            }],
        }

    def test_swift_success_requires_every_inventoried_source(self) -> None:
        paths = ["Sources/ComposeCore/A.swift", "Sources/ComposePlugin/B.swift"]
        status, report = self.check("swift", paths, [self.invocation("swift", paths)])
        self.assertEqual(status, 0)
        self.assertTrue(report["complete"])
        self.assertEqual(report["inventory_extracted_count"], 2)

    def test_go_failure_cannot_be_covered_by_another_successful_invocation(self) -> None:
        path = "Tools/compose-normalizer/main.go"
        status, report = self.check("go", [path], [
            self.invocation("go", [path], succeeded=False),
            self.invocation("go", [], succeeded=True),
        ])
        self.assertEqual(status, 1)
        self.assertFalse(report["invocation_success"])
        self.assertEqual(report["missing"], [path])

    def test_go_excludes_test_files_from_production_inventory(self) -> None:
        path = "Tools/compose-normalizer/main.go"
        status, report = self.check("go", [path], [self.invocation("go", [path])])
        self.assertEqual(status, 0)
        self.assertTrue(report["complete"])

    def test_strict_gate_rejects_alerts_even_with_complete_extraction(self) -> None:
        path = "Sources/ComposeCore/A.swift"
        status, report = self.check("swift", [path], [self.invocation("swift", [path])],
                                    require_clean=True, alerts=[{"ruleId": "swift/example"}])
        self.assertEqual(status, 1)
        self.assertTrue(report["complete"])
        self.assertFalse(report["clean"])

    def test_go_scope_parser_and_selected_sources(self) -> None:
        spec = importlib.util.spec_from_file_location("go_codeql_inventory", GO_INVENTORY)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            package = root / "Tools/compose-normalizer/remote"
            package.mkdir(parents=True)
            payload = json.dumps({"Dir": str(package), "GoFiles": ["cache_unix.go"]})
            payload += "\n" + json.dumps({"Dir": str(package), "GoFiles": ["git_command_unix.go"]})
            packages = module.packages_from_json(payload)
            self.assertEqual(len(packages), 2)
            self.assertEqual(module.selected_sources(packages, root), {
                "Tools/compose-normalizer/remote/cache_unix.go",
                "Tools/compose-normalizer/remote/git_command_unix.go",
            })


if __name__ == "__main__":
    unittest.main()
