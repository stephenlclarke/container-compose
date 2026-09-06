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

        resumed = WORKSPACE.materialize(self.build_root, "-+-", self.remote_root)

        self.assertEqual(resumed, release_root)
        self.assertEqual(self.git("rev-parse", "HEAD", cwd=compose).strip(), candidate)
        self.assertEqual(
            (compose / "retained.log").read_text(encoding="utf-8"),
            "interrupted\n",
        )

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
