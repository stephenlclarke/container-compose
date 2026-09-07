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

"""Focused tests for exact, isolated release workspaces."""

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("release-workspace.py")
RELEASE_SCRIPT = MODULE_PATH.parents[2] / "scripts" / "CONTAINER_STACK_RELEASE.sh"
SPEC = importlib.util.spec_from_file_location("release_workspace", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
WORKSPACE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = WORKSPACE
SPEC.loader.exec_module(WORKSPACE)


class ReleaseWorkspaceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.remote_root = self.root / "remotes"
        self.remote_root.mkdir()
        self.build_root = self.root / "build"
        for component in WORKSPACE.COMPONENTS:
            self.create_remote(component.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def git(self, *arguments: str, cwd: Path | None = None) -> str:
        environment = {
            "GIT_AUTHOR_EMAIL": "release-tests@example.com",
            "GIT_AUTHOR_NAME": "Release Tests",
            "GIT_COMMITTER_EMAIL": "release-tests@example.com",
            "GIT_COMMITTER_NAME": "Release Tests",
        }
        completed = subprocess.run(
            ["git", *arguments],
            cwd=cwd,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return completed.stdout

    def create_remote(self, name: str) -> None:
        source = self.root / "sources" / name
        source.mkdir(parents=True)
        self.git("init", "--initial-branch=main", cwd=source)
        (source / "README.md").write_text(f"# {name}\n", encoding="utf-8")
        if name == "container-compose":
            (source / "Makefile").write_text(
                "COMPOSE_VERSION ?= 0.14.2\n", encoding="utf-8"
            )
            (source / ".gitignore").write_text(".build/\n", encoding="utf-8")
        self.git("add", ".", cwd=source)
        self.git("commit", "-m", "initial", cwd=source)
        self.git("tag", "0.14.2", cwd=source)
        self.git("tag", "current", cwd=source)
        self.git(
            "clone",
            "--bare",
            str(source),
            str(self.remote_root / f"{name}.git"),
        )

    def checkout_state(self, path: Path) -> tuple[str, str, str]:
        return (
            self.git("branch", "--show-current", cwd=path).strip(),
            self.git("rev-parse", "HEAD", cwd=path).strip(),
            self.git("status", "--porcelain=v1", "--untracked-files=all", cwd=path),
        )

    def test_plan_does_not_mutate_dirty_detached_or_non_main_checkouts(self) -> None:
        primary = self.root / "primary"
        dirty = primary / "container-compose"
        detached = primary / "container"
        clean = primary / "containerization"
        for name, path in (
            ("container-compose", dirty),
            ("container", detached),
            ("containerization", clean),
        ):
            self.git("clone", str(self.remote_root / f"{name}.git"), str(path))
        self.git("switch", "-c", "feature/keep-me", cwd=dirty)
        (dirty / "README.md").write_text("modified\n", encoding="utf-8")
        (dirty / "untracked.txt").write_text("keep\n", encoding="utf-8")
        self.git("checkout", "--detach", cwd=detached)
        before = {path: self.checkout_state(path) for path in (dirty, detached, clean)}

        plan = WORKSPACE.format_plan(self.remote_root)

        self.assertIn("next minor release:      0.15.0", plan)
        self.assertIn("container-compose", plan)
        self.assertEqual(
            before,
            {path: self.checkout_state(path) for path in (dirty, detached, clean)},
        )

    def test_materialize_resumes_the_same_mutated_transaction(self) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        compose = release_root / "container-compose"
        (compose / "candidate.txt").write_text("candidate\n", encoding="utf-8")
        self.git("add", "candidate.txt", cwd=compose)
        self.git("commit", "-m", "release candidate", cwd=compose)
        candidate = self.git("rev-parse", "HEAD", cwd=compose).strip()
        (compose / "retained.log").write_text("interrupted\n", encoding="utf-8")
        source = self.root / "sources" / "container-compose"
        (source / "README.md").write_text("# newer main\n", encoding="utf-8")
        self.git("add", "README.md", cwd=source)
        self.git("commit", "-m", "advance main", cwd=source)
        self.git(
            "push",
            str(self.remote_root / "container-compose.git"),
            "HEAD:refs/heads/main",
            cwd=source,
        )

        resumed = WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)

        self.assertEqual(resumed, release_root)
        self.assertEqual(self.git("rev-parse", "HEAD", cwd=compose).strip(), candidate)
        self.assertEqual(
            (compose / "retained.log").read_text(encoding="utf-8"),
            "interrupted\n",
        )

    def test_resume_preserves_stashed_release_work_when_main_moves(self) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        compose = release_root / "container-compose"
        stashed = compose / "operator-work.txt"
        stashed.write_text("preserve me\n", encoding="utf-8")
        self.git(
            "stash",
            "push",
            "--include-untracked",
            "--message",
            "operator work",
            cwd=compose,
        )
        stash = self.git("rev-parse", "refs/stash", cwd=compose).strip()
        source = self.root / "sources" / "containerization"
        (source / "new-runtime.txt").write_text("new runtime\n", encoding="utf-8")
        self.git("add", "new-runtime.txt", cwd=source)
        self.git("commit", "-m", "advance main", cwd=source)
        self.git(
            "push",
            str(self.remote_root / "containerization.git"),
            "HEAD:refs/heads/main",
            cwd=source,
        )

        resumed = WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)

        self.assertEqual(resumed, release_root)
        self.assertEqual(self.git("rev-parse", "refs/stash", cwd=compose).strip(), stash)
        self.assertIn(
            "operator-work.txt",
            self.git(
                "stash",
                "show",
                "--include-untracked",
                "--name-only",
                cwd=compose,
            ),
        )

    def test_resume_preserves_an_unpushed_release_tag_when_main_moves(self) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        compose = release_root / "container-compose"
        self.git(
            "tag",
            "--annotate",
            "--message",
            f"Release {release_root.name}",
            release_root.name,
            cwd=compose,
        )
        tag = self.git(
            "rev-parse", f"refs/tags/{release_root.name}", cwd=compose
        ).strip()
        source = self.root / "sources" / "containerization"
        (source / "new-runtime.txt").write_text("new runtime\n", encoding="utf-8")
        self.git("add", "new-runtime.txt", cwd=source)
        self.git("commit", "-m", "advance main", cwd=source)
        self.git(
            "push",
            str(self.remote_root / "containerization.git"),
            "HEAD:refs/heads/main",
            cwd=source,
        )

        resumed = WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)

        self.assertEqual(resumed, release_root)
        self.assertEqual(
            self.git(
                "rev-parse", f"refs/tags/{release_root.name}", cwd=compose
            ).strip(),
            tag,
        )

    def test_resume_preserves_an_unpushed_authority_tag_when_main_moves(
        self,
    ) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        compose = release_root / "container-compose"
        authority_tag = f"stable-init-image-authority/{release_root.name}"
        self.git(
            "tag",
            "--annotate",
            "--message",
            f"Authority {release_root.name}",
            authority_tag,
            cwd=compose,
        )
        tag = self.git("rev-parse", f"refs/tags/{authority_tag}", cwd=compose).strip()
        source = self.root / "sources" / "containerization"
        (source / "new-runtime.txt").write_text("new runtime\n", encoding="utf-8")
        self.git("add", "new-runtime.txt", cwd=source)
        self.git("commit", "-m", "advance main", cwd=source)
        self.git(
            "push",
            str(self.remote_root / "containerization.git"),
            "HEAD:refs/heads/main",
            cwd=source,
        )

        resumed = WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)

        self.assertEqual(resumed, release_root)
        self.assertEqual(
            self.git("rev-parse", f"refs/tags/{authority_tag}", cwd=compose).strip(),
            tag,
        )

    def test_mutable_tag_names_are_scoped_to_their_owning_repositories(
        self,
    ) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        compose = release_root / "container-compose"
        containerization = release_root / "containerization"
        self.git("tag", "homebrew-main", cwd=compose)
        self.git(
            "tag",
            "--force",
            "--annotate",
            "--message",
            "local current",
            "current",
            cwd=containerization,
        )
        compose_tag = self.git("rev-parse", "refs/tags/homebrew-main", cwd=compose)
        containerization_tag = self.git(
            "rev-parse", "refs/tags/current", cwd=containerization
        )
        source = self.root / "sources" / "container-builder-shim"
        (source / "new-runtime.txt").write_text("new runtime\n", encoding="utf-8")
        self.git("add", "new-runtime.txt", cwd=source)
        self.git("commit", "-m", "advance main", cwd=source)
        self.git(
            "push",
            str(self.remote_root / "container-builder-shim.git"),
            "HEAD:refs/heads/main",
            cwd=source,
        )

        resumed = WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)

        self.assertEqual(resumed, release_root)
        self.assertEqual(
            self.git("rev-parse", "refs/tags/homebrew-main", cwd=compose),
            compose_tag,
        )
        self.assertEqual(
            self.git("rev-parse", "refs/tags/current", cwd=containerization),
            containerization_tag,
        )

    def test_resume_replaces_a_pristine_checkpoint_when_main_moves(self) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        checkpoint = WORKSPACE.workspace_marker(release_root)
        original = checkpoint["mainRefs"]
        checkpoint.pop("immutableTagRefs")
        checkpoint.pop("remoteTrackingRefs")
        checkpoint.pop("recoveryObjects")
        checkpoint.pop("semanticTagTargets")
        WORKSPACE.atomic_json(release_root / WORKSPACE.WORKSPACE_MARKER, checkpoint)
        source = self.root / "sources" / "containerization"
        (source / "new-runtime.txt").write_text("new runtime\n", encoding="utf-8")
        self.git("add", "new-runtime.txt", cwd=source)
        self.git("commit", "-m", "advance main", cwd=source)
        current = self.git("rev-parse", "HEAD", cwd=source).strip()
        self.git(
            "push",
            str(self.remote_root / "containerization.git"),
            "HEAD:refs/heads/main",
            cwd=source,
        )

        resumed = WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)

        marker = WORKSPACE.workspace_marker(resumed)
        self.assertEqual(resumed, release_root)
        self.assertNotEqual(marker["mainRefs"], original)
        self.assertEqual(marker["mainRefs"]["containerization"], current)
        self.assertEqual(
            self.git("rev-parse", "HEAD", cwd=resumed / "containerization").strip(),
            current,
        )
        self.assertTrue((resumed / "containerization" / "new-runtime.txt").is_file())

    def test_resume_replaces_a_checkpoint_after_its_fetch_advances_main(self) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        checkpoint = WORKSPACE.workspace_marker(release_root)
        compose = release_root / "container-compose"
        source = self.root / "sources" / "container-compose"
        (source / "new-compose.txt").write_text("new compose\n", encoding="utf-8")
        self.git("add", "new-compose.txt", cwd=source)
        self.git("commit", "-m", "advance main", cwd=source)
        current = self.git("rev-parse", "HEAD", cwd=source).strip()
        self.git(
            "push",
            str(self.remote_root / "container-compose.git"),
            "HEAD:refs/heads/main",
            cwd=source,
        )
        self.git("fetch", "origin", "main", cwd=compose)
        self.assertNotEqual(
            WORKSPACE.local_remote_tracking_refs(compose),
            checkpoint["remoteTrackingRefs"]["container-compose"],
        )

        resumed = WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)

        self.assertEqual(resumed, release_root)
        self.assertEqual(
            self.git("rev-parse", "HEAD", cwd=resumed / "container-compose").strip(),
            current,
        )
        self.assertEqual(
            WORKSPACE.workspace_marker(resumed)["mainRefs"]["container-compose"],
            current,
        )

    def test_resume_replaces_a_checkpoint_after_fetched_main_advances_again(
        self,
    ) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        compose = release_root / "container-compose"
        source = self.root / "sources" / "container-compose"
        (source / "first.txt").write_text("first\n", encoding="utf-8")
        self.git("add", "first.txt", cwd=source)
        self.git("commit", "-m", "first advance", cwd=source)
        self.git(
            "push",
            str(self.remote_root / "container-compose.git"),
            "HEAD:refs/heads/main",
            cwd=source,
        )
        self.git("fetch", "--prune", "--tags", "origin", cwd=compose)
        fetched = self.git("rev-parse", "origin/main", cwd=compose).strip()

        (source / "second.txt").write_text("second\n", encoding="utf-8")
        self.git("add", "second.txt", cwd=source)
        self.git("commit", "-m", "second advance", cwd=source)
        current = self.git("rev-parse", "HEAD", cwd=source).strip()
        self.git(
            "push",
            str(self.remote_root / "container-compose.git"),
            "HEAD:refs/heads/main",
            cwd=source,
        )
        self.assertNotEqual(fetched, current)
        self.assertEqual(
            self.git("rev-parse", "origin/main", cwd=compose).strip(),
            fetched,
        )

        resumed = WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)

        self.assertEqual(resumed, release_root)
        self.assertEqual(
            self.git("rev-parse", "HEAD", cwd=resumed / "container-compose").strip(),
            current,
        )
        self.assertEqual(
            WORKSPACE.workspace_marker(resumed)["mainRefs"]["container-compose"],
            current,
        )

    def test_checkpoint_rejects_an_unadvertised_remote_tracking_alias(self) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        checkpoint = WORKSPACE.workspace_marker(release_root)
        compose = release_root / "container-compose"
        self.git(
            "update-ref",
            "refs/remotes/origin/operator-work",
            "origin/main",
            cwd=compose,
        )

        self.assertFalse(
            WORKSPACE.workspace_matches_initial_checkpoint(
                release_root,
                checkpoint,
            )
        )

    def test_legacy_checkpoint_accepts_state_advertised_by_its_own_remote(
        self,
    ) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        checkpoint = WORKSPACE.workspace_marker(release_root)
        for field in (
            "immutableTagRefs",
            "recoveryObjects",
            "remoteTrackingRefs",
            "semanticTagTargets",
        ):
            checkpoint.pop(field)
        WORKSPACE.atomic_json(release_root / WORKSPACE.WORKSPACE_MARKER, checkpoint)
        containerization = release_root / "containerization"
        initial = self.git("rev-parse", "HEAD", cwd=containerization).strip()
        (containerization / "upstream.txt").write_text(
            "upstream work\n", encoding="utf-8"
        )
        self.git("add", "upstream.txt", cwd=containerization)
        self.git("commit", "-m", "upstream work", cwd=containerization)
        upstream_commit = self.git(
            "rev-parse", "HEAD", cwd=containerization
        ).strip()
        self.git("reset", "--hard", initial, cwd=containerization)
        self.git(
            "update-ref",
            "refs/remotes/upstream/main",
            upstream_commit,
            cwd=containerization,
        )
        source = self.root / "sources" / "container-compose"
        (source / "new-compose.txt").write_text("new compose\n", encoding="utf-8")
        self.git("add", "new-compose.txt", cwd=source)
        self.git("commit", "-m", "advance main", cwd=source)
        current = self.git("rev-parse", "HEAD", cwd=source).strip()
        self.git(
            "push",
            str(self.remote_root / "container-compose.git"),
            "HEAD:refs/heads/main",
            cwd=source,
        )
        reachable = WORKSPACE.remote_reachable_objects

        def configured_remote_objects(url: str) -> set[str]:
            if url == "https://github.com/apple/containerization.git":
                return {upstream_commit}
            return reachable(url)

        with mock.patch.object(
            WORKSPACE,
            "remote_reachable_objects",
            side_effect=configured_remote_objects,
        ):
            resumed = WORKSPACE.materialize(
                self.build_root, "-+-", self.remote_root
            )

        self.assertEqual(resumed, release_root)
        self.assertEqual(
            WORKSPACE.workspace_marker(resumed)["mainRefs"]["container-compose"],
            current,
        )

    def test_legacy_checkpoint_accepts_an_earlier_fetched_main_ancestor(
        self,
    ) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        checkpoint = WORKSPACE.workspace_marker(release_root)
        for field in (
            "immutableTagRefs",
            "recoveryObjects",
            "remoteTrackingRefs",
            "semanticTagTargets",
        ):
            checkpoint.pop(field)
        WORKSPACE.atomic_json(release_root / WORKSPACE.WORKSPACE_MARKER, checkpoint)

        source = self.root / "sources" / "container-compose"
        compose = release_root / "container-compose"
        (source / "first.txt").write_text("first\n", encoding="utf-8")
        self.git("add", "first.txt", cwd=source)
        self.git("commit", "-m", "first advance", cwd=source)
        self.git(
            "push",
            str(self.remote_root / "container-compose.git"),
            "HEAD:refs/heads/main",
            cwd=source,
        )
        self.git("fetch", "origin", "main", cwd=compose)
        earlier = self.git("rev-parse", "origin/main", cwd=compose).strip()

        (source / "second.txt").write_text("second\n", encoding="utf-8")
        self.git("add", "second.txt", cwd=source)
        self.git("commit", "-m", "second advance", cwd=source)
        current = self.git("rev-parse", "HEAD", cwd=source).strip()
        self.git(
            "push",
            str(self.remote_root / "container-compose.git"),
            "HEAD:refs/heads/main",
            cwd=source,
        )
        self.git("fetch", "origin", "main", cwd=compose)

        self.assertIn(earlier, WORKSPACE.local_recovery_objects(compose))
        self.assertNotIn(
            earlier,
            WORKSPACE.remote_reachable_objects(
                str(self.remote_root / "container-compose.git")
            ),
        )

        resumed = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )

        self.assertEqual(resumed, release_root)
        self.assertEqual(
            WORKSPACE.workspace_marker(resumed)["mainRefs"]["container-compose"],
            current,
        )

    def test_legacy_checkpoint_does_not_query_unneeded_secondary_remotes(
        self,
    ) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        checkpoint = WORKSPACE.workspace_marker(release_root)
        for field in (
            "immutableTagRefs",
            "recoveryObjects",
            "remoteTrackingRefs",
            "semanticTagTargets",
        ):
            checkpoint.pop(field)
        WORKSPACE.atomic_json(release_root / WORKSPACE.WORKSPACE_MARKER, checkpoint)

        reachable = WORKSPACE.remote_reachable_objects

        def clone_remotes_only(url: str) -> set[str]:
            if url.startswith("https://github.com/apple/"):
                raise AssertionError(f"unexpected secondary remote query: {url}")
            return reachable(url)

        with mock.patch.object(
            WORKSPACE,
            "remote_reachable_objects",
            side_effect=clone_remotes_only,
        ):
            self.assertTrue(
                WORKSPACE.workspace_matches_initial_checkpoint(
                    release_root,
                    checkpoint,
                )
            )

    def test_legacy_checkpoint_rejects_grafted_recovery_history(self) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        checkpoint = WORKSPACE.workspace_marker(release_root)
        for field in (
            "immutableTagRefs",
            "recoveryObjects",
            "remoteTrackingRefs",
            "semanticTagTargets",
        ):
            checkpoint.pop(field)
        WORKSPACE.atomic_json(release_root / WORKSPACE.WORKSPACE_MARKER, checkpoint)

        compose = release_root / "container-compose"
        head = self.git("rev-parse", "HEAD", cwd=compose).strip()
        tree = self.git("rev-parse", "HEAD^{tree}", cwd=compose).strip()
        unadvertised = self.git(
            "commit-tree", tree, "-m", "unadvertised recovery object", cwd=compose
        ).strip()
        git_directory = Path(
            self.git("rev-parse", "--absolute-git-dir", cwd=compose).strip()
        )
        (git_directory / "ORIG_HEAD").write_text(
            f"{unadvertised}\n", encoding="utf-8"
        )
        (git_directory / "info" / "grafts").write_text(
            f"{head} {unadvertised}\n", encoding="utf-8"
        )

        self.assertFalse(
            WORKSPACE.workspace_matches_initial_checkpoint(
                release_root,
                checkpoint,
            )
        )

    def test_resume_preserves_an_additional_remote_when_main_moves(self) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        compose = release_root / "container-compose"
        scratch = str(self.remote_root / "container-compose.git")
        self.git("remote", "add", "scratch", scratch, cwd=compose)
        source = self.root / "sources" / "containerization"
        (source / "new-runtime.txt").write_text("new runtime\n", encoding="utf-8")
        self.git("add", "new-runtime.txt", cwd=source)
        self.git("commit", "-m", "advance main", cwd=source)
        self.git(
            "push",
            str(self.remote_root / "containerization.git"),
            "HEAD:refs/heads/main",
            cwd=source,
        )

        resumed = WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)

        self.assertEqual(resumed, release_root)
        self.assertEqual(
            self.git("remote", "get-url", "scratch", cwd=compose).strip(), scratch
        )

    def test_legacy_baseline_upgrade_does_not_capture_concurrent_state(self) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        checkpoint = WORKSPACE.workspace_marker(release_root)
        for field in (
            "immutableTagRefs",
            "recoveryObjects",
            "remoteTrackingRefs",
            "semanticTagTargets",
        ):
            checkpoint.pop(field)
        WORKSPACE.atomic_json(release_root / WORKSPACE.WORKSPACE_MARKER, checkpoint)
        refresh = WORKSPACE.refresh_mutable_current_tag

        def add_operator_tag(root: Path) -> None:
            refresh(root)
            self.git("tag", "operator-after-check", cwd=root / "container-compose")

        with mock.patch.object(
            WORKSPACE,
            "refresh_mutable_current_tag",
            side_effect=add_operator_tag,
        ):
            resumed = WORKSPACE.materialize(
                self.build_root, "-+-", self.remote_root
            )

        self.assertEqual(resumed, release_root)
        marker = WORKSPACE.workspace_marker(resumed)
        self.assertNotIn("immutableTagRefs", marker)
        self.assertNotIn("recoveryObjects", marker)
        self.assertNotIn("remoteTrackingRefs", marker)
        self.assertNotIn("semanticTagTargets", marker)
        self.assertEqual(
            self.git(
                "rev-parse",
                "refs/tags/operator-after-check",
                cwd=resumed / "container-compose",
            ).strip(),
            self.git("rev-parse", "HEAD", cwd=resumed / "container-compose").strip(),
        )

    def test_failed_replacement_clone_preserves_the_pristine_checkpoint(self) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        original = WORKSPACE.workspace_marker(release_root)
        source = self.root / "sources" / "containerization"
        (source / "new-runtime.txt").write_text("new runtime\n", encoding="utf-8")
        self.git("add", "new-runtime.txt", cwd=source)
        self.git("commit", "-m", "advance main", cwd=source)
        self.git(
            "push",
            str(self.remote_root / "containerization.git"),
            "HEAD:refs/heads/main",
            cwd=source,
        )

        with mock.patch.object(
            WORKSPACE,
            "clone_workspace",
            side_effect=WORKSPACE.WorkspaceError("replacement clone failed"),
        ):
            with self.assertRaisesRegex(
                WORKSPACE.WorkspaceError, "replacement clone failed"
            ):
                WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)

        self.assertTrue(release_root.is_dir())
        self.assertEqual(WORKSPACE.workspace_marker(release_root), original)
        self.assertEqual(
            self.git("rev-parse", "HEAD", cwd=release_root / "containerization").strip(),
            original["mainRefs"]["containerization"],
        )

    def test_resume_removes_an_unjournaled_ready_clone_stage(self) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        orphan = self.build_root / f".{release_root.name}.orphan"
        shutil.copytree(release_root, orphan)

        resumed = WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)

        self.assertEqual(resumed, release_root)
        self.assertFalse(orphan.exists())

    def test_replacement_rejects_checkpoint_changes_during_clone(self) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        source = self.root / "sources" / "containerization"
        (source / "new-runtime.txt").write_text("new runtime\n", encoding="utf-8")
        self.git("add", "new-runtime.txt", cwd=source)
        self.git("commit", "-m", "advance main", cwd=source)
        self.git(
            "push",
            str(self.remote_root / "containerization.git"),
            "HEAD:refs/heads/main",
            cwd=source,
        )
        clone_workspace = WORKSPACE.clone_workspace

        def clone_then_change_checkpoint(
            stage: Path,
            refs: dict[str, str],
            remote_root: Path | None,
        ) -> None:
            clone_workspace(stage, refs, remote_root)
            self.git(
                "switch",
                "-c",
                "release/operator-change",
                cwd=release_root / "container-compose",
            )

        with mock.patch.object(
            WORKSPACE,
            "clone_workspace",
            side_effect=clone_then_change_checkpoint,
        ):
            with self.assertRaisesRegex(
                WORKSPACE.WorkspaceError,
                "changed while its replacement was cloned",
            ):
                WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)

        self.assertTrue(release_root.is_dir())
        self.assertEqual(
            self.git(
                "branch",
                "--show-current",
                cwd=release_root / "container-compose",
            ).strip(),
            "release/operator-change",
        )

    def test_failed_replacement_install_restores_the_previous_checkpoint(self) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        original = WORKSPACE.workspace_marker(release_root)
        source = self.root / "sources" / "containerization"
        (source / "new-runtime.txt").write_text("new runtime\n", encoding="utf-8")
        self.git("add", "new-runtime.txt", cwd=source)
        self.git("commit", "-m", "advance main", cwd=source)
        self.git(
            "push",
            str(self.remote_root / "containerization.git"),
            "HEAD:refs/heads/main",
            cwd=source,
        )
        replace = WORKSPACE.os.replace
        failed = False

        def fail_replacement_install(source: Path, destination: Path) -> None:
            nonlocal failed
            source_path = Path(source)
            destination_path = Path(destination)
            if (
                not failed
                and destination_path == release_root
                and source_path.is_dir()
                and ".replaced." not in source_path.name
            ):
                failed = True
                raise OSError("replacement install failed")
            replace(source, destination)

        with mock.patch.object(
            WORKSPACE.os,
            "replace",
            side_effect=fail_replacement_install,
        ):
            with self.assertRaisesRegex(OSError, "replacement install failed"):
                WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)

        self.assertTrue(failed)
        self.assertTrue(release_root.is_dir())
        self.assertEqual(WORKSPACE.workspace_marker(release_root), original)
        self.assertEqual(
            self.git("rev-parse", "HEAD", cwd=release_root / "containerization").strip(),
            original["mainRefs"]["containerization"],
        )

    def test_interrupted_same_version_swap_restores_the_previous_checkpoint(self) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        original = WORKSPACE.workspace_marker(release_root)
        source = self.root / "sources" / "containerization"
        (source / "new-runtime.txt").write_text("new runtime\n", encoding="utf-8")
        self.git("add", "new-runtime.txt", cwd=source)
        self.git("commit", "-m", "advance main", cwd=source)
        self.git(
            "push",
            str(self.remote_root / "containerization.git"),
            "HEAD:refs/heads/main",
            cwd=source,
        )
        replace = WORKSPACE.os.replace
        recover = WORKSPACE.recover_interrupted_replacements
        recovery_calls = 0

        class SimulatedProcessExit(BaseException):
            pass

        def stop_after_backup(source: Path, destination: Path) -> None:
            source_path = Path(source)
            destination_path = Path(destination)
            if (
                destination_path == release_root
                and source_path.is_dir()
                and ".replaced." not in source_path.name
            ):
                raise SimulatedProcessExit()
            replace(source, destination)

        def stop_recovery(build_root: Path) -> None:
            nonlocal recovery_calls
            recovery_calls += 1
            if recovery_calls == 1:
                recover(build_root)
                return
            raise SimulatedProcessExit()

        with mock.patch.object(WORKSPACE.os, "replace", side_effect=stop_after_backup):
            with mock.patch.object(
                WORKSPACE,
                "recover_interrupted_replacements",
                side_effect=stop_recovery,
            ):
                with self.assertRaises(SimulatedProcessExit):
                    WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)

        self.assertFalse(release_root.exists())
        backup = next(self.build_root.glob(f".{release_root.name}.replaced.*"))
        self.assertIn("replacement", WORKSPACE.workspace_marker(backup))

        atomic_json = WORKSPACE.atomic_json
        interrupted = False

        def stop_before_journal_cleanup(
            path: Path, value: dict[str, object]
        ) -> None:
            nonlocal interrupted
            if (
                not interrupted
                and "replacement" not in value
            ):
                interrupted = True
                raise SimulatedProcessExit()
            atomic_json(path, value)

        with mock.patch.object(
            WORKSPACE,
            "atomic_json",
            side_effect=stop_before_journal_cleanup,
        ):
            with self.assertRaises(SimulatedProcessExit):
                WORKSPACE.recover_interrupted_replacements(self.build_root)

        self.assertTrue(interrupted)
        self.assertTrue(release_root.is_dir())
        self.assertFalse(backup.exists())
        self.assertIn("replacement", WORKSPACE.workspace_marker(release_root))

        WORKSPACE.recover_interrupted_replacements(self.build_root)

        self.assertEqual(WORKSPACE.workspace_marker(release_root), original)

        resumed = WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)

        self.assertEqual(resumed, release_root)
        self.assertNotEqual(WORKSPACE.workspace_marker(resumed), original)

    def test_resume_replaces_ignored_preflight_artifacts_when_main_moves(self) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        compose = release_root / "container-compose"
        artifact = compose / ".build" / "release-product"
        artifact.parent.mkdir()
        artifact.write_text("preserve me\n", encoding="utf-8")
        source = self.root / "sources" / "containerization"
        (source / "new-runtime.txt").write_text("new runtime\n", encoding="utf-8")
        self.git("add", "new-runtime.txt", cwd=source)
        self.git("commit", "-m", "advance main", cwd=source)
        self.git(
            "push",
            str(self.remote_root / "containerization.git"),
            "HEAD:refs/heads/main",
            cwd=source,
        )

        resumed = WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)

        self.assertEqual(resumed, release_root)
        self.assertFalse(artifact.exists())
        marker = WORKSPACE.workspace_marker(resumed)
        self.assertEqual(
            marker["mainRefs"]["containerization"],
            self.git("rev-parse", "HEAD", cwd=source).strip(),
        )

    def test_resume_preserves_ignored_release_evidence_when_main_moves(self) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        compose = release_root / "container-compose"
        evidence = compose / ".build" / "release-evidence" / "authority.json"
        evidence.parent.mkdir(parents=True)
        evidence.write_text('{"status":"passed"}\n', encoding="utf-8")
        original = WORKSPACE.workspace_marker(release_root)
        source = self.root / "sources" / "containerization"
        (source / "new-runtime.txt").write_text("new runtime\n", encoding="utf-8")
        self.git("add", "new-runtime.txt", cwd=source)
        self.git("commit", "-m", "advance main", cwd=source)
        self.git(
            "push",
            str(self.remote_root / "containerization.git"),
            "HEAD:refs/heads/main",
            cwd=source,
        )

        resumed = WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)

        self.assertEqual(resumed, release_root)
        self.assertEqual(evidence.read_text(encoding="utf-8"), '{"status":"passed"}\n')
        self.assertEqual(
            WORKSPACE.workspace_marker(resumed)["mainRefs"], original["mainRefs"]
        )

    def test_resume_preserves_changed_branch_state_when_main_moves(self) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        compose = release_root / "container-compose"
        self.git("switch", "-c", "release/recovery", cwd=compose)
        source = self.root / "sources" / "containerization"
        (source / "new-runtime.txt").write_text("new runtime\n", encoding="utf-8")
        self.git("add", "new-runtime.txt", cwd=source)
        self.git("commit", "-m", "advance main", cwd=source)
        self.git(
            "push",
            str(self.remote_root / "containerization.git"),
            "HEAD:refs/heads/main",
            cwd=source,
        )

        resumed = WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)

        self.assertEqual(resumed, release_root)
        self.assertEqual(
            self.git("branch", "--show-current", cwd=compose).strip(),
            "release/recovery",
        )
        marker = WORKSPACE.workspace_marker(resumed)
        self.assertNotEqual(
            marker["mainRefs"]["containerization"],
            self.git("rev-parse", "HEAD", cwd=source).strip(),
        )

    def test_resume_preserves_a_detached_linked_worktree_when_main_moves(
        self,
    ) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        compose = release_root / "container-compose"
        linked = self.root / "linked-compose"
        self.git("worktree", "add", "--detach", str(linked), "HEAD", cwd=compose)
        (linked / "operator-work.txt").write_text("operator work\n", encoding="utf-8")
        self.git("add", "operator-work.txt", cwd=linked)
        self.git("commit", "-m", "operator work", cwd=linked)
        operator_commit = self.git("rev-parse", "HEAD", cwd=linked).strip()
        source = self.root / "sources" / "containerization"
        (source / "new-runtime.txt").write_text("new runtime\n", encoding="utf-8")
        self.git("add", "new-runtime.txt", cwd=source)
        self.git("commit", "-m", "advance main", cwd=source)
        self.git(
            "push",
            str(self.remote_root / "containerization.git"),
            "HEAD:refs/heads/main",
            cwd=source,
        )

        resumed = WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)

        self.assertEqual(resumed, release_root)
        self.assertEqual(self.git("rev-parse", "HEAD", cwd=linked).strip(), operator_commit)
        self.assertEqual(
            (linked / "operator-work.txt").read_text(encoding="utf-8"),
            "operator work\n",
        )

    def test_resume_preserves_edits_hidden_by_index_flags_when_main_moves(
        self,
    ) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        compose = release_root / "container-compose"
        container = release_root / "container"
        self.git("update-index", "--skip-worktree", "README.md", cwd=compose)
        self.git("update-index", "--assume-unchanged", "README.md", cwd=container)
        (compose / "README.md").write_text("skip worktree edit\n", encoding="utf-8")
        (container / "README.md").write_text("assumed edit\n", encoding="utf-8")
        self.assertEqual(self.git("status", "--porcelain=v1", cwd=compose), "")
        self.assertEqual(self.git("status", "--porcelain=v1", cwd=container), "")
        source = self.root / "sources" / "containerization"
        (source / "new-runtime.txt").write_text("new runtime\n", encoding="utf-8")
        self.git("add", "new-runtime.txt", cwd=source)
        self.git("commit", "-m", "advance main", cwd=source)
        self.git(
            "push",
            str(self.remote_root / "containerization.git"),
            "HEAD:refs/heads/main",
            cwd=source,
        )

        resumed = WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)

        self.assertEqual(resumed, release_root)
        self.assertEqual(
            (compose / "README.md").read_text(encoding="utf-8"),
            "skip worktree edit\n",
        )
        self.assertEqual(
            (container / "README.md").read_text(encoding="utf-8"),
            "assumed edit\n",
        )

    def test_resume_preserves_a_commit_reachable_only_from_recovery_state(
        self,
    ) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        compose = release_root / "container-compose"
        initial = self.git("rev-parse", "HEAD", cwd=compose).strip()
        (compose / "operator-work.txt").write_text("operator work\n", encoding="utf-8")
        self.git("add", "operator-work.txt", cwd=compose)
        self.git("commit", "-m", "operator work", cwd=compose)
        operator_commit = self.git("rev-parse", "HEAD", cwd=compose).strip()
        self.git("reset", "--hard", initial, cwd=compose)
        self.assertEqual(self.git("status", "--porcelain=v1", cwd=compose), "")
        self.assertEqual(self.git("branch", "--show-current", cwd=compose), "main\n")
        source = self.root / "sources" / "containerization"
        (source / "new-runtime.txt").write_text("new runtime\n", encoding="utf-8")
        self.git("add", "new-runtime.txt", cwd=source)
        self.git("commit", "-m", "advance main", cwd=source)
        self.git(
            "push",
            str(self.remote_root / "containerization.git"),
            "HEAD:refs/heads/main",
            cwd=source,
        )

        resumed = WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)

        self.assertEqual(resumed, release_root)
        self.assertEqual(
            self.git("rev-parse", "ORIG_HEAD", cwd=compose).strip(), operator_commit
        )
        self.git("cat-file", "-e", f"{operator_commit}^{{commit}}", cwd=compose)

    def test_resume_preserves_a_commit_reachable_only_from_fetch_head(self) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        compose = release_root / "container-compose"
        source = self.root / "sources" / "container-compose"
        (source / "operator-work.txt").write_text("operator work\n", encoding="utf-8")
        self.git("add", "operator-work.txt", cwd=source)
        self.git("commit", "-m", "operator work", cwd=source)
        operator_commit = self.git("rev-parse", "HEAD", cwd=source).strip()
        self.git("fetch", str(source), operator_commit, cwd=compose)
        self.assertEqual(
            self.git("rev-parse", "FETCH_HEAD", cwd=compose).strip(), operator_commit
        )
        dependency = self.root / "sources" / "containerization"
        (dependency / "new-runtime.txt").write_text(
            "new runtime\n", encoding="utf-8"
        )
        self.git("add", "new-runtime.txt", cwd=dependency)
        self.git("commit", "-m", "advance main", cwd=dependency)
        self.git(
            "push",
            str(self.remote_root / "containerization.git"),
            "HEAD:refs/heads/main",
            cwd=dependency,
        )

        resumed = WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)

        self.assertEqual(resumed, release_root)
        self.assertEqual(
            self.git("rev-parse", "FETCH_HEAD", cwd=compose).strip(), operator_commit
        )
        self.git("cat-file", "-e", f"{operator_commit}^{{commit}}", cwd=compose)

    def test_resume_preserves_a_custom_local_remote_ref_when_main_moves(
        self,
    ) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        compose = release_root / "container-compose"
        operator_commit = self.git(
            "commit-tree",
            "HEAD^{tree}",
            "-m",
            "operator remote ref",
            cwd=compose,
        ).strip()
        operator_ref = "refs/remotes/origin/operator-work"
        self.git("update-ref", operator_ref, operator_commit, cwd=compose)
        source = self.root / "sources" / "containerization"
        (source / "new-runtime.txt").write_text("new runtime\n", encoding="utf-8")
        self.git("add", "new-runtime.txt", cwd=source)
        self.git("commit", "-m", "advance main", cwd=source)
        self.git(
            "push",
            str(self.remote_root / "containerization.git"),
            "HEAD:refs/heads/main",
            cwd=source,
        )

        resumed = WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)

        self.assertEqual(resumed, release_root)
        self.assertEqual(
            self.git("rev-parse", operator_ref, cwd=compose).strip(),
            operator_commit,
        )

    def test_pristine_symbolic_selector_advances_after_a_new_release_tag(self) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "--+", self.remote_root
        )
        self.assertEqual(release_root.name, "0.14.3")
        source = self.root / "sources" / "container-compose"
        self.git("tag", "0.14.3", cwd=source)
        self.git(
            "push",
            str(self.remote_root / "container-compose.git"),
            "refs/tags/0.14.3",
            cwd=source,
        )

        resumed = WORKSPACE.materialize(self.build_root, "--+", self.remote_root)

        self.assertEqual(resumed.name, "0.14.4")
        self.assertFalse(release_root.exists())

    def test_explicit_checkpoint_refreshes_after_a_remote_tag_change(self) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "0.14.4", self.remote_root
        )
        original = WORKSPACE.workspace_marker(release_root)
        source = self.root / "sources" / "container-compose"
        self.git("tag", "0.14.3", cwd=source)
        self.git(
            "push",
            str(self.remote_root / "container-compose.git"),
            "refs/tags/0.14.3",
            cwd=source,
        )

        resumed = WORKSPACE.materialize(
            self.build_root, "0.14.4", self.remote_root
        )

        self.assertEqual(resumed, release_root)
        marker = WORKSPACE.workspace_marker(resumed)
        self.assertNotEqual(marker["semanticTagTargets"], original["semanticTagTargets"])
        self.assertEqual(
            marker["semanticTagTargets"]["container-compose"]["0.14.3"],
            self.git("rev-parse", "refs/tags/0.14.3^{}", cwd=source).strip(),
        )

    def test_checkpoint_refreshes_after_an_annotated_tag_object_changes(self) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "0.14.4", self.remote_root
        )
        source = self.root / "sources" / "container-compose"
        self.git("tag", "--annotate", "--message", "first", "0.14.3", cwd=source)
        self.git(
            "push",
            str(self.remote_root / "container-compose.git"),
            "refs/tags/0.14.3",
            cwd=source,
        )
        first = WORKSPACE.materialize(
            self.build_root, "0.14.4", self.remote_root
        )
        first_object = self.git("rev-parse", "refs/tags/0.14.3", cwd=source).strip()
        self.assertEqual(
            WORKSPACE.workspace_marker(first)["semanticTagTargets"][
                "container-compose"
            ]["0.14.3"],
            first_object,
        )
        self.git(
            "tag",
            "--force",
            "--annotate",
            "--message",
            "replacement",
            "0.14.3",
            cwd=source,
        )
        second_object = self.git("rev-parse", "refs/tags/0.14.3", cwd=source).strip()
        self.assertNotEqual(second_object, first_object)
        self.git(
            "push",
            "--force",
            str(self.remote_root / "container-compose.git"),
            "refs/tags/0.14.3",
            cwd=source,
        )

        resumed = WORKSPACE.materialize(
            self.build_root, "0.14.4", self.remote_root
        )

        self.assertEqual(resumed, release_root)
        self.assertEqual(
            WORKSPACE.workspace_marker(resumed)["semanticTagTargets"][
                "container-compose"
            ]["0.14.3"],
            second_object,
        )
        self.assertEqual(
            self.git(
                "rev-parse", "refs/tags/0.14.3", cwd=resumed / "container-compose"
            ).strip(),
            second_object,
        )

    def test_symbolic_selector_revalidates_an_existing_destination(self) -> None:
        old_symbolic = WORKSPACE.materialize(
            self.build_root, "--+", self.remote_root
        )
        existing = WORKSPACE.materialize(
            self.build_root, "0.14.4", self.remote_root
        )
        source = self.root / "sources" / "containerization"
        (source / "new-runtime.txt").write_text("new runtime\n", encoding="utf-8")
        self.git("add", "new-runtime.txt", cwd=source)
        self.git("commit", "-m", "advance main", cwd=source)
        current = self.git("rev-parse", "HEAD", cwd=source).strip()
        self.git(
            "push",
            str(self.remote_root / "containerization.git"),
            "HEAD:refs/heads/main",
            cwd=source,
        )
        compose = self.root / "sources" / "container-compose"
        self.git("tag", "0.14.3", cwd=compose)
        self.git(
            "push",
            str(self.remote_root / "container-compose.git"),
            "refs/tags/0.14.3",
            cwd=compose,
        )

        resumed = WORKSPACE.materialize(self.build_root, "--+", self.remote_root)

        self.assertEqual(resumed, existing)
        self.assertFalse(old_symbolic.exists())
        marker = WORKSPACE.workspace_marker(resumed)
        self.assertEqual(marker["mainRefs"]["containerization"], current)
        self.assertEqual(
            self.git("rev-parse", "HEAD", cwd=resumed / "containerization").strip(),
            current,
        )

    def test_reused_destination_resumes_under_the_symbolic_selector(self) -> None:
        old_symbolic = WORKSPACE.materialize(
            self.build_root, "--+", self.remote_root
        )
        source = self.root / "sources" / "container-compose"
        self.git("tag", "0.14.3", cwd=source)
        self.git(
            "push",
            str(self.remote_root / "container-compose.git"),
            "refs/tags/0.14.3",
            cwd=source,
        )
        existing = WORKSPACE.materialize(
            self.build_root, "0.14.4", self.remote_root
        )

        resumed = WORKSPACE.materialize(self.build_root, "--+", self.remote_root)

        self.assertEqual(resumed, existing)
        self.assertFalse(old_symbolic.exists())
        self.assertEqual(WORKSPACE.workspace_marker(resumed)["selector"], "--+")
        retained = existing / "container-compose" / "retained.log"
        retained.write_text("operator work\n", encoding="utf-8")
        self.git("tag", "0.14.4", cwd=source)
        self.git(
            "push",
            str(self.remote_root / "container-compose.git"),
            "refs/tags/0.14.4",
            cwd=source,
        )

        resumed_again = WORKSPACE.materialize(
            self.build_root, "--+", self.remote_root
        )

        self.assertEqual(resumed_again, existing)
        self.assertEqual(retained.read_text(encoding="utf-8"), "operator work\n")

    def test_reused_destination_does_not_rebaseline_an_unpushed_tag(self) -> None:
        old_symbolic = WORKSPACE.materialize(
            self.build_root, "--+", self.remote_root
        )
        source = self.root / "sources" / "container-compose"
        self.git("tag", "0.14.3", cwd=source)
        self.git(
            "push",
            str(self.remote_root / "container-compose.git"),
            "refs/tags/0.14.3",
            cwd=source,
        )
        existing = WORKSPACE.materialize(
            self.build_root, "0.14.4", self.remote_root
        )
        compose = existing / "container-compose"
        authority_tag = f"stable-init-image-authority/{existing.name}"
        self.git("tag", authority_tag, cwd=compose)

        resumed = WORKSPACE.materialize(self.build_root, "--+", self.remote_root)

        self.assertEqual(resumed, existing)
        self.assertFalse(old_symbolic.exists())
        marker = WORKSPACE.workspace_marker(resumed)
        self.assertNotIn(
            authority_tag,
            marker["immutableTagRefs"]["container-compose"],
        )
        dependency = self.root / "sources" / "containerization"
        (dependency / "new-runtime.txt").write_text(
            "new runtime\n", encoding="utf-8"
        )
        self.git("add", "new-runtime.txt", cwd=dependency)
        self.git("commit", "-m", "advance main", cwd=dependency)
        self.git(
            "push",
            str(self.remote_root / "containerization.git"),
            "HEAD:refs/heads/main",
            cwd=dependency,
        )

        resumed_again = WORKSPACE.materialize(
            self.build_root, "--+", self.remote_root
        )

        self.assertEqual(resumed_again, existing)
        self.assertEqual(
            self.git("rev-parse", f"refs/tags/{authority_tag}", cwd=compose).strip(),
            self.git("rev-parse", "HEAD", cwd=compose).strip(),
        )

    def test_interrupted_tag_refresh_rejects_a_stale_destination(self) -> None:
        old_symbolic = WORKSPACE.materialize(
            self.build_root, "--+", self.remote_root
        )
        existing = WORKSPACE.materialize(
            self.build_root, "0.14.4", self.remote_root
        )
        compose = self.root / "sources" / "container-compose"
        self.git("tag", "0.14.3", cwd=compose)
        self.git(
            "push",
            str(self.remote_root / "container-compose.git"),
            "refs/tags/0.14.3",
            cwd=compose,
        )
        replace = WORKSPACE.os.replace
        recover = WORKSPACE.recover_interrupted_replacements
        recovery_calls = 0

        class SimulatedProcessExit(BaseException):
            pass

        def stop_before_destination_backup(source: Path, destination: Path) -> None:
            if (
                Path(source).resolve() == existing.resolve()
                and ".replaced." in Path(destination).name
            ):
                raise SimulatedProcessExit()
            replace(source, destination)

        def stop_recovery(build_root: Path) -> None:
            nonlocal recovery_calls
            recovery_calls += 1
            if recovery_calls == 1:
                recover(build_root)
                return
            raise SimulatedProcessExit()

        remove = WORKSPACE.shutil.rmtree

        def preserve_interrupted_stage(
            path: Path, *args: object, **kwargs: object
        ) -> None:
            candidate = Path(path)
            if (
                candidate.parent.resolve() == self.build_root.resolve()
                and candidate.name.startswith(f".{existing.name}.")
                and ".replaced." not in candidate.name
            ):
                return
            remove(path, *args, **kwargs)

        with mock.patch.object(
            WORKSPACE.os, "replace", side_effect=stop_before_destination_backup
        ):
            with mock.patch.object(
                WORKSPACE.shutil,
                "rmtree",
                side_effect=preserve_interrupted_stage,
            ):
                with mock.patch.object(
                    WORKSPACE,
                    "recover_interrupted_replacements",
                    side_effect=stop_recovery,
                ):
                    with self.assertRaises(SimulatedProcessExit):
                        WORKSPACE.materialize(
                            self.build_root, "--+", self.remote_root
                        )

        old_marker = WORKSPACE.workspace_marker(old_symbolic)
        replacement = old_marker["replacement"]
        self.assertIn(
            "0.14.3",
            replacement["semanticTagTargets"]["container-compose"],
        )
        stage = self.build_root / replacement["stage"]
        self.assertTrue(stage.is_dir())

        WORKSPACE.recover_interrupted_replacements(self.build_root.resolve())

        self.assertTrue(old_symbolic.is_dir())
        self.assertTrue(existing.is_dir())
        self.assertFalse(stage.exists())
        self.assertNotIn("replacement", WORKSPACE.workspace_marker(old_symbolic))
        self.assertNotIn("replacement", WORKSPACE.workspace_marker(existing))

        resumed = WORKSPACE.materialize(
            self.build_root, "--+", self.remote_root
        )

        self.assertEqual(resumed, existing)
        self.assertFalse(old_symbolic.exists())
        self.assertIn(
            "0.14.3",
            WORKSPACE.workspace_marker(resumed)["semanticTagTargets"][
                "container-compose"
            ],
        )

    def test_existing_destination_reuse_retires_the_old_checkpoint(self) -> None:
        old_symbolic = WORKSPACE.materialize(
            self.build_root, "--+", self.remote_root
        )
        compose = self.root / "sources" / "container-compose"
        self.git("tag", "0.14.3", cwd=compose)
        self.git(
            "push",
            str(self.remote_root / "container-compose.git"),
            "refs/tags/0.14.3",
            cwd=compose,
        )
        existing = WORKSPACE.materialize(
            self.build_root, "0.14.4", self.remote_root
        )
        resumed = WORKSPACE.materialize(self.build_root, "--+", self.remote_root)

        self.assertFalse(old_symbolic.exists())
        backup = next(self.build_root.glob(f".{old_symbolic.name}.replaced.*"))
        retired_marker = WORKSPACE.workspace_marker(backup)

        self.assertEqual(resumed, existing)
        self.assertTrue(backup.is_dir())
        self.assertEqual(retired_marker["state"], "retired")
        self.assertNotIn("replacement", retired_marker)

    def test_interrupted_destination_rebind_is_completed_from_the_journal(
        self,
    ) -> None:
        old_symbolic = WORKSPACE.materialize(
            self.build_root, "--+", self.remote_root
        )
        compose = self.root / "sources" / "container-compose"
        self.git("tag", "0.14.3", cwd=compose)
        self.git(
            "push",
            str(self.remote_root / "container-compose.git"),
            "refs/tags/0.14.3",
            cwd=compose,
        )
        existing = WORKSPACE.materialize(
            self.build_root, "0.14.4", self.remote_root
        )
        write_marker = WORKSPACE.atomic_json
        interrupted = False

        def stop_destination_rebind(path: Path, value: object) -> None:
            nonlocal interrupted
            if (
                not interrupted
                and path == existing / WORKSPACE.WORKSPACE_MARKER
                and isinstance(value, dict)
                and value.get("selector") == "--+"
            ):
                interrupted = True
                raise OSError("destination rebind failed")
            write_marker(path, value)

        with mock.patch.object(
            WORKSPACE,
            "atomic_json",
            side_effect=stop_destination_rebind,
        ):
            with self.assertRaisesRegex(OSError, "destination rebind failed"):
                WORKSPACE.materialize(self.build_root, "--+", self.remote_root)

        self.assertTrue(interrupted)
        self.assertFalse(old_symbolic.exists())
        backup = next(self.build_root.glob(f".{old_symbolic.name}.replaced.*"))
        self.assertIn("replacement", WORKSPACE.workspace_marker(backup))
        self.assertEqual(WORKSPACE.workspace_marker(existing)["selector"], "0.14.4")

        resumed = WORKSPACE.materialize(self.build_root, "--+", self.remote_root)

        self.assertEqual(resumed, existing)
        self.assertTrue(backup.is_dir())
        self.assertEqual(WORKSPACE.workspace_marker(backup)["state"], "retired")
        self.assertNotIn("replacement", WORKSPACE.workspace_marker(backup))
        self.assertEqual(WORKSPACE.workspace_marker(existing)["selector"], "--+")

    def test_interrupted_destination_reuse_rolls_back_a_changed_source(
        self,
    ) -> None:
        old_symbolic = WORKSPACE.materialize(
            self.build_root, "--+", self.remote_root
        )
        compose = self.root / "sources" / "container-compose"
        self.git("tag", "0.14.3", cwd=compose)
        self.git(
            "push",
            str(self.remote_root / "container-compose.git"),
            "refs/tags/0.14.3",
            cwd=compose,
        )
        existing = WORKSPACE.materialize(
            self.build_root, "0.14.4", self.remote_root
        )
        replace = WORKSPACE.os.replace

        class SimulatedProcessExit(BaseException):
            pass

        def stop_before_source_retirement(source: Path, destination: Path) -> None:
            if (
                Path(source).resolve() == old_symbolic.resolve()
                and ".replaced." in Path(destination).name
            ):
                raise SimulatedProcessExit()
            replace(source, destination)

        with mock.patch.object(
            WORKSPACE.os, "replace", side_effect=stop_before_source_retirement
        ):
            with self.assertRaises(SimulatedProcessExit):
                WORKSPACE.materialize(self.build_root, "--+", self.remote_root)

        self.assertIn("replacement", WORKSPACE.workspace_marker(old_symbolic))
        source_file = old_symbolic / "container-compose" / "README.md"
        source_file.write_text("operator work after interruption\n", encoding="utf-8")

        resumed = WORKSPACE.materialize(self.build_root, "--+", self.remote_root)

        self.assertEqual(resumed.resolve(), old_symbolic.resolve())
        self.assertEqual(
            source_file.read_text(encoding="utf-8"),
            "operator work after interruption\n",
        )
        self.assertNotIn("replacement", WORKSPACE.workspace_marker(old_symbolic))
        self.assertEqual(WORKSPACE.workspace_marker(old_symbolic)["selector"], "--+")
        self.assertEqual(WORKSPACE.workspace_marker(existing)["selector"], "0.14.4")

    def test_destination_reuse_preserves_a_concurrent_source_edit(self) -> None:
        old_symbolic = WORKSPACE.materialize(
            self.build_root, "--+", self.remote_root
        )
        compose = self.root / "sources" / "container-compose"
        self.git("tag", "0.14.3", cwd=compose)
        self.git(
            "push",
            str(self.remote_root / "container-compose.git"),
            "refs/tags/0.14.3",
            cwd=compose,
        )
        existing = WORKSPACE.materialize(
            self.build_root, "0.14.4", self.remote_root
        )
        replace = WORKSPACE.os.replace
        changed = False

        def edit_after_retirement(source: Path, destination: Path) -> None:
            nonlocal changed
            replace(source, destination)
            candidate = Path(destination)
            if (
                not changed
                and Path(source).resolve() == old_symbolic.resolve()
                and ".replaced." in candidate.name
            ):
                changed = True
                (candidate / "container-compose" / "README.md").write_text(
                    "operator work\n", encoding="utf-8"
                )

        with mock.patch.object(
            WORKSPACE.os, "replace", side_effect=edit_after_retirement
        ):
            with self.assertRaisesRegex(
                WORKSPACE.WorkspaceError, "changed while being retired"
            ):
                WORKSPACE.materialize(self.build_root, "--+", self.remote_root)

        self.assertTrue(changed)
        self.assertTrue(old_symbolic.is_dir())
        self.assertEqual(
            (old_symbolic / "container-compose" / "README.md").read_text(
                encoding="utf-8"
            ),
            "operator work\n",
        )
        self.assertNotIn("replacement", WORKSPACE.workspace_marker(old_symbolic))
        self.assertEqual(WORKSPACE.workspace_marker(existing)["selector"], "0.14.4")

    def test_new_destination_is_not_installed_when_source_retirement_changes(
        self,
    ) -> None:
        old_symbolic = WORKSPACE.materialize(
            self.build_root, "--+", self.remote_root
        )
        compose = self.root / "sources" / "container-compose"
        self.git("tag", "0.14.3", cwd=compose)
        self.git(
            "push",
            str(self.remote_root / "container-compose.git"),
            "refs/tags/0.14.3",
            cwd=compose,
        )
        replace = WORKSPACE.os.replace
        changed = False

        def edit_after_retirement(source: Path, destination: Path) -> None:
            nonlocal changed
            replace(source, destination)
            candidate = Path(destination)
            if (
                not changed
                and Path(source).resolve() == old_symbolic.resolve()
                and ".replaced." in candidate.name
            ):
                changed = True
                (candidate / "container-compose" / "README.md").write_text(
                    "operator work\n", encoding="utf-8"
                )

        with mock.patch.object(
            WORKSPACE.os, "replace", side_effect=edit_after_retirement
        ):
            with self.assertRaisesRegex(
                WORKSPACE.WorkspaceError, "changed while being retired"
            ):
                WORKSPACE.materialize(self.build_root, "--+", self.remote_root)

        self.assertTrue(changed)
        self.assertTrue(old_symbolic.is_dir())
        self.assertFalse((self.build_root / "0.14.4").exists())
        self.assertEqual(
            (old_symbolic / "container-compose" / "README.md").read_text(
                encoding="utf-8"
            ),
            "operator work\n",
        )
        self.assertNotIn("replacement", WORKSPACE.workspace_marker(old_symbolic))
        retained = WORKSPACE.retained_workspace(self.build_root, "--+")
        self.assertIsNotNone(retained)
        assert retained is not None
        self.assertEqual(retained.resolve(), old_symbolic.resolve())

    def test_interrupted_reuse_recovers_a_modified_destination(self) -> None:
        old_symbolic = WORKSPACE.materialize(
            self.build_root, "--+", self.remote_root
        )
        existing = WORKSPACE.materialize(
            self.build_root, "0.14.4", self.remote_root
        )
        destination_file = existing / "container-compose" / "README.md"
        destination_file.write_text("modified destination\n", encoding="utf-8")
        compose = self.root / "sources" / "container-compose"
        self.git("tag", "0.14.3", cwd=compose)
        self.git(
            "push",
            str(self.remote_root / "container-compose.git"),
            "refs/tags/0.14.3",
            cwd=compose,
        )
        write_marker = WORKSPACE.atomic_json
        interrupted = False

        def stop_destination_rebind(path: Path, value: object) -> None:
            nonlocal interrupted
            if (
                not interrupted
                and path == existing / WORKSPACE.WORKSPACE_MARKER
                and isinstance(value, dict)
                and value.get("selector") == "--+"
            ):
                interrupted = True
                raise OSError("modified destination rebind failed")
            write_marker(path, value)

        with mock.patch.object(
            WORKSPACE,
            "atomic_json",
            side_effect=stop_destination_rebind,
        ):
            with self.assertRaisesRegex(
                OSError, "modified destination rebind failed"
            ):
                WORKSPACE.materialize(self.build_root, "--+", self.remote_root)

        self.assertTrue(interrupted)
        self.assertFalse(old_symbolic.exists())
        backup = next(self.build_root.glob(f".{old_symbolic.name}.replaced.*"))
        self.assertEqual(WORKSPACE.workspace_marker(existing)["selector"], "0.14.4")

        resumed = WORKSPACE.materialize(
            self.build_root, "--+", self.remote_root
        )

        self.assertEqual(resumed, existing)
        self.assertTrue(backup.is_dir())
        self.assertEqual(WORKSPACE.workspace_marker(backup)["state"], "retired")
        self.assertNotIn("replacement", WORKSPACE.workspace_marker(backup))
        self.assertEqual(
            destination_file.read_text(encoding="utf-8"),
            "modified destination\n",
        )
        self.assertEqual(WORKSPACE.workspace_marker(existing)["selector"], "--+")

    def test_retirement_preserves_writes_after_validation(self) -> None:
        old_symbolic = WORKSPACE.materialize(
            self.build_root, "--+", self.remote_root
        )
        compose = self.root / "sources" / "container-compose"
        self.git("tag", "0.14.3", cwd=compose)
        self.git(
            "push",
            str(self.remote_root / "container-compose.git"),
            "refs/tags/0.14.3",
            cwd=compose,
        )
        existing = WORKSPACE.materialize(
            self.build_root, "0.14.4", self.remote_root
        )
        matches_checkpoint = WORKSPACE.workspace_matches_initial_checkpoint
        written = False

        def write_after_validation(path: Path, marker: dict[str, object]) -> bool:
            nonlocal written
            matches = matches_checkpoint(path, marker)
            if matches and not written and ".replaced." in path.name:
                written = True
                (path / "container-compose" / "late-writer.txt").write_text(
                    "operator work after validation\n", encoding="utf-8"
                )
            return matches

        with mock.patch.object(
            WORKSPACE,
            "workspace_matches_initial_checkpoint",
            side_effect=write_after_validation,
        ):
            resumed = WORKSPACE.materialize(
                self.build_root, "--+", self.remote_root
            )

        backup = next(self.build_root.glob(f".{old_symbolic.name}.replaced.*"))
        retired_marker = WORKSPACE.workspace_marker(backup)
        self.assertTrue(written)
        self.assertEqual(resumed, existing)
        self.assertEqual(
            (backup / "container-compose" / "late-writer.txt").read_text(
                encoding="utf-8"
            ),
            "operator work after validation\n",
        )
        self.assertEqual(retired_marker["state"], "retired")
        self.assertNotIn("replacement", retired_marker)

    def test_resume_refreshes_the_mutable_current_tag(self) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        source = self.root / "sources" / "container-compose"
        (source / "README.md").write_text("# promoted current\n", encoding="utf-8")
        self.git("add", "README.md", cwd=source)
        self.git("commit", "-m", "promote current", cwd=source)
        promoted = self.git("rev-parse", "HEAD", cwd=source).strip()
        self.git(
            "push",
            "--force",
            str(self.remote_root / "container-compose.git"),
            "HEAD:refs/tags/current",
            cwd=source,
        )

        resumed = WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)

        self.assertEqual(resumed, release_root)
        self.assertEqual(
            self.git(
                "rev-parse",
                "refs/tags/current",
                cwd=resumed / "container-compose",
            ).strip(),
            promoted,
        )

    def test_resume_rejects_a_missing_remote_current_tag(self) -> None:
        WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)
        source = self.root / "sources" / "container-compose"
        self.git(
            "push",
            str(self.remote_root / "container-compose.git"),
            ":refs/tags/current",
            cwd=source,
        )

        with self.assertRaisesRegex(
            WORKSPACE.WorkspaceError, "current tag is missing"
        ):
            WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)

    def test_missing_baseline_object_is_fetched_into_retained_workspace(self) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        container = release_root / "container"
        marker = WORKSPACE.workspace_marker(release_root)
        expected = marker["mainRefs"]["container"]
        objects = container / ".git" / "objects"
        shutil.rmtree(objects)
        (objects / "info").mkdir(parents=True)
        (objects / "pack").mkdir()

        WORKSPACE.verify_workspace(release_root, self.build_root)

        self.git("cat-file", "-e", f"{expected}^{{commit}}", cwd=container)

    def test_incomplete_clone_is_cleaned_before_retry(self) -> None:
        WORKSPACE.safe_build_root(self.build_root)
        stage = self.build_root / ".0.15.0.interrupted"
        stage.mkdir()
        WORKSPACE.atomic_json(
            stage / WORKSPACE.WORKSPACE_MARKER,
            {
                "owner": "container-compose",
                "schemaVersion": 1,
                "stageHost": WORKSPACE.socket.gethostname(),
                "stagePid": 99_999_999,
                "state": "cloning",
            },
        )

        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )

        self.assertFalse(stage.exists())
        self.assertEqual(release_root.name, "0.15.0")

    def test_semantic_tag_change_during_clone_rejects_the_snapshot(self) -> None:
        clone_workspace = WORKSPACE.clone_workspace

        def clone_then_publish_tag(
            stage: Path,
            refs: dict[str, str],
            remote_root: Path | None,
        ) -> None:
            clone_workspace(stage, refs, remote_root)
            source = self.root / "sources" / "container-compose"
            self.git("tag", "0.15.0", cwd=source)
            self.git(
                "push",
                str(self.remote_root / "container-compose.git"),
                "refs/tags/0.15.0",
                cwd=source,
            )

        with mock.patch.object(
            WORKSPACE,
            "clone_workspace",
            side_effect=clone_then_publish_tag,
        ):
            with self.assertRaisesRegex(
                WORKSPACE.WorkspaceError, "semantic tag moved"
            ):
                WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)

        self.assertFalse((self.build_root / "0.15.0").exists())
        self.assertEqual(
            [path for path in self.build_root.iterdir() if path.is_dir()],
            [],
        )

    def test_cleanup_requires_both_markers_and_exact_parent(self) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        marker_path = release_root / WORKSPACE.WORKSPACE_MARKER
        marker = json.loads(marker_path.read_text(encoding="utf-8"))
        marker["owner"] = "someone-else"
        marker_path.write_text(json.dumps(marker), encoding="utf-8")

        with self.assertRaisesRegex(WORKSPACE.WorkspaceError, "marker is invalid"):
            WORKSPACE.cleanup(release_root, self.build_root)
        self.assertTrue(release_root.exists())

        marker["owner"] = "container-compose"
        marker_path.write_text(json.dumps(marker), encoding="utf-8")
        WORKSPACE.cleanup(release_root, self.build_root)
        self.assertFalse(release_root.exists())

    def test_live_claim_blocks_concurrent_release_and_can_be_cleared(self) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        WORKSPACE.claim(release_root, self.build_root, os.getpid())

        with self.assertRaisesRegex(WORKSPACE.WorkspaceError, "already active"):
            WORKSPACE.claim(release_root, self.build_root, os.getpid())
        with self.assertRaisesRegex(WORKSPACE.WorkspaceError, "already active"):
            WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)
        with self.assertRaisesRegex(WORKSPACE.WorkspaceError, "still claimed"):
            WORKSPACE.cleanup(release_root, self.build_root)

        WORKSPACE.release_claim(release_root, self.build_root, os.getpid())
        WORKSPACE.cleanup(release_root, self.build_root)

    def test_dead_same_host_claim_is_recovered(self) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        marker_path = release_root / WORKSPACE.WORKSPACE_MARKER
        marker = WORKSPACE.workspace_marker(release_root)
        marker["leaseHost"] = WORKSPACE.socket.gethostname()
        marker["leasePid"] = 99_999_999
        WORKSPACE.atomic_json(marker_path, marker)

        WORKSPACE.claim(release_root, self.build_root, os.getpid())

        recovered = WORKSPACE.workspace_marker(release_root)
        self.assertEqual(recovered["leaseHost"], WORKSPACE.socket.gethostname())
        self.assertEqual(recovered["leasePid"], os.getpid())

    def test_execute_lease_belongs_to_the_running_release_child(self) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        ready = self.root / "release-child-ready"
        child = subprocess.Popen(
            [
                sys.executable,
                str(MODULE_PATH),
                "execute",
                "--build-root",
                str(self.build_root),
                str(release_root),
                sys.executable,
                "-c",
                "import pathlib, sys, time; "
                "pathlib.Path(sys.argv[1]).touch(); time.sleep(30)",
                str(ready),
            ]
        )
        try:
            for _ in range(100):
                if ready.exists():
                    break
                if child.poll() is not None:
                    self.fail(f"release child exited early with {child.returncode}")
                time.sleep(0.01)
            else:
                self.fail("release child did not become ready")

            marker = WORKSPACE.workspace_marker(release_root)
            self.assertEqual(marker["leasePid"], child.pid)
            with self.assertRaisesRegex(WORKSPACE.WorkspaceError, "already active"):
                WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)
        finally:
            if child.poll() is None:
                child.terminate()
            child.wait(timeout=5)

        resumed = WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)
        self.assertEqual(resumed, release_root)

    def test_git_operations_have_a_bounded_deadline(self) -> None:
        timeout = subprocess.TimeoutExpired(["git", "status"], 300)
        with mock.patch.object(WORKSPACE.subprocess, "run", side_effect=timeout):
            with self.assertRaisesRegex(
                WORKSPACE.WorkspaceError, "git status exceeded 300 seconds"
            ):
                WORKSPACE.run_git("status")

    def test_remote_retargeting_is_rejected(self) -> None:
        release_root = WORKSPACE.materialize(
            self.build_root, "-+-", self.remote_root
        )
        compose = release_root / "container-compose"
        self.git("remote", "set-url", "origin", "https://example.com/wrong.git", cwd=compose)

        with self.assertRaisesRegex(WORKSPACE.WorkspaceError, "remote changed"):
            WORKSPACE.verify_workspace(release_root, self.build_root)

    def test_cli_accepts_symbolic_selector_after_option_separator(self) -> None:
        completed = subprocess.run(
            [
                sys.executable,
                str(MODULE_PATH),
                "--remote-root",
                str(self.remote_root),
                "materialize",
                "--build-root",
                str(self.build_root),
                "--",
                "-+-",
            ],
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(Path(completed.stdout.strip()).name, "0.15.0")

    def test_active_release_rejects_an_unmarked_checkout_before_work(self) -> None:
        unmarked = self.root / "unmarked" / "0.15.0"
        unmarked.mkdir(parents=True)
        environment = os.environ.copy()
        environment.update(
            {
                "CONTAINER_STACK_RELEASE_BUILD_ROOT": str(self.build_root),
                "CONTAINER_STACK_RELEASE_ROOT": str(unmarked),
                "CONTAINER_STACK_RELEASE_WORKSPACE_ACTIVE": "1",
            }
        )

        completed = subprocess.run(
            ["/bin/bash", str(RELEASE_SCRIPT), "release", "0.15.0", "--execute"],
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("escaped its build root", completed.stderr)


if __name__ == "__main__":
    unittest.main()
