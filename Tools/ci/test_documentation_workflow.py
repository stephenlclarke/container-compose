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

    def test_documentation_is_release_only_and_preserves_independent_sites(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        triggers = workflow[
            workflow.index("on:\n") : workflow.index("permissions:\n")
        ]
        resolve_job = workflow[
            workflow.index("  resolve-release:\n") : workflow.index("  build-sites:\n")
        ]
        build_job = workflow[
            workflow.index("  build-sites:\n") : workflow.index("  upload-pages-artifact:\n")
        ]

        self.assertIn("  workflow_dispatch:\n", triggers)
        self.assertIn("        required: true\n", triggers)
        self.assertNotIn("  schedule:\n", triggers)
        self.assertNotIn("  push:\n", triggers)
        self.assertNotIn("  pull_request:\n", triggers)
        self.assertIn("Require exact published release inputs", resolve_job)
        self.assertIn("Checkout tagged container-compose source", resolve_job)
        self.assertIn("    needs: resolve-release\n", build_job)
        self.assertIn("      fail-fast: false\n", build_job)
        self.assertIn("Restore SwiftPM documentation cache", build_job)
        self.assertIn("Restore exact DocC site", build_job)
        self.assertIn("steps.site-cache.outputs.cache-hit != 'true'", build_job)
        self.assertIn("Verify reusable DocC site", build_job)

    def test_release_work_is_queued_instead_of_discarding_pending_runs(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")

        self.assertIn("  queue: max\n", workflow)


if __name__ == "__main__":
    unittest.main()
