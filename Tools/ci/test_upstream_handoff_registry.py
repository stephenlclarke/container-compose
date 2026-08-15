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

"""Tests for the generated upstream handoff registry."""

from __future__ import annotations

import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("upstream-handoff-registry.py")
SPEC = importlib.util.spec_from_file_location(
    "upstream_handoff_registry",
    MODULE_PATH,
)
assert SPEC is not None and SPEC.loader is not None
registry = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = registry
SPEC.loader.exec_module(registry)


class UpstreamHandoffRegistryTests(unittest.TestCase):
    def create_repository(
        self,
    ) -> tuple[tempfile.TemporaryDirectory[str], Path, str]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(
            ["git", "config", "user.name", "Test"],
            cwd=root,
            check=True,
        )
        subprocess.run(
            ["git", "config", "user.email", "test@example.com"],
            cwd=root,
            check=True,
        )
        handoff = root / "docs/upstream/apple-container"
        handoff.mkdir(parents=True)
        (handoff / "ISSUE-demo.md").write_text(
            "# Demo issue\n\n"
            "Commit `1111111111111111111111111111111111111111`.\n",
            encoding="utf-8",
        )
        (handoff / "PR-demo.md").write_text(
            "# Demo pull request\n\n"
            "Commit `2222222222222222222222222222222222222222`.\n",
            encoding="utf-8",
        )
        subprocess.run(["git", "add", "."], cwd=root, check=True)
        subprocess.run(
            ["git", "commit", "-qm", "fixture"],
            cwd=root,
            check=True,
        )
        commit = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        return temporary, root, commit

    def test_import_pairs_documents_and_preserves_archives(self) -> None:
        temporary, root, commit = self.create_repository()
        self.addCleanup(temporary.cleanup)
        active = Path("docs/upstream/apple-container/PR-demo.md")

        payload = registry.import_legacy(
            root,
            commit,
            "2026-07-29",
            {active},
        )

        self.assertEqual(len(payload["entries"]), 1)
        entry = payload["entries"][0]
        self.assertEqual(entry["id"], "apple-container-demo")
        self.assertEqual(entry["owner"], "apple/container")
        self.assertEqual(entry["title"], "Demo pull request")
        self.assertEqual(entry["state"], "active-draft")
        self.assertEqual(
            entry["commits"],
            [
                "1111111111111111111111111111111111111111",
                "2222222222222222222222222222222222222222",
            ],
        )
        self.assertNotIn("path", entry["documents"][0])
        self.assertEqual(
            entry["documents"][1]["path"],
            active.as_posix(),
        )
        self.assertIn(
            f"/blob/{commit}/",
            entry["documents"][0]["archive"],
        )

    def test_validation_rejects_unregistered_legacy_document(self) -> None:
        temporary, root, commit = self.create_repository()
        self.addCleanup(temporary.cleanup)
        payload = registry.import_legacy(
            root,
            commit,
            "2026-07-29",
            set(),
        )

        errors = registry.validate_registry(payload, root)

        self.assertTrue(
            any(
                "legacy handoff document is not registered as active" in error
                for error in errors
            )
        )

    def test_validation_passes_after_archived_sources_are_removed(self) -> None:
        temporary, root, commit = self.create_repository()
        self.addCleanup(temporary.cleanup)
        payload = registry.import_legacy(
            root,
            commit,
            "2026-07-29",
            set(),
        )
        for path in (root / "docs/upstream").rglob("*.md"):
            path.unlink()

        self.assertEqual(registry.validate_registry(payload, root), [])
        rendered = registry.render_registry(payload)
        self.assertIn("# Upstream Handoff Registry", rendered)
        self.assertIn("Demo pull request", rendered)
        self.assertIn(f"/blob/{commit}/", rendered)

    def test_render_uses_links_relative_to_generated_document(self) -> None:
        temporary, root, commit = self.create_repository()
        self.addCleanup(temporary.cleanup)
        active = Path("docs/upstream/apple-container/PR-demo.md")
        payload = registry.import_legacy(
            root,
            commit,
            "2026-07-29",
            {active},
        )
        (root / "docs/upstream/apple-container/ISSUE-demo.md").unlink()

        rendered = registry.render_registry(payload)

        self.assertIn(
            "[PR details](apple-container/PR-demo.md)",
            rendered,
        )
        self.assertNotIn(
            "[PR details](docs/upstream/apple-container/PR-demo.md)",
            rendered,
        )

    def test_render_escapes_brackets_in_linked_title(self) -> None:
        temporary, root, commit = self.create_repository()
        self.addCleanup(temporary.cleanup)
        payload = registry.import_legacy(
            root,
            commit,
            "2026-07-29",
            set(),
        )
        payload["entries"][0]["title"] = "[container]: stream archive"
        payload["entries"][0]["upstream"] = (
            "https://github.com/apple/container/pull/1"
        )

        rendered = registry.render_registry(payload)

        self.assertIn(
            r"[\[container\]: stream archive]"
            "(https://github.com/apple/container/pull/1)",
            rendered,
        )
        self.assertNotIn("<br>", rendered)

    def test_validation_rejects_unsafe_paths_and_upstream_urls(self) -> None:
        temporary, root, commit = self.create_repository()
        self.addCleanup(temporary.cleanup)
        payload = registry.import_legacy(
            root,
            commit,
            "2026-07-29",
            set(),
        )
        for path in (root / "docs/upstream").rglob("*.md"):
            path.unlink()
        entry = payload["entries"][0]
        entry["upstream"] = "https://github.com/apple/container/pull/not-a-number"
        entry["documents"][0]["path"] = "../../outside.md"

        errors = registry.validate_registry(payload, root)

        self.assertTrue(
            any("must be a GitHub pull-request URL" in error for error in errors)
        )
        self.assertTrue(
            any("path must stay under docs/upstream" in error for error in errors)
        )

    def test_validation_reports_non_string_path_without_crashing(self) -> None:
        temporary, root, commit = self.create_repository()
        self.addCleanup(temporary.cleanup)
        payload = registry.import_legacy(
            root,
            commit,
            "2026-07-29",
            set(),
        )
        for path in (root / "docs/upstream").rglob("*.md"):
            path.unlink()
        payload["entries"][0]["documents"][0]["path"] = 42

        errors = registry.validate_registry(payload, root)

        self.assertTrue(
            any("path must be a string" in error for error in errors)
        )

    def test_validation_rejects_duplicate_document_registrations(self) -> None:
        temporary, root, commit = self.create_repository()
        self.addCleanup(temporary.cleanup)
        active = Path("docs/upstream/apple-container/PR-demo.md")
        payload = registry.import_legacy(
            root,
            commit,
            "2026-07-29",
            {active},
        )
        (root / "docs/upstream/apple-container/ISSUE-demo.md").unlink()
        duplicate = dict(payload["entries"][0]["documents"][1])
        payload["entries"][0]["documents"].append(duplicate)

        errors = registry.validate_registry(payload, root)

        self.assertTrue(
            any(
                "active handoff document is registered more than once" in error
                for error in errors
            )
        )
        self.assertTrue(
            any(
                "archived handoff document is registered more than once"
                in error
                for error in errors
            )
        )

    def test_validation_allows_new_active_document_without_archive(self) -> None:
        temporary, root, commit = self.create_repository()
        self.addCleanup(temporary.cleanup)
        active = Path("docs/upstream/apple-container/PR-demo.md")
        payload = registry.import_legacy(
            root,
            commit,
            "2026-07-29",
            {active},
        )
        (root / "docs/upstream/apple-container/ISSUE-demo.md").unlink()
        payload["entries"][0]["documents"] = [
            {
                "kind": "pull-request",
                "path": active.as_posix(),
            }
        ]

        self.assertEqual(registry.validate_registry(payload, root), [])

    def test_rewrite_replaces_relative_retired_handoff_links(self) -> None:
        temporary, root, commit = self.create_repository()
        self.addCleanup(temporary.cleanup)
        payload = registry.import_legacy(
            root,
            commit,
            "2026-07-29",
            set(),
        )
        current = root / "docs/project/STATUS.md"
        current.parent.mkdir(parents=True, exist_ok=True)
        current.write_text(
            "[handoff](../upstream/apple-container/PR-demo.md)\n",
            encoding="utf-8",
        )
        for path in (root / "docs/upstream").rglob("*.md"):
            path.unlink()

        self.assertEqual(len(registry.archived_relative_link_errors(payload, root)), 1)
        changed = registry.rewrite_archived_links(payload, root)

        self.assertEqual(changed, [Path("docs/project/STATUS.md")])
        self.assertEqual(
            registry.archived_relative_link_errors(payload, root),
            [],
        )
        self.assertIn(
            f"/blob/{commit}/docs/upstream/apple-container/PR-demo.md",
            current.read_text(encoding="utf-8"),
        )

    def test_main_check_detects_stale_rendered_output(self) -> None:
        temporary, root, commit = self.create_repository()
        self.addCleanup(temporary.cleanup)
        payload = registry.import_legacy(
            root,
            commit,
            "2026-07-29",
            set(),
        )
        for path in (root / "docs/upstream").rglob("*.md"):
            path.unlink()
        registry_path = root / "docs/upstream/HANDOFF-REGISTRY.json"
        rendered_path = root / "docs/upstream/HANDOFF-REGISTRY.md"
        registry_path.write_text(
            json.dumps(payload),
            encoding="utf-8",
        )
        rendered_path.write_text("stale\n", encoding="utf-8")

        stderr = io.StringIO()
        with redirect_stderr(stderr):
            result = registry.main(
                [
                    "--root",
                    str(root),
                    "--registry",
                    str(registry_path),
                    "--rendered",
                    str(rendered_path),
                    "check",
                ]
            )

        self.assertEqual(result, 1)
        self.assertIn("rendered handoff registry is stale", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
