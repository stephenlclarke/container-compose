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

"""Unit tests for prebuilt release note rendering."""

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


def load_module():
    module_path = Path(__file__).with_name("release-notes.py")
    spec = importlib.util.spec_from_file_location("release_notes", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load module: {module_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["release_notes"] = module
    spec.loader.exec_module(module)
    return module


class ReleaseNotesTests(unittest.TestCase):
    """Release notes should show the commits packaged by each lane."""

    def test_main_validation_tag_lists_commits_since_previous_stable_release(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            self.init_repo(repo)
            self.git(repo, "tag", "--no-sign", "0.6.0")
            self.commit(repo, "feat(mounts): support bind propagation")
            self.commit(repo, "docs: refresh compose guidance")

            notes = module.render_release_notes(
                repo=repo,
                release_tag="homebrew-main-123-abcdef123456",
                release_label="Main validation",
                compose_version="0.6.1",
                asset="container-compose-plugin-homebrew-main-release-arm64.tar.gz",
                asset_sha="abc123",
                head_ref="HEAD",
            )

            self.assertIn("Commits since `0.6.0`", notes)
            self.assertIn("## Homebrew Formula", notes)
            self.assertIn("## Promotion", notes)
            self.assertIn("## Asset Retention", notes)
            self.assertIn("Main validation packages do not update the stable Homebrew formula.", notes)
            self.assertIn("They do not move semantic source tags or Homebrew formulae.", notes)
            self.assertIn("feat(mounts): support bind propagation", notes)
            self.assertIn("docs: refresh compose guidance", notes)
            self.assertNotIn("chore: initial import", notes)

    def test_main_validation_tag_rerun_keeps_full_stable_range(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            self.init_repo(repo)
            self.git(repo, "tag", "--no-sign", "0.6.0")
            self.commit(repo, "ci(release): simplify package publishing")
            self.commit(repo, "fix(release): commit new tap formula files")
            self.git(repo, "tag", "--no-sign", "homebrew-main-123-abcdef123456")

            notes = module.render_release_notes(
                repo=repo,
                release_tag="homebrew-main-123-abcdef123456",
                release_label="Main validation",
                compose_version="0.6.1",
                asset="container-compose-plugin-homebrew-main-release-arm64.tar.gz",
                asset_sha="abc123",
                head_ref="HEAD",
            )

            self.assertIn("Commits since `0.6.0`", notes)
            self.assertIn("ci(release): simplify package publishing", notes)
            self.assertIn("fix(release): commit new tap formula files", notes)
            self.assertNotIn("chore: initial import", notes)

    def test_semver_tag_lists_commits_since_previous_semver_release(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            self.init_repo(repo)
            self.git(repo, "tag", "--no-sign", "0.5.0")
            self.commit(repo, "fix(cli): report help topic")
            self.commit(repo, "feat(examples): add monitoring stack")
            self.git(repo, "tag", "--no-sign", "0.6.0")

            notes = module.render_release_notes(
                repo=repo,
                release_tag="0.6.0",
                release_label="stable release",
                compose_version="0.6.0",
                asset="container-compose-plugin-release-arm64.tar.gz",
                asset_sha="abc123",
                head_ref="HEAD",
            )

            self.assertIn("Commits since `0.5.0`", notes)
            self.assertIn("The stable release updates `stephenlclarke/tap/container-compose`", notes)
            self.assertIn("fix(cli): report help topic", notes)
            self.assertIn("feat(examples): add monitoring stack", notes)
            self.assertNotIn("chore: initial import", notes)

    def test_semver_tag_lists_validated_main_changes(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            self.init_repo(repo)
            self.git(repo, "tag", "--no-sign", "0.6.0")
            self.commit(repo, "feat(release): simplify package lanes")
            self.commit(repo, "ci(release): prune older assets")
            self.git(repo, "tag", "--no-sign", "0.6.1")

            notes = module.render_release_notes(
                repo=repo,
                release_tag="0.6.1",
                release_label="stable release",
                compose_version="0.6.1",
                asset="container-compose-plugin-release-arm64.tar.gz",
                asset_sha="abc123",
                head_ref="HEAD",
            )

            self.assertIn("Commits since `0.6.0`", notes)
            self.assertIn("feat(release): simplify package lanes", notes)
            self.assertIn("ci(release): prune older assets", notes)
            self.assertNotIn("chore: initial import", notes)

    def test_first_release_lists_current_commit(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            self.init_repo(repo)

            notes = module.render_release_notes(
                repo=repo,
                release_tag="0.1.0",
                release_label="stable release",
                compose_version="0.1.0",
                asset="container-compose-plugin-release-arm64.tar.gz",
                asset_sha="abc123",
                head_ref="HEAD",
            )

            self.assertIn("Commits included through", notes)
            self.assertIn("chore: initial import", notes)

    def init_repo(self, repo: Path) -> None:
        self.git(repo, "init", "-b", "main")
        self.commit(repo, "chore: initial import")

    def commit(self, repo: Path, message: str) -> None:
        index = len(list(repo.glob("*.txt")))
        (repo / f"{index}.txt").write_text(f"{message}\n", encoding="utf-8")
        self.git(repo, "add", ".")
        self.git(
            repo,
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.com",
            "commit",
            "-m",
            message,
        )

    def git(self, repo: Path, *arguments: str) -> str:
        result = subprocess.run(
            ["git", "-C", str(repo), *arguments],
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip()


if __name__ == "__main__":
    unittest.main()
