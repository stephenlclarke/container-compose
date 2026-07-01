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

"""Unit tests for container dependency ref resolution."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


class ContainerRefResolutionTests(unittest.TestCase):
    """Package metadata should follow the checked-out dependency automatically."""

    def test_prefers_local_container_checkout(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory) / "container"
            self.init_repo(repo)
            expected = self.git(repo, "rev-parse", "HEAD")

            result = subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).with_name("resolve-container-ref.py")),
                    "--repo",
                    str(repo),
                    "--remote",
                    str(Path(directory) / "missing-remote"),
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.stdout.strip(), expected)

    def test_falls_back_to_remote_branch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            remote = Path(directory) / "container"
            self.init_repo(remote)
            expected = self.git(remote, "rev-parse", "HEAD")

            result = subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).with_name("resolve-container-ref.py")),
                    "--repo",
                    str(Path(directory) / "missing-checkout"),
                    "--remote",
                    str(remote),
                    "--branch",
                    "main",
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.stdout.strip(), expected)

    def init_repo(self, repo: Path) -> None:
        repo.mkdir()
        self.git(repo, "init", "-b", "main")
        (repo / "README.md").write_text("# test\n", encoding="utf-8")
        self.git(repo, "add", "README.md")
        self.git(repo, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "test")

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
