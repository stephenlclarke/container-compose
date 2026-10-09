#!/usr/bin/env python3
# Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0
"""Bounded offline tests for the Q runtime source-companion inventory helpers."""
from __future__ import annotations

import importlib.util
import io
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

MODULE_PATH = Path(__file__).with_name("build_runtime_source_companion.py")
SPEC = importlib.util.spec_from_file_location("runtime_source_companion", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class RuntimeSourceCompanionTests(unittest.TestCase):
    @staticmethod
    def git(directory: Path, *arguments: str) -> str:
        result = subprocess.run(["git", "-C", str(directory), *arguments],
                                check=True, capture_output=True, text=True)
        return result.stdout.strip()

    @classmethod
    def repository(cls, root: Path, name: str, *, nested: Path | None = None) -> tuple[Path, str]:
        directory = root / name
        directory.mkdir()
        cls.git(directory, "init", "-q")
        cls.git(directory, "config", "user.email", "source-test@example.invalid")
        cls.git(directory, "config", "user.name", "Source Test")
        (directory / "LICENSE").write_text(f"{name} notice\n")
        cls.git(directory, "add", "LICENSE")
        cls.git(directory, "commit", "-qm", "source")
        if nested is not None:
            cls.git(directory, "update-index", "--add", "--cacheinfo",
                    f"160000,{cls.git(nested, 'rev-parse', 'HEAD')},nested")
            cls.git(directory, "commit", "-qm", "nested gitlink")
            (directory / "nested").mkdir()
            (directory / "nested" / ".git").write_text(
                f"gitdir: {nested / '.git'}\n")
            cls.git(directory / "nested", "checkout", "--detach", "-q",
                    cls.git(nested, "rev-parse", "HEAD"))
        return directory, cls.git(directory, "rev-parse", "HEAD")

    def test_go_module_cache_escaping_preserves_path_separators(self):
        path = module.go_module_cache_path(Path("/cache"), "github.com/AWS/aws-sdk-go/v2", "v2.1.0")
        self.assertEqual(str(path), "/cache/github.com/!a!w!s/aws-sdk-go/v2@v2.1.0")

    def test_go_mod_requirements_are_deduplicated_and_sorted(self):
        rows = module.module_requirements(
            "module example.test/x\nrequire (\n example.com/b v1.0.0\n example.com/a v1.2.0\n)\n")
        self.assertEqual(rows, [("example.com/a", "v1.2.0"), ("example.com/b", "v1.0.0")])

    def test_source_tree_rejects_escaping_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = (Path(directory) / "module").resolve()
            root.mkdir()
            (root / "LICENSE").write_text("license\n")
            (root / "escape").symlink_to("../../outside")
            with self.assertRaisesRegex(module.InventoryError, "escaping file symlink"):
                module.safe_tree(root)

    def test_canonical_runtime_payload_hash_uses_stable_json(self):
        value = {"bin/container": "a" * 64, "bin/plugin": "b" * 64}
        self.assertEqual(module.digest(module.canonical(value)), module.digest(module.canonical(dict(reversed(list(value.items()))))))

    def test_license_like_candidates_include_notice_and_patents_names(self):
        self.assertTrue("NOTICE.txt".lower().startswith(module.LICENSE_PREFIXES))
        self.assertTrue("PATENTS".lower().startswith(module.LICENSE_PREFIXES))
        self.assertFalse("Dockerfile".lower().startswith(module.LICENSE_PREFIXES))

    def test_recursive_gitlink_source_is_archived_at_exact_commits(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            leaf, leaf_commit = self.repository(root, "leaf")
            child, child_commit = self.repository(root, "child", nested=leaf)
            parent, _ = self.repository(root, "parent")
            self.git(parent, "update-index", "--add", "--cacheinfo",
                     f"160000,{child_commit},vendor/child")
            self.git(parent, "commit", "-qm", "child gitlink")
            (parent / "vendor").mkdir()
            (parent / "vendor" / "child").mkdir()
            (parent / "vendor" / "child" / ".git").write_text(
                f"gitdir: {child / '.git'}\n")
            self.git(parent / "vendor" / "child", "checkout", "--detach", "-q", child_commit)
            (parent / "vendor" / "child" / "nested").mkdir()
            (parent / "vendor" / "child" / "nested" / ".git").write_text(
                f"gitdir: {leaf / '.git'}\n")
            self.git(parent / "vendor" / "child" / "nested", "checkout", "--detach", "-q", leaf_commit)

            output = io.BytesIO()
            licenses = []
            inventory = []
            with tarfile.open(fileobj=output, mode="w") as archive:
                module.add_gitlink_tree(archive, parent / "vendor" / "child", child_commit,
                                        "runtime/vendor/child", licenses, inventory)

            output.seek(0)
            with tarfile.open(fileobj=output, mode="r:") as archive:
                self.assertEqual(archive.extractfile(
                    "runtime/vendor/child/LICENSE").read(), b"child notice\n")
                self.assertEqual(archive.extractfile(
                    "runtime/vendor/child/nested/LICENSE").read(), b"leaf notice\n")
            self.assertEqual([row["commit"] for row in inventory], [child_commit, leaf_commit])
            self.assertEqual([row["path"] for row in inventory], [
                "runtime/vendor/child", "runtime/vendor/child/nested"])
            self.assertEqual({row["path"] for row in licenses}, {
                "runtime/vendor/child/LICENSE", "runtime/vendor/child/nested/LICENSE"})

    def test_gitlink_checkout_must_match_pinned_commit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo, commit = self.repository(root, "pinned")
            self.git(repo, "checkout", "--orphan", "replacement")
            (repo / "LICENSE").write_text("replacement\n")
            self.git(repo, "add", "LICENSE")
            self.git(repo, "commit", "-qm", "replacement")
            with tarfile.open(fileobj=io.BytesIO(), mode="w") as archive:
                with self.assertRaisesRegex(module.InventoryError, "does not match its pinned commit"):
                    module.add_gitlink_tree(archive, repo, commit, "runtime/vendor/pinned", [], [])


if __name__ == "__main__":
    unittest.main()
