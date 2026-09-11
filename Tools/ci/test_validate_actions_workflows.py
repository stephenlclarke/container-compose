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

import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("validate-actions-workflows.py")
SPEC = importlib.util.spec_from_file_location("validate_actions_workflows", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ValidateActionsWorkflowsTests(unittest.TestCase):
    def workflow(self, source: str) -> Path:
        temporary = tempfile.NamedTemporaryFile(suffix=".yml", delete=False)
        self.addCleanup(Path(temporary.name).unlink, missing_ok=True)
        path = Path(temporary.name)
        temporary.close()
        path.write_text(source, encoding="utf-8")
        return path

    def test_removes_only_valid_queue_extension_for_actionlint(self) -> None:
        source = "name: CI\nconcurrency:\n  group: release\n  queue: max\njobs: {}\n"
        self.assertNotIn("queue:", MODULE.compatible_source(self.workflow(source)))

    def test_rejects_unknown_queue_value_or_location(self) -> None:
        for source in (
            "concurrency:\n  queue: newest\n",
            "jobs:\n  queue: max\n",
        ):
            with self.subTest(source=source):
                with self.assertRaises(MODULE.WorkflowError):
                    MODULE.compatible_source(self.workflow(source))


if __name__ == "__main__":
    unittest.main()
