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
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("worktree-audit.py")
SPEC = importlib.util.spec_from_file_location("worktree_audit", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
audit = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = audit
SPEC.loader.exec_module(audit)


def git(repository: Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=repository, check=True, capture_output=True, text=True)


def commit_file(repository: Path, name: str, contents: str, message: str) -> None:
    (repository / name).write_text(contents, encoding="utf-8")
    git(repository, "add", name)
    git(repository, "commit", "-m", message)


class WorktreeAuditTests(unittest.TestCase):
    def test_classifies_active_integrated_and_unique_local_branches(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            repository = Path(temporary_directory)
            git(repository, "init", "-b", "main")
            git(repository, "config", "user.email", "test@example.com")
            git(repository, "config", "user.name", "Test User")
            commit_file(repository, "README.md", "base\n", "base")

            git(repository, "switch", "-c", "integrated")
            commit_file(repository, "integrated.txt", "integrated\n", "integrated change")
            git(repository, "switch", "main")
            git(repository, "cherry-pick", "integrated")

            git(repository, "switch", "-c", "active")
            commit_file(repository, "active.txt", "active\n", "active change")
            active_head = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=repository,
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            git(repository, "update-ref", "refs/remotes/origin/active", active_head)

            git(repository, "switch", "main")
            git(repository, "switch", "-c", "retained")
            commit_file(repository, "retained.txt", "retained\n", "retained change")
            git(repository, "switch", "main")

            audits = {entry.name: entry for entry in audit.audit_branches(repository, "main")}

            self.assertEqual(audits["active"].category, "active")
            self.assertEqual(audits["integrated"].category, "integrated")
            self.assertEqual(audits["retained"].category, "retain")

    def test_classifies_a_merged_topic_as_integrated_when_its_patch_is_on_main(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            repository = Path(temporary_directory)
            git(repository, "init", "-b", "main")
            git(repository, "config", "user.email", "test@example.com")
            git(repository, "config", "user.name", "Test User")
            commit_file(repository, "README.md", "base\n", "base")

            git(repository, "switch", "-c", "merged-topic")
            git(repository, "switch", "-c", "contribution")
            commit_file(repository, "feature.txt", "feature\n", "feature")
            git(repository, "switch", "merged-topic")
            git(repository, "merge", "--no-ff", "contribution", "-m", "merge contribution")
            git(repository, "switch", "main")
            git(repository, "cherry-pick", "contribution")
            git(repository, "branch", "-D", "contribution")

            audits = {entry.name: entry for entry in audit.audit_branches(repository, "main")}

            self.assertEqual(audits["merged-topic"].category, "integrated")

    def test_classifies_a_squash_merged_topic_as_integrated(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            repository = Path(temporary_directory)
            git(repository, "init", "-b", "main")
            git(repository, "config", "user.email", "test@example.com")
            git(repository, "config", "user.name", "Test User")
            commit_file(repository, "README.md", "base\n", "base")

            git(repository, "switch", "-c", "squashed-topic")
            commit_file(repository, "first.txt", "first\n", "first change")
            commit_file(repository, "second.txt", "second\n", "second change")

            git(repository, "switch", "main")
            git(repository, "cherry-pick", "--no-commit", "squashed-topic~1", "squashed-topic")
            git(repository, "commit", "-m", "squashed topic")

            audits = {entry.name: entry for entry in audit.audit_branches(repository, "main")}

            self.assertEqual(audits["squashed-topic"].category, "integrated")
