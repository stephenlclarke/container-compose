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
import json
import subprocess
import sys
import tempfile
import textwrap
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
            self.assertIn("## Highlights", notes)
            self.assertIn("Support bind propagation.", notes)
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
            self.commit(repo, "fix(integration): preserve serial rootfs")
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
            self.assertIn("fix(integration): preserve serial rootfs", notes)
            self.assertNotIn("## Highlights", notes)
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
            self.assertIn(
                "Stable release promotion runs `make release-gate`, promotes `container-compose` through the pull-request path, and verifies the promoted main tree before dispatching the package workflow.",
                notes,
            )
            self.assertIn(
                "The package workflow repeats `make ci` before publishing package assets or updating the tap.",
                notes,
            )
            self.assertIn(
                "`make release-gate` runs builder, containerization, and container coverage and runtime integration checks, Compose CI, and the full Docker Compose parity suite.",
                notes,
            )
            self.assertIn("fix(cli): report help topic", notes)
            self.assertIn("feat(examples): add monitoring stack", notes)
            self.assertIn("Report help topic.", notes)
            self.assertIn("Add monitoring stack.", notes)
            self.assertNotIn("chore: initial import", notes)

    def test_release_note_trailers_render_user_facing_highlights(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            self.init_repo(repo)
            self.git(repo, "tag", "--no-sign", "0.6.0")
            self.commit(
                repo,
                "feat(build): support compose build ssh forwarding",
                body="""
                Preserve BuildKit SSH requests from `docker compose build --ssh`
                and service `build.ssh` entries.

                Release-Note: Supports Docker Compose build SSH forwarding from `--ssh` and `build.ssh`, including named SSH agent IDs.
                """,
            )
            self.commit(
                repo,
                "fix(help): show partial up wait support",
                body="""
                Keep the CLI support matrix honest while healthchecks remain
                runtime-gated.

                Release-Highlight: Marks `container compose up --wait` and `--wait-timeout` as partially supported instead of making every `up` option look green.
                """,
            )
            self.commit(repo, "fix(release): keep package workflow deterministic")
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

            self.assertIn("## Highlights", notes)
            self.assertIn(
                "- Supports Docker Compose build SSH forwarding from `--ssh` and "
                "`build.ssh`, including named SSH agent IDs.",
                notes,
            )
            self.assertIn(
                "- Marks `container compose up --wait` and `--wait-timeout` as "
                "partially supported instead of making every `up` option look green.",
                notes,
            )
            self.assertNotIn("Keep package workflow deterministic.", notes)
            self.assertIn("fix(release): keep package workflow deterministic", notes)

    def test_spaced_release_highlights_all_render(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            self.init_repo(repo)
            self.git(repo, "tag", "--no-sign", "0.6.0")
            self.commit(
                repo,
                "feat(compose): support Bridge CLI runtime",
                body="""
                Add Bridge convert and transformer-management support.

                Release-Highlight: Supports container compose bridge convert with transformer images and template mounts.

                Release-Highlight: Supports container compose bridge transformations create, list, and ls.

                Release-Highlight: Supports Docker Compose --compatibility generated service names.
                """,
            )
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

            self.assertIn(
                "- Supports container compose bridge convert with transformer "
                "images and template mounts.",
                notes,
            )
            self.assertIn(
                "- Supports container compose bridge transformations create, "
                "list, and ls.",
                notes,
            )
            self.assertIn(
                "- Supports Docker Compose --compatibility generated service names.",
                notes,
            )

    def test_plain_body_upstream_refs_are_attached_to_highlights(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            self.init_repo(repo)
            self.git(repo, "tag", "--no-sign", "0.6.0")
            self.commit(
                repo,
                "feat(gpu): support Compose GPU requests",
                body="""
                Support Docker Compose service gpus and generic Deploy GPU reservations.

                Release-Highlight: Maps Compose `gpus` and deploy GPU reservations to the matched Apple virtio-gpu runtime, projecting guest DRM nodes when the kernel exposes them.

                Refs apple/container#1511, apple/containerization#480, apple/containerization#569.
                """,
            )
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

            self.assertIn(
                "- Maps Compose `gpus` and deploy GPU reservations to the "
                "matched Apple virtio-gpu runtime, projecting guest DRM nodes "
                "when the kernel exposes them. Upstream references: "
                "apple/container#1511, apple/containerization#480, "
                "apple/containerization#569.",
                notes,
            )

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

    def test_published_release_baseline_skips_unpublished_semver_tag(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            self.init_repo(repo)
            self.git(repo, "tag", "--no-sign", "0.6.0")
            self.commit(
                repo,
                "feat(commit): support stopped service image commits",
                body="""
                Release-Highlight: Supports `container compose commit` for stopped services by resolving each service's latest container before creating the image snapshot.
                """,
            )
            self.git(repo, "tag", "--no-sign", "0.6.1")
            self.commit(
                repo,
                "fix(normalizer): reject raw git subdirectory traversal",
                body="""
                Upstream-Ref: docker/compose#13331

                Release-Highlight: Rejects raw Git Compose subdirectories before the normalizer clones the project, matching Docker Compose's security fix.
                """,
            )
            self.git(repo, "tag", "--no-sign", "0.6.2")
            self.git(repo, "tag", "--no-sign", "0.7.0")

            original_gh_output = module.gh_output
            try:
                module.gh_output = lambda *arguments: json.dumps(
                    [
                        {
                            "tagName": "0.7.0",
                            "publishedAt": "2026-07-12T08:00:00Z",
                        },
                        {
                            "tagName": "0.6.0",
                            "publishedAt": "2026-07-12T07:00:00Z",
                        },
                    ]
                )
                notes = module.render_release_notes(
                    repo=repo,
                    release_tag="0.6.2",
                    release_label="stable release",
                    compose_version="0.6.2",
                    asset="container-compose-plugin-release-arm64.tar.gz",
                    asset_sha="abc123",
                    head_ref="HEAD",
                    release_repo="stephenlclarke/container-compose",
                )
            finally:
                module.gh_output = original_gh_output

            self.assertIn("Commits since `0.6.0`", notes)
            self.assertNotIn("Commits since `0.6.1`", notes)
            self.assertIn(
                "Supports `container compose commit` for stopped services by "
                "resolving each service's latest container before creating the "
                "image snapshot.",
                notes,
            )
            self.assertIn(
                "Rejects raw Git Compose subdirectories before the normalizer "
                "clones the project, matching Docker Compose's security fix. "
                "Upstream reference: docker/compose#13331.",
                notes,
            )
            self.assertIn("feat(commit): support stopped service image commits", notes)
            self.assertIn(
                "fix(normalizer): reject raw git subdirectory traversal",
                notes,
            )

    def test_stack_component_changes_render_highlights(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            component = root / "container"
            compose = root / "compose"

            self.init_repo(component)
            previous_component_ref = self.git(component, "rev-parse", "HEAD")
            self.commit(
                component,
                "fix(runtime): clean up attached exec on disconnect",
                body="""
                Clean up attached exec sessions when the client disappears
                while preserving detached exec process lifetime.

                Upstream-Ref: apple/container#1926

                Bug-Ref: apple/container#1916

                Release-Highlight: Improves container compose exec reliability by killing attached exec processes when the client disconnects, preventing orphaned sessions from blocking later exec or stop operations while preserving detached exec.
                """,
            )
            current_component_ref = self.git(component, "rev-parse", "HEAD")

            self.init_repo(compose)
            self.write_stack_refs(compose, previous_component_ref)
            self.git(compose, "add", "Tools/release/stack-refs.json")
            self.git(
                compose,
                "-c",
                "user.name=Test",
                "-c",
                "user.email=test@example.com",
                "commit",
                "-m",
                "chore(release): record stack refs",
            )
            self.git(compose, "tag", "--no-sign", "0.6.0")
            self.write_stack_refs(compose, current_component_ref)
            self.git(compose, "add", "Tools/release/stack-refs.json")
            self.git(
                compose,
                "-c",
                "user.name=Test",
                "-c",
                "user.email=test@example.com",
                "commit",
                "-m",
                "chore(release): prepare 0.6.1",
            )
            self.git(compose, "tag", "--no-sign", "0.6.1")

            notes = module.render_release_notes(
                repo=compose,
                release_tag="0.6.1",
                release_label="stable release",
                compose_version="0.6.1",
                asset="container-compose-plugin-release-arm64.tar.gz",
                asset_sha="abc123",
                head_ref="HEAD",
                component_repos={"container": component},
            )

            self.assertIn("## Highlights", notes)
            self.assertIn(
                "- Improves container compose exec reliability by killing attached "
                "exec processes when the client disconnects, preventing orphaned "
                "sessions from blocking later exec or stop operations while "
                "preserving detached exec. Upstream references: "
                "apple/container#1926, apple/container#1916.",
                notes,
            )
            self.assertIn("## Component Changes", notes)
            self.assertIn(
                f"- `container` `{previous_component_ref[:12]}` -> `{current_component_ref[:12]}`",
                notes,
            )
            self.assertIn(
                "fix(runtime): clean up attached exec on disconnect",
                notes,
            )

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
            self.assertNotIn("## Highlights", notes)

    def init_repo(self, repo: Path) -> None:
        repo.mkdir(parents=True, exist_ok=True)
        self.git(repo, "init", "-b", "main")
        self.commit(repo, "chore: initial import")

    def write_stack_refs(self, repo: Path, container_ref: str) -> None:
        path = repo / "Tools" / "release"
        path.mkdir(parents=True, exist_ok=True)
        (path / "stack-refs.json").write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "components": {
                        "container": {
                            "repository": "stephenlclarke/container",
                            "ref": container_ref,
                        }
                    },
                },
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )

    def commit(self, repo: Path, message: str, body: str | None = None) -> None:
        index = len(list(repo.glob("*.txt")))
        (repo / f"{index}.txt").write_text(f"{message}\n", encoding="utf-8")
        self.git(repo, "add", ".")
        command = [
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.com",
            "commit",
            "-m",
            message,
        ]
        if body is not None:
            command.extend(["-m", textwrap.dedent(body).strip()])
        self.git(repo, *command)

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
