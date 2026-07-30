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


MODULE_PATH = Path(__file__).with_name("upstream-divergence-report.py")
SPEC = importlib.util.spec_from_file_location("upstream_divergence_report", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
reporter = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = reporter
SPEC.loader.exec_module(reporter)


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=repo,
        capture_output=True,
        check=True,
        text=True,
    )
    return result.stdout.strip()


def init_repo(repo: Path) -> None:
    repo.mkdir(parents=True, exist_ok=True)
    git(repo, "init", "-q", "-b", "main")
    git(repo, "config", "user.email", "test@example.com")
    git(repo, "config", "user.name", "Test User")


def commit_file(repo: Path, name: str, content: str, message: str) -> None:
    path = repo / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    git(repo, "add", name)
    git(repo, "commit", "-q", "-m", message)


def create_fixture(root: Path) -> tuple[Path, Path, Path]:
    upstream = root / "apple"
    fork = root / "fork.git"
    work = root / "work"
    init_repo(upstream)
    commit_file(upstream, "README.md", "base\n", "initial upstream")
    git(root, "clone", "--bare", str(upstream), str(fork))
    git(root, "clone", str(fork), str(work))
    git(work, "remote", "rename", "origin", "fork")
    git(work, "remote", "add", "upstream", str(upstream))
    git(work, "config", "user.email", "test@example.com")
    git(work, "config", "user.name", "Test User")
    return upstream, fork, work


def registry_for(
    upstream: Path,
    work: Path,
    commits: list[str],
    *,
    duplicate: bool = False,
) -> dict[str, object]:
    slices: list[dict[str, object]] = [
        {
            "id": "fixture-maintenance",
            "classification": "support-maintenance",
            "owner": "fixture/fork",
            "reason": "Independent fork maintenance.",
            "upstreamDisposition": "Retain while the fork requires it.",
            "commits": commits,
        }
    ]
    if duplicate:
        slices.append(
            {
                "id": "fixture-duplicate",
                "classification": "generic-runtime-primitive",
                "owner": "fixture/fork",
                "reason": "Duplicate test entry.",
                "upstreamDisposition": "Submit upstream.",
                "commits": commits,
            }
        )
    return {
        "schemaVersion": 1,
        "repositories": {
            "fixture": {
                "upstreamHead": git(upstream, "rev-parse", "HEAD"),
                "forkHead": git(work, "rev-parse", "fork/main"),
                "slices": slices,
            }
        },
    }


class UpstreamDivergenceReportTests(unittest.TestCase):
    def spec(self) -> reporter.RepoSpec:
        return reporter.RepoSpec(
            name="fixture",
            relative_path="work",
            fork_remotes=("fork",),
            upstream_remotes=("upstream",),
        )

    def test_repo_root_from_primary_checkout_common_dir(self) -> None:
        root = Path("/tmp/github/container-compose")

        repo_root = reporter.repo_root_from_git_common_dir(root, ".git")

        self.assertEqual(repo_root, Path("/tmp/github").resolve())

    def test_repo_root_from_linked_worktree_common_dir(self) -> None:
        root = Path("/tmp/github/worktrees/container-compose-review")

        repo_root = reporter.repo_root_from_git_common_dir(
            root,
            "/tmp/github/container-compose/.git",
        )

        self.assertEqual(repo_root, Path("/tmp/github").resolve())

    def test_repo_root_falls_back_for_nonstandard_common_dir(self) -> None:
        root = Path("/tmp/github/container-compose")

        repo_root = reporter.repo_root_from_git_common_dir(
            root,
            "/tmp/git-metadata/container-compose",
        )

        self.assertEqual(repo_root, root.parent)

    def test_reports_fork_and_upstream_divergence(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            upstream, _, work = create_fixture(root)
            commit_file(work, "fork-only.txt", "fork\n", "add fork feature")
            git(work, "push", "fork", "main")
            commit_file(upstream, "upstream-only.txt", "upstream\n", "add upstream fix")

            report = reporter.analyze_repository(self.spec(), root, fetch=True, max_commits=5)

            self.assertEqual(report.local_to_upstream.ahead, 1)
            self.assertEqual(report.local_to_upstream.behind, 1)
            self.assertEqual(report.fork_to_upstream.ahead, 1)
            self.assertEqual(report.fork_to_upstream.behind, 1)
            self.assertEqual(report.local_to_fork.ahead, 0)
            self.assertEqual(report.merge_upstream_into_local.status, "clean")
            self.assertEqual([commit.subject for commit in report.local_only_commits], ["add fork feature"])
            self.assertEqual([commit.subject for commit in report.upstream_only_commits], ["add upstream fix"])

    def test_detects_apple_upstream_merge_conflicts(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            upstream, _, work = create_fixture(root)
            commit_file(work, "README.md", "fork\n", "change fork readme")
            git(work, "push", "fork", "main")
            commit_file(upstream, "README.md", "upstream\n", "change upstream readme")

            report = reporter.analyze_repository(self.spec(), root, fetch=True, max_commits=5)

            self.assertEqual(report.merge_upstream_into_local.status, "conflicts")
            self.assertEqual(report.merge_upstream_into_local.files, ["README.md"])

    def test_strict_mode_flags_dirty_unpushed_and_conflicted_repos(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            upstream, _, work = create_fixture(root)
            commit_file(work, "README.md", "fork\n", "change fork readme")
            commit_file(upstream, "README.md", "upstream\n", "change upstream readme")
            (work / "untracked.txt").write_text("dirty\n", encoding="utf-8")

            stack_report = reporter.build_report(root, fetch=True, max_commits=5, specs=(self.spec(),))
            failures = reporter.strict_failures(stack_report)

            self.assertIn("fixture: dirty worktree", failures)
            self.assertIn("fixture: local commits are not pushed to the fork remote", failures)
            self.assertIn("fixture: Apple upstream merge conflicts", failures)

    def test_release_strict_mode_blocks_forks_behind_upstream(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            upstream, _, _ = create_fixture(root)
            commit_file(upstream, "upstream-only.txt", "upstream\n", "add upstream fix")

            stack_report = reporter.build_report(root, fetch=True, max_commits=5, specs=(self.spec(),))
            failures = reporter.strict_failures(stack_report, require_upstream_current=True)

            self.assertIn("fixture: fork main is 1 commit(s) behind Apple upstream", failures)

    def test_validates_every_patch_unique_nonmerge_commit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            upstream, _, work = create_fixture(root)
            commit_file(work, "fork-only.txt", "fork\n", "add fork feature")
            git(work, "push", "fork", "main")
            commit_hash = git(work, "rev-parse", "HEAD")
            registry = registry_for(upstream, work, [commit_hash])

            report = reporter.analyze_repository(
                self.spec(),
                root,
                fetch=True,
                max_commits=5,
                classification_registry=registry,
            )

            self.assertEqual(report.fork_classifications.status, "current")
            self.assertEqual(report.fork_classifications.classified, 1)
            self.assertEqual(report.fork_classifications.total, 1)
            self.assertEqual(report.fork_classifications.counts, {"support-maintenance": 1})

    def test_strict_classification_check_rejects_unclassified_commit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            upstream, _, work = create_fixture(root)
            commit_file(work, "fork-only.txt", "fork\n", "add fork feature")
            git(work, "push", "fork", "main")
            registry = registry_for(upstream, work, [])
            registry["repositories"]["fixture"]["slices"] = []

            stack_report = reporter.build_report(
                root,
                fetch=True,
                max_commits=5,
                specs=(self.spec(),),
                classification_registry=registry,
            )
            failures = reporter.strict_failures(stack_report, require_classifications=True)
            classification_failures = reporter.classification_failures(stack_report)

            self.assertEqual(stack_report.repositories[0].fork_classifications.status, "stale")
            self.assertIn("fixture: fork commit classifications are stale (0/1)", failures)
            self.assertEqual(
                classification_failures,
                ["fixture: fork commit classifications are stale (0/1)"],
            )

    def test_rejects_duplicate_classification_and_stale_heads(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            upstream, _, work = create_fixture(root)
            commit_file(work, "fork-only.txt", "fork\n", "add fork feature")
            git(work, "push", "fork", "main")
            commit_hash = git(work, "rev-parse", "HEAD")
            registry = registry_for(upstream, work, [commit_hash], duplicate=True)
            registry["repositories"]["fixture"]["forkHead"] = "0" * 40

            report = reporter.analyze_repository(
                self.spec(),
                root,
                fetch=True,
                max_commits=5,
                classification_registry=registry,
            )

            self.assertEqual(report.fork_classifications.status, "stale")
            self.assertTrue(
                any("duplicate classified commits" in error for error in report.fork_classifications.errors)
            )
            self.assertTrue(
                any("registry forkHead" in error for error in report.fork_classifications.errors)
            )

    def test_renders_markdown_and_json_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _, _, work = create_fixture(root)
            commit_file(work, "fork-only.txt", "fork\n", "add fork feature")
            git(work, "push", "fork", "main")

            stack_report = reporter.build_report(root, fetch=True, max_commits=5, specs=(self.spec(),))
            markdown = reporter.render_markdown(stack_report)
            json_output = reporter.report_to_json(stack_report)

            self.assertIn("# Upstream Divergence Report", markdown)
            self.assertIn("`fixture`", markdown)
            self.assertIn('"repository_count": 1', json_output)


if __name__ == "__main__":
    unittest.main()
