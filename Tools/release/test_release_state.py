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
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("release-state.py")
SPEC = importlib.util.spec_from_file_location("release_state", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ReleaseStateTests(unittest.TestCase):
    def test_unknown_dispatch_is_actionable_and_never_reported_absent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "retained"
            request_id = "12345678-1234-1234-1234-123456789abc"
            journal = root / f"release/dispatches/{request_id}.json"
            journal.parent.mkdir(parents=True)
            journal.write_text(
                json.dumps(
                    {
                        "control_sha": "a" * 40,
                        "created_at": "2026-09-10T00:00:00+00:00",
                        "request_id": request_id,
                        "schema": 1,
                        "state": "dispatch-unknown",
                        "version": "1.2.3",
                        "workflow": "docs.yml",
                    }
                ),
                encoding="utf-8",
            )
            state = MODULE.inspect(
                root, "1.2.3", "stephenlclarke/container-compose", True
            )

            self.assertEqual(state["remote_release"]["state"], "not-inspected")
            self.assertIn("do not redispatch", state["next_action"])
            rendered = MODULE.render_text(state, True)
            self.assertIn("Mutation: none", rendered)
            self.assertIn("dispatch-unknown", rendered)

    def test_tampered_dispatch_record_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "retained"
            journal = (
                root
                / "release/dispatches/12345678-1234-1234-1234-123456789abc.json"
            )
            journal.parent.mkdir(parents=True)
            journal.write_text(
                json.dumps(
                    {
                        "control_sha": "a" * 40,
                        "request_id": "different",
                        "schema": 1,
                        "state": "dispatch-unknown",
                        "version": "1.2.3",
                        "workflow": "docs.yml",
                    }
                ),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(MODULE.StateError, "unsupported"):
                MODULE.inspect(
                    root, "1.2.3", "stephenlclarke/container-compose", True
                )

    def test_offline_missing_artifacts_never_claim_success(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "retained"
            state = MODULE.inspect(
                root, "1.2.3", "stephenlclarke/container-compose", True
            )

            self.assertEqual(state["retained"]["verified"], [])
            self.assertEqual(
                len(state["retained"]["missing"]), len(MODULE.EXPECTED_ASSETS)
            )
            self.assertIn("blocked", state["next_action"])

    def test_acknowledged_run_observation_is_read_only(self) -> None:
        record = {"run_id": "987", "state": "dispatched"}
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps(
                {
                    "conclusion": "success",
                    "status": "completed",
                    "url": "https://example.invalid/run/987",
                }
            ),
            stderr="",
        )
        with mock.patch.object(MODULE.subprocess, "run", return_value=completed):
            observed = MODULE.observe_dispatches([record], "owner/repo", False)

        self.assertEqual(observed[0]["observed"]["state"], "completed")
        self.assertNotIn("observed", record)

    def test_malformed_remote_assets_are_reported_unavailable(self) -> None:
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps(
                {"assets": None, "draft": False, "prerelease": False}
            ),
            stderr="",
        )
        with mock.patch.object(MODULE.subprocess, "run", return_value=completed):
            remote = MODULE.remote_release("owner/repo", "1.2.3", False)

        self.assertEqual(remote["state"], "unavailable")
        self.assertIn("malformed", remote["reason"])

    def test_complete_local_store_plans_missing_remote_assets_before_postconditions(
        self,
    ) -> None:
        with (
            tempfile.TemporaryDirectory() as directory,
            mock.patch.object(
                MODULE,
                "retained_assets",
                return_value=(list(MODULE.EXPECTED_ASSETS), []),
            ),
            mock.patch.object(MODULE, "dispatch_records", return_value=[]),
            mock.patch.object(
                MODULE,
                "remote_release",
                return_value={
                    "assets": [],
                    "missing_assets": list(MODULE.EXPECTED_ASSETS),
                    "state": "published",
                },
            ),
        ):
            state = MODULE.inspect(
                Path(directory) / "retained", "1.2.3", "owner/repo", False
            )

        self.assertIn("incomplete remote release", state["next_action"])


if __name__ == "__main__":
    unittest.main()
