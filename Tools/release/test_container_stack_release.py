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

"""Regression tests for stable release policy in the stack helper."""

import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[2] / "scripts" / "CONTAINER_STACK_RELEASE.sh"
ROOT = SCRIPT.parent.parent
TEMPLATE = ROOT / "Tools" / "release" / "container-compose.rb.in"
HOMEBREW_WORKFLOW = ROOT / ".github" / "workflows" / "homebrew.yml"


class ContainerStackReleasePolicyTests(unittest.TestCase):
    """Stable releases must be new, immutable, and tap-owned."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.script = SCRIPT.read_text(encoding="utf-8")

    def test_existing_stable_tags_are_rejected_before_release_mutation(self) -> None:
        release = self.script[self.script.index("release_current_stack() {") :]
        self.assertIn("ensure_new_stable_release \"${version}\"", release)
        self.assertLess(
            release.index("ensure_new_stable_release \"${version}\""),
            release.index("bump_compose_version_files"),
        )
        self.assertIn("tag_new_stable_version() {", self.script)
        self.assertIn("stable tag already exists locally", self.script)
        self.assertIn("stable tag already exists remotely", self.script)

    def test_release_helper_has_no_existing_stable_package_mode(self) -> None:
        self.assertNotIn("package VERSION", self.script)
        self.assertNotIn("package_existing_stable", self.script)
        self.assertNotIn("sync_source_homebrew_formula", self.script)

    def test_release_formula_is_tap_owned_and_template_backed(self) -> None:
        self.assertFalse((ROOT / "Formula" / "container-compose.rb").exists())
        self.assertTrue(TEMPLATE.is_file())
        workflow = HOMEBREW_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("Tools/release/container-compose.rb.in", workflow)
        self.assertNotIn("Formula/container-compose.rb", workflow)

    def test_release_gate_includes_sibling_coverage_and_runtime_integration(self) -> None:
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        self.assertIn("check-licenses vet lint coverage build", makefile)
        self.assertIn("check containerization examples docs coverage integration", makefile)
        self.assertIn("check container dsym docs coverage", makefile)
        self.assertIn("CONTAINER_COMPOSE_BUILD_CHECK_LIVE=1", makefile)
        self.assertIn("docker-compose-devices-parity", makefile)
        self.assertNotIn("repackage-release", makefile)

    def test_release_helper_fetches_tags_before_resolving_versions(self) -> None:
        self.assertIn("fetch --prune --tags", self.script)

    def test_release_helper_only_force_refreshes_the_legacy_package_pointer(self) -> None:
        self.assertIn(
            "+refs/tags/homebrew-main:refs/tags/homebrew-main", self.script
        )
        self.assertIn("legacy mutable pointer", self.script)
        self.assertNotIn("fetch --prune --tags --force", self.script)


if __name__ == "__main__":
    unittest.main()
