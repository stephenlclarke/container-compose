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

"""Regression tests for the documentation workflow."""

import unittest
from pathlib import Path


WORKFLOW = Path(__file__).parents[2] / ".github" / "workflows" / "docs.yml"


class DocumentationWorkflowTests(unittest.TestCase):
    """Each independent DocC build must remain bounded."""

    def test_fanout_docc_build_has_a_bounded_sixty_minute_window(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        build_job = workflow[
            workflow.index("  build-sites:\n") : workflow.index("  upload-pages-artifact:\n")
        ]

        self.assertIn("    timeout-minutes: 60\n", build_job)
        self.assertNotIn("    timeout-minutes: 45\n", build_job)


if __name__ == "__main__":
    unittest.main()
