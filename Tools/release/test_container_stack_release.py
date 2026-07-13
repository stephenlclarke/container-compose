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

import os
import shlex
import subprocess
import tempfile
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

    def test_stable_tags_are_signed_and_verified_by_github(self) -> None:
        self.assertIn('tag -s "${version}" main', self.script)
        self.assertIn('verify_github_stable_tag_signature "${version}"', self.script)
        self.assertIn("GitHub did not verify stable tag", self.script)

    def test_internal_dependency_pins_do_not_become_release_highlights(self) -> None:
        pin_commit = self.script[
            self.script.index("commit_containerization_package_pin() {") : self.script.index(
                "sync_containerization_package_pins() {"
            )
        ]
        self.assertIn("Release-Note: none", pin_commit)
        self.assertNotIn("Release-Highlight:", pin_commit)

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

    def test_release_helper_preserves_formatted_swiftpm_dependency_pins(self) -> None:
        self.assertIn(r'r"(\s*,?\s*\))"', self.script)

    def test_release_helper_does_not_refresh_legacy_mutable_package_pointers(self) -> None:
        self.assertNotIn("+refs/tags/homebrew-main:refs/tags/homebrew-main", self.script)
        self.assertNotIn("legacy mutable pointer", self.script)
        self.assertNotIn("fetch --prune --tags --force", self.script)

    def test_equivalent_squash_promotion_aligns_local_main(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _remote, local, candidate_tree, remote_head = self.create_equivalent_squash(root)

            result = self.promote_compose_main(root / "github")

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("already promoted", result.stdout)
            self.assertEqual(self.git(local, "rev-parse", "main"), remote_head)
            self.assertEqual(self.git(local, "rev-parse", "main^{tree}"), candidate_tree)
            self.assertEqual(self.git(local, "status", "--short"), "")

    def test_post_promotion_equivalent_squash_aligns_local_main(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _remote, local, candidate_tree, remote_head = self.create_equivalent_squash(root)

            result = self.synchronize_promoted_compose_main(root / "github")

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("already promoted", result.stdout)
            self.assertEqual(self.git(local, "rev-parse", "main"), remote_head)
            self.assertEqual(self.git(local, "rev-parse", "main^{tree}"), candidate_tree)
            self.assertEqual(self.git(local, "status", "--short"), "")

    def test_divergent_promotion_still_requires_revalidation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            remote, local = self.create_compose_checkout(root)
            self.commit_file(local, "candidate.yml", "candidate\n", "feat: gated candidate")
            candidate_head = self.git(local, "rev-parse", "HEAD")

            remote_change = root / "remote-change"
            self.run_command("git", "clone", "--branch", "main", str(remote), str(remote_change))
            self.configure_repo(remote_change)
            self.commit_file(
                remote_change,
                "remote.yml",
                "remote\n",
                "feat: unrelated remote change",
            )
            self.run_command("git", "-C", str(remote_change), "push", "origin", "main")

            result = self.promote_compose_main(root / "github")

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not based on origin/main", result.stderr)
            self.assertEqual(self.git(local, "rev-parse", "main"), candidate_head)

    def test_post_promotion_divergence_does_not_move_local_main(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            remote, local = self.create_compose_checkout(root)
            self.commit_file(local, "candidate.yml", "candidate\n", "feat: gated candidate")
            candidate_head = self.git(local, "rev-parse", "HEAD")

            remote_change = root / "remote-change"
            self.run_command("git", "clone", "--branch", "main", str(remote), str(remote_change))
            self.configure_repo(remote_change)
            self.commit_file(
                remote_change,
                "remote.yml",
                "remote\n",
                "feat: altered remote candidate",
            )
            self.run_command("git", "-C", str(remote_change), "push", "origin", "main")

            result = self.synchronize_promoted_compose_main(root / "github")

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("tree differs from the locally gated candidate", result.stderr)
            self.assertEqual(self.git(local, "rev-parse", "main"), candidate_head)

    def test_merge_promotion_accepts_external_merge_after_auto_merge_rejection(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_directory = root / "bin"
            bin_directory.mkdir()
            state_file = root / "gh-view-state"
            fake_gh = bin_directory / "gh"
            fake_gh.write_text(
                """#!/usr/bin/env bash
set -euo pipefail

if [[ \"$1\" != \"pr\" ]]; then
  exit 1
fi

case \"$2\" in
  view)
    if [[ ! -e \"${GH_STATE_FILE}\" ]]; then
      : > \"${GH_STATE_FILE}\"
      exit 0
    fi
    printf '%s\\n' '2026-07-13T12:00:00Z'
    ;;
  merge)
    exit 1
    ;;
  *)
    exit 1
    ;;
esac
""",
                encoding="utf-8",
            )
            fake_gh.chmod(0o755)

            result = self.run_release_function(
                root,
                "merge_compose_promotion_pr 42",
                shell_setup="\n".join(
                    [
                        f"export GH_STATE_FILE={shlex.quote(str(state_file))}",
                        f"export PATH={shlex.quote(str(bin_directory))}:$PATH",
                    ]
                ),
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("auto-merge was not available", result.stdout)
            self.assertIn("promotion PR already merged: #42", result.stdout)

    def create_compose_checkout(self, root: Path) -> tuple[Path, Path]:
        remote = root / "remote.git"
        local = root / "github" / "container-compose"
        self.run_command("git", "init", "--bare", str(remote))
        local.parent.mkdir(parents=True)
        self.run_command("git", "init", "-b", "main", str(local))
        self.configure_repo(local)
        self.run_command("git", "-C", str(local), "remote", "add", "origin", str(remote))
        self.commit_file(local, "README.md", "base\n", "chore: initial stack")
        self.run_command("git", "-C", str(local), "push", "-u", "origin", "main")
        return remote, local

    def create_equivalent_squash(self, root: Path) -> tuple[Path, Path, str, str]:
        remote, local = self.create_compose_checkout(root)
        self.commit_file(local, "compose.yml", "services: {}\n", "feat: gated candidate")
        candidate_tree = self.git(local, "rev-parse", "HEAD^{tree}")

        squashed = root / "squashed"
        self.run_command("git", "clone", "--branch", "main", str(remote), str(squashed))
        self.configure_repo(squashed)
        self.commit_file(
            squashed,
            "compose.yml",
            "services: {}\n",
            "chore: equivalent squash promotion",
        )
        self.run_command("git", "-C", str(squashed), "push", "origin", "main")
        return remote, local, candidate_tree, self.git(squashed, "rev-parse", "HEAD")

    def configure_repo(self, repo: Path) -> None:
        self.run_command("git", "-C", str(repo), "config", "user.name", "Test")
        self.run_command("git", "-C", str(repo), "config", "user.email", "test@example.com")

    def commit_file(self, repo: Path, name: str, contents: str, subject: str) -> None:
        (repo / name).write_text(contents, encoding="utf-8")
        self.run_command("git", "-C", str(repo), "add", name)
        self.run_command("git", "-C", str(repo), "commit", "-m", subject)

    def promote_compose_main(self, root: Path) -> subprocess.CompletedProcess[str]:
        return self.run_release_function(
            root,
            "promote_compose_main 0.6.70 source 'test promotion' 'test body'",
        )

    def synchronize_promoted_compose_main(self, root: Path) -> subprocess.CompletedProcess[str]:
        path = root / "container-compose"
        candidate_tree = self.git(path, "rev-parse", "main^{tree}")
        return self.run_release_function(
            root,
            " ".join(
                [
                    "synchronize_promoted_compose_main",
                    shlex.quote(str(path)),
                    "origin",
                    shlex.quote(candidate_tree),
                ]
            ),
        )

    def run_release_function(
        self,
        root: Path,
        function_call: str,
        shell_setup: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        lines = [
            "set -euo pipefail",
            "export CONTAINER_STACK_RELEASE_LIBRARY=1",
            f"source {shlex.quote(str(SCRIPT))}",
            f"ROOT={shlex.quote(str(root))}",
            "EXECUTE=1",
            "COMPOSE_MAIN_PROMOTION_MODE=direct",
            "COMPOSE_MAIN_MERGE_MODE=checked-admin",
        ]
        if shell_setup is not None:
            lines.append(shell_setup)
        lines.append(function_call)
        command = "\n".join(lines)
        return subprocess.run(
            ["bash", "-c", command],
            capture_output=True,
            text=True,
            check=False,
            env=os.environ.copy(),
        )

    def git(self, repo: Path, *arguments: str) -> str:
        return self.run_command("git", "-C", str(repo), *arguments).stdout.strip()

    def run_command(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            arguments,
            capture_output=True,
            text=True,
            check=True,
        )


if __name__ == "__main__":
    unittest.main()
