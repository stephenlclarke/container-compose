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

"""Tests for isolated local Swift stack execution."""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).with_name("run-with-local-swift-stack.py")
SPEC = importlib.util.spec_from_file_location("run_with_local_swift_stack", MODULE_PATH)
assert SPEC and SPEC.loader
STACK = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = STACK
SPEC.loader.exec_module(STACK)


class LocalSwiftStackTests(unittest.TestCase):
    """Local dependency overrides never become release graph inputs."""

    def test_clean_environment_removes_manifest_overrides(self) -> None:
        original = os.environ.copy()
        try:
            for name in STACK.OVERRIDE_ENVIRONMENT:
                os.environ[name] = "/untrusted/local/path"
            environment = STACK.clean_environment()
        finally:
            os.environ.clear()
            os.environ.update(original)

        for name in STACK.OVERRIDE_ENVIRONMENT:
            self.assertNotIn(name, environment)

    def test_authoritative_sources_match_the_resolved_graph(self) -> None:
        resolved = json.loads(
            (MODULE_PATH.parents[2] / "Package.resolved").read_text(
                encoding="utf-8"
            )
        )
        locations = {
            pin["identity"]: pin["location"]
            for pin in resolved["pins"]
        }

        for identity, source in STACK.AUTHORITATIVE_SOURCES.items():
            self.assertEqual(source, locations[identity])

    def test_lockfile_is_not_rewritten_when_contents_match(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            lockfile = Path(temporary) / "Package.resolved"
            contents = b'{"pins":[]}\n'
            lockfile.write_bytes(contents)
            original_mtime = lockfile.stat().st_mtime_ns

            self.assertFalse(STACK.restore_lockfile(lockfile, contents))
            self.assertEqual(lockfile.stat().st_mtime_ns, original_mtime)

    def test_active_edits_reports_every_edited_dependency(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary) / "workspace-state.json"
            state.write_text(
                json.dumps(
                    {
                        "object": {
                            "dependencies": [
                                {
                                    "packageRef": {"identity": "container"},
                                    "state": {"name": "edited", "path": "/tmp/container"},
                                },
                                {
                                    "packageRef": {"identity": "swift-log"},
                                    "state": {"name": "sourceControlCheckout"},
                                },
                                {
                                    "packageRef": {"identity": "containerization"},
                                    "state": {
                                        "name": "edited",
                                        "path": "/tmp/containerization",
                                    },
                                },
                            ]
                        }
                    }
                ),
                encoding="utf-8",
            )

            self.assertEqual(
                STACK.active_edit_paths(state),
                {
                    "container": Path("/tmp/container").resolve(),
                    "containerization": Path("/tmp/containerization").resolve(),
                },
            )

    def test_dependency_paths_must_be_absolute_packages(self) -> None:
        with self.assertRaisesRegex(SystemExit, "must be absolute"):
            STACK.validate_dependency("container", "../container")

    def test_expected_object_requires_path_commit_and_tree(self) -> None:
        with self.assertRaisesRegex(SystemExit, "path is required"):
            STACK.validate_dependency(
                "container", None, "a" * 40, "b" * 40
            )
        with tempfile.TemporaryDirectory() as temporary:
            package = Path(temporary)
            (package / "Package.swift").write_text(
                "// swift-tools-version: 6.2\n", encoding="utf-8"
            )
            with self.assertRaisesRegex(SystemExit, "supplied together"):
                STACK.validate_dependency(
                    "container", str(package), "a" * 40, None
                )

    @staticmethod
    def create_git_dependency(root: Path) -> tuple[Path, Path, str, str]:
        authority = root / "authority"
        checkout = root / "checkout"
        authority.mkdir()
        (authority / "Package.swift").write_text(
            "// swift-tools-version: 6.2\n", encoding="utf-8"
        )
        subprocess.run(["git", "init", "-q", authority], check=True)
        subprocess.run(
            ["git", "-C", authority, "add", "Package.swift"], check=True
        )
        commit = [
            "git",
            "-C",
            authority,
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "commit",
            "-q",
        ]
        subprocess.run([*commit, "-m", "initial"], check=True)
        subprocess.run(
            ["git", "clone", "--no-local", "-q", authority, checkout], check=True
        )
        subprocess.run([*commit, "--allow-empty", "-m", "promoted"], check=True)
        promoted = subprocess.run(
            ["git", "-C", authority, "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        tree = subprocess.run(
            ["git", "-C", authority, "rev-parse", "HEAD^{tree}"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        return authority, checkout, promoted, tree

    def test_present_expected_commit_does_not_fetch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            authority, checkout, promoted, tree = self.create_git_dependency(root)
            subprocess.run(
                ["git", "-C", checkout, "fetch", "-q", str(authority), promoted],
                check=True,
            )
            dependency = STACK.Dependency("container", checkout, promoted, tree)

            with mock.patch.object(STACK, "fetch_dependency_object") as fetch:
                STACK.recover_dependency_object(dependency)

            fetch.assert_not_called()

    def test_missing_expected_commit_is_recovered_from_fixed_authority(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            authority, checkout, promoted, tree = self.create_git_dependency(root)
            dependency = STACK.Dependency("container", checkout, promoted, tree)

            with mock.patch.dict(
                STACK.AUTHORITATIVE_SOURCES, {"container": str(authority)}
            ):
                record = STACK.dependency_record(dependency)

            self.assertEqual(record["tree"], tree)
            self.assertTrue(
                STACK.git_object_exists(checkout, f"{promoted}^{{commit}}")
            )

    def test_recovered_commit_with_wrong_tree_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            authority, checkout, promoted, _ = self.create_git_dependency(root)
            dependency = STACK.Dependency("container", checkout, promoted, "0" * 40)

            with mock.patch.dict(
                STACK.AUTHORITATIVE_SOURCES, {"container": str(authority)}
            ):
                with self.assertRaisesRegex(SystemExit, "expected 0000"):
                    STACK.recover_dependency_object(dependency)

    def test_unavailable_expected_commit_fails_without_prompting(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            authority, checkout, _, tree = self.create_git_dependency(root)
            unavailable = "f" * 40
            dependency = STACK.Dependency("container", checkout, unavailable, tree)

            with mock.patch.dict(
                STACK.AUTHORITATIVE_SOURCES, {"container": str(authority)}
            ):
                with self.assertRaisesRegex(SystemExit, "could not recover"):
                    STACK.recover_dependency_object(dependency)

    def test_expected_commit_fetch_has_a_bounded_failure(self) -> None:
        dependency = STACK.Dependency(
            "container", Path("/tmp/container"), "f" * 40, "e" * 40
        )

        with mock.patch.object(STACK, "git_object_exists", return_value=False):
            with mock.patch.object(
                STACK,
                "fetch_dependency_object",
                side_effect=subprocess.TimeoutExpired("git fetch", 60),
            ):
                with self.assertRaisesRegex(SystemExit, "timed out recovering"):
                    STACK.recover_dependency_object(dependency)

    def test_configured_clone_remote_cannot_replace_fixed_authority(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            authority, checkout, promoted, tree = self.create_git_dependency(root)
            subprocess.run(
                [
                    "git",
                    "-C",
                    checkout,
                    "remote",
                    "set-url",
                    "origin",
                    str(root / "untrusted"),
                ],
                check=True,
            )
            dependency = STACK.Dependency("container", checkout, promoted, tree)

            with mock.patch.dict(
                STACK.AUTHORITATIVE_SOURCES, {"container": str(authority)}
            ):
                STACK.recover_dependency_object(dependency)

            self.assertTrue(
                STACK.git_object_exists(checkout, f"{promoted}^{{commit}}")
            )

    def test_session_resumes_when_commit_changes_but_tree_does_not(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            dependency_root = root / "container"
            dependency_root.mkdir()
            (dependency_root / "Package.swift").write_text(
                "// swift-tools-version: 6.2\n", encoding="utf-8"
            )
            subprocess.run(["git", "init", "-q", dependency_root], check=True)
            subprocess.run(
                ["git", "-C", dependency_root, "add", "Package.swift"], check=True
            )
            commit = [
                "git",
                "-C",
                dependency_root,
                "-c",
                "user.name=Fixture",
                "-c",
                "user.email=fixture@example.invalid",
                "commit",
                "-q",
            ]
            subprocess.run([*commit, "-m", "first"], check=True)
            dependency = STACK.validate_dependency("container", str(dependency_root))
            assert dependency is not None
            records = STACK.dependency_records((dependency,))

            lockfile = root / "Package.resolved"
            original = b'{"pins":[]}\n'
            lockfile.write_bytes(original)
            STACK.write_recovery_journal(
                root, original, (dependency,), records
            )
            self.assertFalse(
                (root / ".build" / "local-swift-stack" / "Package.resolved.backup").exists()
            )
            workspace_state = root / ".build" / "workspace-state.json"
            workspace_state.write_text(
                json.dumps(
                    {
                        "object": {
                            "dependencies": [
                                {
                                    "packageRef": {"identity": "container"},
                                    "state": {
                                        "name": "edited",
                                        "path": str(dependency_root),
                                    },
                                }
                            ]
                        }
                    }
                ),
                encoding="utf-8",
            )
            subprocess.run([*commit, "--allow-empty", "-m", "promoted"], check=True)
            lockfile.write_bytes(b"edited\n")

            promoted_records = STACK.dependency_records((dependency,))
            self.assertEqual(promoted_records, records)
            self.assertTrue(
                STACK.can_resume(
                    root, lockfile, (dependency,), promoted_records
                )
            )
            self.assertEqual(lockfile.read_bytes(), original)

    def test_recover_restores_an_interrupted_lock_transaction(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lockfile = root / "Package.resolved"
            original = b'{"pins":[]}\n'
            lockfile.write_bytes(b"locally edited\n")
            recovery = root / ".build" / "local-swift-stack"
            recovery.mkdir(parents=True)
            (recovery / "Package.resolved.backup").write_bytes(original)
            (recovery / "journal.json").write_text(
                json.dumps(
                    {
                        "schema": 1,
                        "identities": [],
                        "package_resolved_sha256": STACK.sha256(original),
                    }
                ),
                encoding="utf-8",
            )

            STACK.recover(root, lockfile, "/usr/bin/true", {})

            self.assertEqual(lockfile.read_bytes(), original)
            self.assertFalse((recovery / "Package.resolved.backup").exists())
            self.assertFalse((recovery / "journal.json").exists())

    def test_recover_quarantines_workspace_when_unedit_cannot_resolve(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lockfile = root / "Package.resolved"
            original = b'{"pins":[]}\n'
            lockfile.write_bytes(b"locally edited\n")
            recovery = root / ".build" / "local-swift-stack"
            recovery.mkdir(parents=True)
            backup = recovery / "Package.resolved.backup"
            journal = recovery / "journal.json"
            backup.write_bytes(original)
            journal.write_text(
                json.dumps(
                    {
                        "schema": 1,
                        "identities": ["container"],
                        "package_resolved_sha256": STACK.sha256(original),
                    }
                ),
                encoding="utf-8",
            )
            (root / ".build" / "workspace-state.json").write_text(
                json.dumps(
                    {
                        "object": {
                            "dependencies": [
                                {
                                    "packageRef": {"identity": "container"},
                                    "state": {"name": "edited", "path": "/tmp/container"},
                                }
                            ]
                        }
                    }
                ),
                encoding="utf-8",
            )

            with mock.patch.object(STACK, "unedit_dependencies", return_value=1):
                STACK.recover(root, lockfile, "/usr/bin/false", {})

            self.assertEqual(lockfile.read_bytes(), original)
            self.assertFalse((root / ".build").exists())
            quarantines = list(
                root.glob(".build.local-swift-stack-quarantine-*")
            )
            self.assertEqual(len(quarantines), 1)
            self.assertTrue(
                (quarantines[0] / "local-swift-stack/journal.json").is_file()
            )

    def test_quarantine_rejects_an_indirect_build_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            outside = root / "outside"
            outside.mkdir()
            (root / ".build").symlink_to(outside, target_is_directory=True)

            with self.assertRaisesRegex(SystemExit, "recovery state retained"):
                STACK.quarantine_workspace(root, b"lock")

            self.assertTrue((root / ".build").is_symlink())


if __name__ == "__main__":
    unittest.main()
