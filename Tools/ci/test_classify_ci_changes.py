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

"""Focused tests for the CI changed-file classifier."""

import importlib.util
import sys
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("classify-ci-changes.py")
SPEC = importlib.util.spec_from_file_location("classify_ci_changes", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
CLASSIFIER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CLASSIFIER
SPEC.loader.exec_module(CLASSIFIER)


class ClassifyCIChangesTests(unittest.TestCase):
    def test_controller_changes_select_tools_without_runtime(self) -> None:
        scope = CLASSIFIER.classify(
            [
                ".github/workflows/docs.yml",
                "Tools/release/test_container_stack_release.py",
                "scripts/CONTAINER_STACK_RELEASE.sh",
            ]
        )

        self.assertTrue(scope.heavy)
        self.assertTrue(scope.tools)
        self.assertFalse(scope.runtime)
        self.assertFalse(scope.handoff)

    def test_runtime_changes_select_runtime_without_tool_suites(self) -> None:
        scope = CLASSIFIER.classify(
            ["Sources/ComposeCore/Project.swift", "Tests/ComposeCoreTests/ProjectTests.swift"]
        )

        self.assertTrue(scope.heavy)
        self.assertFalse(scope.tools)
        self.assertTrue(scope.runtime)

    def test_go_normalizer_is_runtime_work(self) -> None:
        scope = CLASSIFIER.classify(["Tools/compose-normalizer/main.go"])

        self.assertTrue(scope.runtime)
        self.assertFalse(scope.tools)

    def test_recoverable_stack_inputs_select_runtime_and_tool_tests(self) -> None:
        for path in ("Tools/build/stack-pin.py", "Tools/release/stack-refs.json"):
            with self.subTest(path=path):
                scope = CLASSIFIER.classify([path])
                self.assertTrue(scope.heavy)
                self.assertTrue(scope.tools)
                self.assertTrue(scope.runtime)

    def test_swift_runtime_drivers_select_both_scopes(self) -> None:
        for path in sorted(CLASSIFIER.RUNTIME_DRIVER_PATHS):
            with self.subTest(path=path):
                scope = CLASSIFIER.classify([path])
                self.assertTrue(scope.heavy)
                self.assertTrue(scope.tools)
                self.assertTrue(scope.runtime)

    def test_mixed_and_makefile_changes_select_both_scopes(self) -> None:
        for paths in (
            ["Sources/ComposePlugin/ComposePlugin.swift", "Tools/ci/tool.py"],
            ["Makefile"],
        ):
            with self.subTest(paths=paths):
                scope = CLASSIFIER.classify(paths)
                self.assertTrue(scope.tools)
                self.assertTrue(scope.runtime)

    def test_rename_paths_retain_the_removed_runtime_scope(self) -> None:
        scope = CLASSIFIER.classify(
            ["Tools/ci/renamed-helper.py", "Sources/ComposeCore/OldHelper.swift"]
        )

        self.assertTrue(scope.tools)
        self.assertTrue(scope.runtime)

    def test_ci_workflow_changes_validate_the_runtime_lane_they_can_edit(self) -> None:
        scope = CLASSIFIER.classify([".github/workflows/ci.yml"])

        self.assertTrue(scope.tools)
        self.assertTrue(scope.runtime)

    def test_documentation_and_handoff_changes_stay_lightweight(self) -> None:
        scope = CLASSIFIER.classify(
            ["README.md", "docs/STATUS.md", "docs/upstream/apple-container/PR-1.md"]
        )

        self.assertFalse(scope.heavy)
        self.assertFalse(scope.tools)
        self.assertFalse(scope.runtime)
        self.assertTrue(scope.handoff)

    def test_full_and_unknown_inputs_fail_safe(self) -> None:
        for scope in (
            CLASSIFIER.classify([], full=True),
            CLASSIFIER.classify([]),
            CLASSIFIER.classify(["new-build-input.xyz"]),
            CLASSIFIER.classify(["../outside"]),
        ):
            with self.subTest(scope=scope):
                self.assertTrue(scope.heavy)
                self.assertTrue(scope.tools)
                self.assertTrue(scope.runtime)


if __name__ == "__main__":
    unittest.main()
