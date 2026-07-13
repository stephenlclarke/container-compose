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

import json
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
                    "--stack-refs",
                    str(Path(directory) / "missing-stack-refs.json"),
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
                    "--tag-prefix",
                    "missing-prefix-",
                    "--stack-refs",
                    str(Path(directory) / "missing-stack-refs.json"),
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.stdout.strip(), expected)

    def test_uses_explicit_stack_manifest_before_remote_tags(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            remote = root / "container"
            self.init_repo(remote)
            remote_ref = self.git(remote, "rev-parse", "HEAD")
            manifest_ref = "a" * 40
            manifest = root / "stack-refs.json"
            manifest.write_text(
                json.dumps(
                    {
                        "components": {
                            "container": {
                                "ref": manifest_ref,
                            },
                        },
                    },
                ),
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).with_name("resolve-container-ref.py")),
                    "--repo",
                    str(root / "missing-checkout"),
                    "--remote",
                    str(remote),
                    "--stack-refs",
                    str(manifest),
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(remote_ref, manifest_ref)
            self.assertEqual(result.stdout.strip(), manifest_ref)

    def test_prefers_latest_remote_current_tag_prefix_before_remote_branch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            remote = Path(directory) / "container"
            self.init_repo(remote)
            old_expected = self.git(remote, "rev-parse", "HEAD")
            self.git(remote, "tag", "--no-sign", f"current-41-{old_expected[:12]}")
            (remote / "README.md").write_text("# test\n\nupdated\n", encoding="utf-8")
            self.git(remote, "add", "README.md")
            self.git(remote, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "test update")
            expected = self.git(remote, "rev-parse", "HEAD")
            self.git(remote, "tag", "--no-sign", f"current-42-{expected[:12]}")
            (remote / "README.md").write_text("# test\n\nupdated again\n", encoding="utf-8")
            self.git(remote, "add", "README.md")
            self.git(remote, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "test branch ahead")

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
                    "--stack-refs",
                    str(Path(directory) / "missing-stack-refs.json"),
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.stdout.strip(), expected)

    def test_stack_manifest_is_canonical_and_rejects_a_mismatched_checkout(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            remote = root / "container"
            self.init_repo(remote)
            expected = self.git(remote, "rev-parse", "HEAD")
            manifest = root / "stack-refs.json"
            manifest.write_text(
                '{"components":{"container":{"ref":"' + expected + '"}}}',
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).with_name("resolve-container-ref.py")),
                    "--repo",
                    str(remote),
                    "--remote",
                    str(root / "missing-remote"),
                    "--stack-refs",
                    str(manifest),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.stdout.strip(), expected)

            (remote / "README.md").write_text("# later\n", encoding="utf-8")
            self.git(remote, "add", "README.md")
            self.git(remote, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "later")
            mismatch = subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).with_name("resolve-container-ref.py")),
                    "--repo",
                    str(remote),
                    "--remote",
                    str(root / "missing-remote"),
                    "--stack-refs",
                    str(manifest),
                ],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(mismatch.returncode, 0)
            self.assertIn("does not match stack manifest", mismatch.stderr)

    def test_ignores_legacy_homebrew_main_tag_by_default(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            remote = Path(directory) / "container"
            self.init_repo(remote)
            legacy = self.git(remote, "rev-parse", "HEAD")
            self.git(remote, "tag", "--no-sign", "homebrew-main")
            (remote / "README.md").write_text("# test\n\nupdated\n", encoding="utf-8")
            self.git(remote, "add", "README.md")
            self.git(remote, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "test update")
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
                    "--stack-refs",
                    str(Path(directory) / "missing-stack-refs.json"),
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(result.stdout.strip(), legacy)
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
