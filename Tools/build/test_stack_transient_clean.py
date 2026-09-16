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
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("stack-transient-clean.py")
SPEC = importlib.util.spec_from_file_location("stack_transient_clean", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class StackTransientCleanTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        temporary_root = Path(temporary.name).resolve()
        self.root = temporary_root / "transient"
        self.root.mkdir()
        (self.root / MODULE.MARKER).write_text(MODULE.MARKER_VALUE, encoding="utf-8")
        self.retained = temporary_root / "retained"
        self.retained.mkdir()
        (self.retained / "compose").write_text("keep", encoding="utf-8")
        (self.root / "scratch/nested").mkdir(parents=True)
        (self.root / "scratch/nested/output").write_text("discard", encoding="utf-8")

    def invoke(self, *arguments: str) -> int:
        with redirect_stdout(StringIO()):
            return MODULE.main(["--root", str(self.root), *arguments])

    def test_plan_does_not_delete_transient_or_retained_data(self) -> None:
        self.assertEqual(self.invoke(), 0)
        self.assertTrue((self.root / "scratch/nested/output").exists())
        self.assertTrue((self.retained / "compose").exists())

    def test_execute_removes_only_allowlisted_transient_directories(self) -> None:
        (self.root / "unrelated").write_text("preserve", encoding="utf-8")
        self.assertEqual(self.invoke("--execute"), 0)
        self.assertFalse((self.root / "scratch").exists())
        self.assertTrue((self.root / "unrelated").exists())
        self.assertTrue((self.root / MODULE.MARKER).exists())
        self.assertTrue((self.retained / "compose").exists())

    def test_execute_cleans_process_temporary_state_and_recreates_live_roots(self) -> None:
        (self.root / "process-tmp/nested").mkdir(parents=True)
        (self.root / "process-tmp/nested/output").write_text(
            "discard", encoding="utf-8"
        )

        self.assertEqual(
            self.invoke(
                "--execute",
                "--recreate",
                "scratch",
                "--recreate",
                "process-tmp",
            ),
            0,
        )

        self.assertEqual(list((self.root / "scratch").iterdir()), [])
        self.assertEqual(list((self.root / "process-tmp").iterdir()), [])

    def test_symlink_target_is_unlinked_without_following_it(self) -> None:
        outside = self.retained / "outside"
        outside.mkdir()
        (outside / "keep").write_text("keep", encoding="utf-8")
        (self.root / "tmp").symlink_to(outside, target_is_directory=True)
        self.assertEqual(self.invoke("--execute"), 0)
        self.assertFalse((self.root / "tmp").exists())
        self.assertTrue((outside / "keep").exists())

    def test_dangling_live_root_symlink_is_removed_before_recreation(self) -> None:
        MODULE.remove_tree(self.root / "scratch")
        scratch = self.root / "scratch"
        scratch.symlink_to(self.retained / "missing", target_is_directory=True)
        self.assertFalse(scratch.exists())
        self.assertTrue(scratch.is_symlink())

        self.assertEqual(
            self.invoke("--execute", "--recreate", "scratch"),
            0,
        )

        self.assertTrue(scratch.is_dir())
        self.assertFalse(scratch.is_symlink())
        self.assertEqual(list(scratch.iterdir()), [])

    def test_wrong_marker_refuses_cleanup(self) -> None:
        (self.root / MODULE.MARKER).write_text("wrong\n", encoding="utf-8")
        self.assertEqual(self.invoke("--execute"), 2)
        self.assertTrue((self.root / "scratch/nested/output").exists())

    def test_unsafe_roots_and_missing_marker_are_refused(self) -> None:
        relative = Path("relative")
        with self.assertRaises(MODULE.CleanupError):
            MODULE.validate_root(relative)
        with self.assertRaises(MODULE.CleanupError):
            MODULE.validate_root(Path("/"))

        (self.root / MODULE.MARKER).unlink()
        with self.assertRaisesRegex(MODULE.CleanupError, "no regular ownership marker"):
            MODULE.validate_root(self.root)

    def test_symbolic_link_root_is_refused(self) -> None:
        link = self.root.parent / "transient-link"
        link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(MODULE.CleanupError, "unsafe transient root"):
            MODULE.validate_root(link)

    def test_recreate_rejects_unknown_or_existing_directories(self) -> None:
        with self.assertRaisesRegex(MODULE.CleanupError, "unsupported"):
            MODULE.recreate_directories(self.root, ["downloads"])
        with self.assertRaisesRegex(MODULE.CleanupError, "still exists"):
            MODULE.recreate_directories(self.root, ["scratch"])

    def test_recreate_requires_execute(self) -> None:
        self.assertEqual(self.invoke("--recreate", "process-tmp"), 2)

    def test_empty_report_and_optional_atomic_output(self) -> None:
        MODULE.remove_tree(self.root / "scratch")
        report = MODULE.render_report(
            self.root, execute=False, phase="empty", records=[]
        )
        self.assertIn("| clean | — |", report)
        self.assertIsNone(MODULE.write_atomic(None, report))

    def test_directory_replaced_by_symlink_during_cleanup_cannot_escape(self) -> None:
        outside = self.retained / "outside"
        outside.mkdir()
        sentinel = outside / "keep"
        sentinel.write_text("keep", encoding="utf-8")
        original_open = MODULE.os.open
        replaced = False

        def replace_before_open(path: object, flags: int, *args: object, **kwargs: object) -> int:
            nonlocal replaced
            if path == "scratch" and kwargs.get("dir_fd") is not None and not replaced:
                replaced = True
                (self.root / "scratch").rename(self.root / "scratch-original")
                (self.root / "scratch").symlink_to(outside, target_is_directory=True)
            return original_open(path, flags, *args, **kwargs)

        with mock.patch.object(MODULE.os, "open", side_effect=replace_before_open):
            with self.assertRaises(OSError):
                MODULE.remove_tree(self.root / "scratch")

        self.assertTrue(sentinel.is_file())

    def test_receipts_record_plan_and_apply_without_retained_data(self) -> None:
        report = self.retained / "hygiene" / "cleanup.md"
        machine = self.retained / "hygiene" / "cleanup.json"

        self.assertEqual(
            self.invoke(
                "--execute",
                "--phase",
                "postflight",
                "--report",
                str(report),
                "--json-output",
                str(machine),
            ),
            0,
        )

        self.assertIn("Phase: `postflight`", report.read_text(encoding="utf-8"))
        payload = json.loads(machine.read_text(encoding="utf-8"))
        self.assertEqual(payload["mode"], "apply")
        self.assertEqual(payload["status"], "success")
        self.assertEqual(payload["entries"][0]["disposition"], "removed")
        self.assertTrue((self.retained / "compose").is_file())

    def test_partial_cleanup_failure_retains_completed_dispositions(self) -> None:
        attempts = self.root / "attempts"
        attempts.mkdir()
        (attempts / "discard").write_text("discard", encoding="utf-8")
        report = self.retained / "hygiene" / "partial.md"
        machine = self.retained / "hygiene" / "partial.json"
        original_remove = MODULE.remove_tree

        def fail_after_first_removal(path: Path) -> None:
            if path.name == "scratch":
                raise OSError("fixture removal failure")
            original_remove(path)

        with mock.patch.object(
            MODULE, "remove_tree", side_effect=fail_after_first_removal
        ):
            result = self.invoke(
                "--execute",
                "--phase",
                "postflight",
                "--report",
                str(report),
                "--json-output",
                str(machine),
            )

        self.assertEqual(result, 2)
        self.assertFalse(attempts.exists())
        self.assertTrue((self.root / "scratch").exists())
        payload = json.loads(machine.read_text(encoding="utf-8"))
        self.assertEqual(payload["status"], "failed")
        self.assertEqual(payload["error"], "fixture removal failure")
        self.assertEqual(
            payload["entries"],
            [{"disposition": "removed", "path": str(attempts)}],
        )
        self.assertIn("Status: `failed`", report.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
