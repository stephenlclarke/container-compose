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
import sys
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("update-readme-upstream-metrics.py")
SPEC = importlib.util.spec_from_file_location("update_readme_upstream_metrics", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
updater = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = updater
SPEC.loader.exec_module(updater)


class UpdateReadmeUpstreamMetricsTests(unittest.TestCase):
    def metrics(self) -> list[updater.ReadmeMetric]:
        return [
            updater.ReadmeMetric("containerization", 0, 2, "abc123456789", "abc12345"),
            updater.ReadmeMetric("container", 1, 3, "def123456789", "def12345"),
            updater.ReadmeMetric("container-builder-shim", 0, 5, "fed123456789", "fed12345"),
        ]

    def test_renders_metrics_with_total_and_commit_links(self) -> None:
        rendered = updater.render_metrics_section(self.metrics(), "27 July 2026")

        self.assertIn("27 July 2026 snapshot", rendered)
        self.assertIn("**10 commits ahead of Apple upstream**", rendered)
        self.assertIn("**1 behind, 3 ahead**", rendered)
        self.assertIn("https://github.com/stephenlclarke/container/commit/def123456789", rendered)
        self.assertIn(updater.BEGIN_MARKER, rendered)
        self.assertIn(updater.END_MARKER, rendered)

    def test_resolves_stack_root_from_linked_worktree_common_directory(self) -> None:
        root = Path("/Users/example/github/worktrees/container-compose-change")
        common_dir = "/Users/example/github/container-compose/.git\n"

        resolved = updater.repo_root_from_git_common_dir(root, common_dir)

        self.assertEqual(resolved, Path("/Users/example/github"))

    def test_resolves_stack_root_from_primary_checkout_common_directory(self) -> None:
        root = Path("/Users/example/github/container-compose")

        resolved = updater.repo_root_from_git_common_dir(root, ".git\n")

        self.assertEqual(resolved, Path("/Users/example/github"))

    def test_falls_back_when_common_directory_is_not_a_git_directory(self) -> None:
        root = Path("/Users/example/github/container-compose")

        resolved = updater.repo_root_from_git_common_dir(root, "/tmp/bare-repository")

        self.assertEqual(resolved, Path("/Users/example/github"))

    def test_replaces_legacy_unmarked_metrics_block(self) -> None:
        readme = "\n".join(
            [
                "> [!WARNING]",
                ">",
                "> What started as a 'fun' implementation and old text.",
                ">",
                "> - [`container`](https://example.invalid): **0 behind, 1 ahead** at [`old`](https://example.invalid).",
                ">",
                "> What looks like a local Compose change can therefore require old work.",
                ">",
                "> Apple's [#1769 proposal](https://github.com/apple/container/pull/1769) continues.",
                "",
            ]
        )
        replacement = updater.render_metrics_section(self.metrics(), "27 July 2026")

        updated = updater.replace_metrics_section(readme, replacement)

        self.assertIn("**10 commits ahead of Apple upstream**", updated)
        self.assertIn("> Apple's [#1769 proposal]", updated)
        self.assertNotIn("old text", updated)

    def test_replaces_marked_metrics_block(self) -> None:
        replacement = updater.render_metrics_section(self.metrics(), "27 July 2026")
        readme = (
            "before\n"
            f"> {updater.BEGIN_MARKER}\n"
            "> stale\n"
            f"> {updater.END_MARKER}\n"
            "after\n"
        )

        updated = updater.replace_metrics_section(readme, replacement)

        self.assertTrue(updated.startswith("before\n"))
        self.assertIn("**10 commits ahead of Apple upstream**", updated)
        self.assertTrue(updated.endswith("after\n"))


if __name__ == "__main__":
    unittest.main()
