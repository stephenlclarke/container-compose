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
                release_tag="current",
                release_label="current build",
                compose_version="0.6.1",
                asset="container-compose-plugin-current-arm64.tar.gz",
                asset_sha="abc123",
                head_ref="HEAD",
            )

            self.assertIn("Commits since `0.6.0`", notes)
            self.assertIn("## Homebrew Formula", notes)
            self.assertIn("## Promotion", notes)
            self.assertIn("## Asset Retention", notes)
            self.assertIn("It never changes the stable formula pair.", notes)
            self.assertIn("They do not move semantic source tags or the stable formula pair.", notes)
            self.assertIn("Mutable `current` pointer targets main commit", notes)
            self.assertIn("single `Current build` prerelease", notes)
            self.assertIn("## Highlights", notes)
            self.assertIn("Support bind propagation.", notes)
            self.assertIn("feat(mounts): support bind propagation", notes)
            self.assertIn("docs: refresh compose guidance", notes)
            self.assertNotIn("chore: initial import", notes)

    def test_current_release_ignores_the_previous_current_pointer_as_a_baseline(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            self.init_repo(repo)
            self.git(repo, "tag", "--no-sign", "0.6.0")
            self.commit(repo, "feat(runtime): add the first current change")
            self.git(repo, "tag", "--no-sign", "current")
            self.commit(repo, "fix(runtime): add the next current change")

            notes = module.render_release_notes(
                repo=repo,
                release_tag="current",
                release_label="current build",
                compose_version="0.6.1",
                asset="container-compose-plugin-current-arm64.tar.gz",
                asset_sha="abc123",
                head_ref="HEAD",
            )

            self.assertIn("Commits since `0.6.0`", notes)
            self.assertIn("feat(runtime): add the first current change", notes)
            self.assertIn("fix(runtime): add the next current change", notes)
            self.assertNotIn("Commits since `current`", notes)

    def test_current_notes_record_the_matched_runtime_checksum(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            self.init_repo(repo)
            head = self.git(repo, "rev-parse", "HEAD")

            notes = module.render_release_notes(
                repo=repo,
                release_tag="current",
                release_label="current build",
                compose_version="0.6.1",
                asset="container-compose-plugin-current-arm64.tar.gz",
                asset_sha="compose-sha",
                runtime_asset="container-current-arm64.tar.gz",
                runtime_asset_sha="runtime-sha",
                head_ref="HEAD",
            )

            self.assertIn(f"Mutable `current` pointer targets main commit `{head}`", notes)
            self.assertIn("`container-current-arm64.tar.gz` SHA-256:", notes)
            self.assertIn("`runtime-sha`.", notes)

    def test_main_validation_tag_rerun_keeps_full_stable_range(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            self.init_repo(repo)
            self.git(repo, "tag", "--no-sign", "0.6.0")
            self.commit(repo, "ci(release): simplify package publishing")
            self.commit(repo, "fix(release): commit new tap formula files")
            self.commit(repo, "fix(integration): preserve serial rootfs")
            self.git(repo, "tag", "--no-sign", "current-123-abcdef123456")

            notes = module.render_release_notes(
                repo=repo,
                release_tag="current-123-abcdef123456",
                release_label="current build",
                compose_version="0.6.1",
                asset="container-compose-plugin-current-arm64.tar.gz",
                asset_sha="abc123",
                head_ref="HEAD",
            )

            self.assertIn("Commits since `0.6.0`", notes)
            self.assertIn("ci(release): simplify package publishing", notes)
            self.assertIn("fix(release): commit new tap formula files", notes)
            self.assertIn("fix(integration): preserve serial rootfs", notes)
            self.assertIn("## Highlights", notes)
            self.assertIn("No user-facing highlights were declared", notes)
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
            self.assertIn("The stable release atomically updates `stephenlclarke/tap/container-compose`", notes)
            self.assertIn(
                "Stable releases additionally require the hosted Stable Release Gate",
                notes,
            )
            self.assertIn(
                "The package workflow verifies the exact immutable runtime asset",
                notes,
            )
            self.assertIn(
                "builder, containerization, and container coverage and runtime integration checks, Compose CI, and full Docker Compose parity",
                notes,
            )
            self.assertIn("fix(cli): report help topic", notes)
            self.assertIn("feat(examples): add monitoring stack", notes)
            self.assertIn("Report help topic.", notes)
            self.assertIn("Add monitoring stack.", notes)
            self.assertNotIn("chore: initial import", notes)

    def test_stable_release_renders_the_static_quality_snapshot(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            self.init_repo(repo)
            self.git(repo, "tag", "--no-sign", "0.6.0")
            self.commit(repo, "fix(release): preserve quality evidence")
            self.git(repo, "tag", "--no-sign", "0.6.1")
            snapshot = """## Quality Snapshot

![Quality Gate Status](https://img.shields.io/static/v1?label=Quality+Gate+Status&message=Passed&color=brightgreen) ![CodeQL Results](https://img.shields.io/static/v1?label=CodeQL+Results&message=0&color=brightgreen)
"""

            notes = module.render_release_notes(
                repo=repo,
                release_tag="0.6.1",
                release_label="stable release",
                compose_version="0.6.1",
                asset="container-compose-plugin-release-arm64.tar.gz",
                asset_sha="abc123",
                quality_snapshot=snapshot,
                head_ref="HEAD",
            )

            self.assertIn("## Quality Snapshot", notes)
            self.assertIn("![Quality Gate Status]", notes)
            self.assertIn("![CodeQL Results]", notes)
            self.assertNotIn("[![", notes)
            self.assertLess(notes.index("## Quality Snapshot"), notes.index("## Summary"))
            metric_rows = [line for line in notes.splitlines() if line.startswith("![")]
            self.assertEqual(metric_rows, [snapshot.splitlines()[2]])

    def test_stable_highlights_and_changes_exclude_the_previous_stable_build(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            self.init_repo(repo)
            self.git(repo, "tag", "--no-sign", "0.6.0")
            self.commit(
                repo,
                "feat(network): add obsolete release feature",
                body="Release-Highlight: This must not appear in the next stable release notes.",
            )
            self.git(repo, "tag", "--no-sign", "0.6.1")
            self.commit(
                repo,
                "feat(network): add stable release feature",
                body="Release-Highlight: Adds the feature delivered by this stable release.",
            )
            self.git(repo, "tag", "--no-sign", "0.6.2")

            notes = module.render_release_notes(
                repo=repo,
                release_tag="0.6.2",
                release_label="stable release",
                compose_version="0.6.2",
                asset="container-compose-plugin-release-arm64.tar.gz",
                asset_sha="abc123",
                head_ref="HEAD",
            )

            self.assertIn("Commits since `0.6.1`", notes)
            self.assertIn("feat(network): add stable release feature", notes)
            self.assertIn("Adds the feature delivered by this stable release.", notes)
            self.assertNotIn("feat(network): add obsolete release feature", notes)
            self.assertNotIn("This must not appear in the next stable release notes.", notes)

    def test_current_release_renders_a_quality_snapshot_before_the_summary(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            self.init_repo(repo)

            notes = module.render_release_notes(
                repo=repo,
                release_tag="current",
                release_label="current build",
                compose_version="0.6.1",
                asset="container-compose-plugin-current-arm64.tar.gz",
                asset_sha="abc123",
                quality_snapshot="## Quality Snapshot\n\nCurrent evidence.",
                head_ref="HEAD",
            )

            self.assertIn("Current evidence.", notes)
            self.assertLess(notes.index("## Quality Snapshot"), notes.index("## Summary"))

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

    def test_commit_body_summary_is_preferred_over_terse_subject(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            self.init_repo(repo)
            self.git(repo, "tag", "--no-sign", "0.6.0")
            self.commit(
                repo,
                "fix(deploy): accept local start-first updates",
                body="""
                Support Docker Compose local deploy.update_config.order start-first
                and recreate services when deploy metadata changes, without
                claiming unsupported Swarm rollout scheduling.
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
                "- Supports Docker Compose local deploy.update_config.order "
                "start-first and recreate services when deploy metadata changes, "
                "without claiming unsupported Swarm rollout scheduling.",
                notes,
            )
            self.assertNotIn("- Accept local start-first updates.", notes)

    def test_internal_release_trailers_do_not_become_user_highlights(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            self.init_repo(repo)
            self.git(repo, "tag", "--no-sign", "0.6.0")
            self.commit(
                repo,
                "chore(deps): pin containerization",
                body="""
                Release-Highlight: Release automation pins containerization to an exact revision.
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

            self.assertIn("## Highlights", notes)
            self.assertIn("No user-facing highlights were declared", notes)
            self.assertNotIn("Release automation pins containerization", notes)
            self.assertIn("chore(deps): pin containerization", notes)

    def test_release_note_none_suppresses_automatic_highlight(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            self.init_repo(repo)
            self.git(repo, "tag", "--no-sign", "0.6.0")
            self.commit(
                repo,
                "fix(cli): retain compatibility diagnostics",
                body="""
                Release-Note: none
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

            self.assertIn("## Highlights", notes)
            self.assertIn("No user-facing highlights were declared", notes)
            self.assertNotIn("retain compatibility diagnostics.", notes)
            self.assertIn("fix(cli): retain compatibility diagnostics", notes)

    def test_body_summary_ignores_generic_git_trailers(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            self.init_repo(repo)
            self.git(repo, "tag", "--no-sign", "0.6.0")
            self.commit(
                repo,
                "fix(config): preserve project labels",
                body="""
                Preserve Compose project labels while applying configuration changes.

                Co-authored-by: Codex <codex@example.com>
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
                "- Preserves Compose project labels while applying configuration changes.",
                notes,
            )
            self.assertNotIn("Co-authored-by", notes.split("## Changes", maxsplit=1)[0])

    def test_body_summary_preserves_user_facing_colons(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            self.init_repo(repo)
            self.git(repo, "tag", "--no-sign", "0.6.0")
            self.commit(
                repo,
                "feat(config): preserve labels",
                body="""
                Support Docker Compose project labels: preserve them while applying configuration changes.
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
                "- Supports Docker Compose project labels: preserve them while "
                "applying configuration changes.",
                notes,
            )

    def test_explicit_nonconventional_highlight_is_preserved(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            self.init_repo(repo)
            self.git(repo, "tag", "--no-sign", "0.6.0")
            self.commit(
                repo,
                "Docker Compose import from upstream",
                body="""
                Release-Highlight: Supports Docker Compose profile-aware imports from the upstream compatibility fix.

                Upstream-Ref: docker/compose#12345
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
                "- Supports Docker Compose profile-aware imports from the upstream "
                "compatibility fix. Upstream reference: docker/compose#12345.",
                notes,
            )

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
            self.assertIn("## Highlights", notes)
            self.assertIn("No user-facing highlights were declared", notes)

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
