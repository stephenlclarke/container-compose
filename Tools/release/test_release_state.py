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
import base64
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
    @staticmethod
    def completed(value: object) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(
            args=[], returncode=0, stdout=json.dumps(value), stderr=""
        )

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
                len(state["retained"]["missing"]),
                len(MODULE.EXPECTED_RETAINED_ASSETS),
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

    def test_nonprerelease_draft_is_planned_as_resumable(self) -> None:
        completed = self.completed(
            {
                "assets": [],
                "draft": True,
                "id": 123,
                "prerelease": False,
            }
        )
        with mock.patch.object(MODULE.subprocess, "run", return_value=completed):
            remote = MODULE.remote_release("owner/repo", "1.2.3", False)

        assets = {
            asset: {"sha256": "a" * 64}
            for asset in MODULE.EXPECTED_RETAINED_ASSETS
        }
        remote = MODULE.reconcile_remote_digests(remote, {"assets": assets})
        self.assertEqual(remote["state"], "draft")
        action = MODULE.plan_recovery(
            [],
            [],
            [],
            remote,
            {"formulae": {"state": "deferred"}, "pages": {"state": "deferred"}},
        )
        self.assertEqual(action["name"], "resume-stable-draft")
        self.assertIn("publish", action["summary"])

    def test_stale_prerelease_draft_is_planned_as_resumable(self) -> None:
        completed = self.completed(
            {
                "assets": [],
                "draft": True,
                "id": 123,
                "prerelease": True,
            }
        )
        with mock.patch.object(MODULE.subprocess, "run", return_value=completed):
            remote = MODULE.remote_release("owner/repo", "1.2.3", False)

        assets = {
            asset: {"sha256": "a" * 64}
            for asset in MODULE.EXPECTED_RETAINED_ASSETS
        }
        remote = MODULE.reconcile_remote_digests(remote, {"assets": assets})
        action = MODULE.plan_recovery(
            [],
            [],
            [],
            remote,
            {"formulae": {"state": "deferred"}, "pages": {"state": "deferred"}},
        )

        self.assertEqual(remote["state"], "draft")
        self.assertEqual(action["name"], "resume-stable-draft")

    def test_draft_with_unexpected_asset_is_a_conflict(self) -> None:
        assets = {
            asset: {"sha256": "a" * 64}
            for asset in MODULE.EXPECTED_RETAINED_ASSETS
        }
        remote = {
            "asset_digests": {"foreign.tar.gz": "sha256:" + "a" * 64},
            "assets": ["foreign.tar.gz"],
            "missing_assets": list(MODULE.EXPECTED_RELEASE_ASSETS),
            "state": "draft",
        }

        observed = MODULE.reconcile_remote_digests(remote, {"assets": assets})

        self.assertEqual(observed["state"], "conflicting")
        self.assertEqual(observed["unexpected_assets"], ["foreign.tar.gz"])

    def test_draft_rejects_postpublication_init_asset_pair(self) -> None:
        names = [
            "container-vminit-arm64.oci.tar",
            "container-vminit-arm64.oci.tar.sha256",
        ]
        assets = {
            asset: {"sha256": "a" * 64}
            for asset in MODULE.EXPECTED_RETAINED_ASSETS
        }
        remote = {
            "asset_digests": {
                name: "sha256:" + str(assets[name]["sha256"]) for name in names
            },
            "assets": names,
            "missing_assets": list(MODULE.EXPECTED_DRAFT_ASSETS),
            "state": "draft",
        }

        observed = MODULE.reconcile_remote_digests(remote, {"assets": assets})

        self.assertEqual(observed["state"], "conflicting")
        self.assertEqual(observed["unexpected_assets"], sorted(names))

    def test_draft_with_mismatched_asset_digest_is_a_conflict(self) -> None:
        name = MODULE.EXPECTED_RELEASE_ASSETS[0]
        assets = {
            asset: {"sha256": "a" * 64}
            for asset in MODULE.EXPECTED_RETAINED_ASSETS
        }
        remote = {
            "asset_digests": {name: "sha256:" + "b" * 64},
            "assets": [name],
            "missing_assets": sorted(set(MODULE.EXPECTED_RELEASE_ASSETS) - {name}),
            "state": "draft",
        }

        observed = MODULE.reconcile_remote_digests(remote, {"assets": assets})

        self.assertEqual(observed["state"], "conflicting")
        self.assertIn(name, observed["digest_conflicts"])

    def test_complete_local_store_plans_missing_remote_assets_before_postconditions(
        self,
    ) -> None:
        with (
            tempfile.TemporaryDirectory() as directory,
            mock.patch.object(
                MODULE,
                "retained_assets",
                return_value=(list(MODULE.EXPECTED_RETAINED_ASSETS), []),
            ),
            mock.patch.object(MODULE, "dispatch_records", return_value=[]),
            mock.patch.object(
                MODULE,
                "remote_release",
                return_value={
                    "assets": [],
                    "asset_digests": {},
                    "missing_assets": list(MODULE.EXPECTED_RELEASE_ASSETS),
                    "state": "published",
                },
            ),
        ):
            state = MODULE.inspect(
                Path(directory) / "retained", "1.2.3", "owner/repo", False
            )

        self.assertIn("incomplete remote release", state["next_action"])
        self.assertEqual(state["actions"][0]["name"], "upload-missing-assets")
        self.assertIn("side_effects", state["actions"][0])

    def test_latest_postconditions_are_bound_to_formulae_and_docs_run(self) -> None:
        compose_url = (
            "https://github.com/owner/repo/releases/download/1.2.3/"
            "container-compose-plugin-release-arm64.tar.gz"
        )
        runtime_url = (
            "https://github.com/owner/repo/releases/download/1.2.3/"
            "container-release-arm64.tar.gz"
        )
        formulae = {
            "compose_url": compose_url,
            "runtime_url": runtime_url,
            "compose_sha256": "a" * 64,
            "runtime_sha256": "b" * 64,
        }
        compose = (
            f'  url "{compose_url}"\n  sha256 "{"a" * 64}"\n'
            '  depends_on "stephenlclarke/tap/container"\n'
        )
        runtime = (
            f'  url "{runtime_url}"\n  sha256 "{"b" * 64}"\n'
            "  plugin = opt/container-compose/libexec/container-plugins/compose\n"
        )
        def metadata(body: str, sha: str) -> dict[str, str]:
            return {
                "content": base64.encodebytes(body.encode()).decode(),
                "encoding": "base64",
                "sha": sha,
            }
        control_sha = "c" * 40
        responses = [
            self.completed({"tag_name": "1.2.3"}),
            self.completed(metadata(runtime, "runtime-blob")),
            self.completed(metadata(compose, "compose-blob")),
            self.completed(
                {
                    "build_type": "workflow",
                    "html_url": "https://docs.test",
                    "status": "built",
                }
            ),
            self.completed(
                {
                    "workflow_runs": [
                        {
                            "conclusion": "success",
                            "display_title": "Documentation · 1.2.3 · request",
                            "head_sha": control_sha,
                            "id": 123,
                            "status": "completed",
                        }
                    ]
                }
            ),
            self.completed([{"id": 456, "sha": control_sha}]),
            self.completed([{"state": "success"}]),
        ]
        with mock.patch.object(MODULE.subprocess, "run", side_effect=responses):
            observed = MODULE.remote_postconditions(
                "owner/repo", "1.2.3", False, formulae
            )

        self.assertEqual(observed["formulae"]["state"], "verified")
        self.assertEqual(observed["pages"]["state"], "verified")
        self.assertEqual(observed["pages"]["control_sha"], control_sha)
        self.assertNotIn(
            "body", observed["formulae"]["members"]["container-compose.rb"]
        )

    def test_superseded_release_does_not_compare_current_postconditions(
        self,
    ) -> None:
        with mock.patch.object(
            MODULE.subprocess,
            "run",
            return_value=self.completed({"tag_name": "2.0.0"}),
        ) as run:
            observed = MODULE.remote_postconditions(
                "owner/repo", "1.2.3", False, None
            )

        self.assertEqual(observed["formulae"]["state"], "superseded")
        self.assertEqual(observed["pages"]["latest_version"], "2.0.0")
        run.assert_called_once()

    def test_formula_conflict_fails_candidate_bound_postcondition(self) -> None:
        wrong = '  url "https://wrong.test/archive"\n  sha256 "' + "a" * 64 + '"\n'
        runtime = (
            '  url "https://example.test/runtime"\n  sha256 "'
            + "b" * 64
            + '"\n  plugin = opt/container-compose/libexec/container-plugins/compose\n'
        )
        responses = [
            self.completed({"tag_name": "1.2.3"}),
            self.completed(
                {
                    "content": base64.b64encode(runtime.encode()).decode(),
                    "encoding": "base64",
                    "sha": "runtime-blob",
                }
            ),
            self.completed(
                {
                    "content": base64.b64encode(wrong.encode()).decode(),
                    "encoding": "base64",
                    "sha": "compose-blob",
                }
            ),
            self.completed({"status": "built"}),
            self.completed({"workflow_runs": []}),
            self.completed([]),
        ]
        expected = {
            "compose_url": "https://example.test/compose",
            "runtime_url": "https://example.test/runtime",
            "compose_sha256": "a" * 64,
            "runtime_sha256": "b" * 64,
        }
        with mock.patch.object(MODULE.subprocess, "run", side_effect=responses):
            observed = MODULE.remote_postconditions(
                "owner/repo", "1.2.3", False, expected
            )

        self.assertEqual(observed["formulae"]["state"], "conflict")
        self.assertIn("URL", observed["formulae"]["reason"])

    def test_remote_digest_conflict_is_not_reported_as_published(self) -> None:
        name = MODULE.EXPECTED_RELEASE_ASSETS[0]
        assets = {
            asset: {"sha256": "a" * 64}
            for asset in MODULE.EXPECTED_RETAINED_ASSETS
        }
        remote = {
            "asset_digests": {name: "sha256:" + "b" * 64},
            "state": "published",
        }

        observed = MODULE.reconcile_remote_digests(
            {**remote, "assets": [name]}, {"assets": assets}
        )

        self.assertEqual(observed["state"], "conflicting")
        self.assertIn(name, observed["digest_conflicts"])
        self.assertEqual(remote["state"], "published")

    def test_missing_remote_digests_fail_closed_for_complete_inventory(self) -> None:
        assets = {
            asset: {"sha256": "a" * 64}
            for asset in MODULE.EXPECTED_RETAINED_ASSETS
        }

        observed = MODULE.reconcile_remote_digests(
            {
                "asset_digests": {},
                "assets": list(MODULE.EXPECTED_RELEASE_ASSETS),
                "missing_assets": [],
                "state": "published",
            },
            {"assets": assets},
        )

        self.assertEqual(observed["state"], "unavailable")
        self.assertEqual(
            observed["unverified_digests"], list(MODULE.EXPECTED_RELEASE_ASSETS)
        )

    def test_remote_release_inventory_excludes_locally_retained_docs(self) -> None:
        assets = [
            {"digest": f"sha256:{'a' * 64}", "name": name}
            for name in MODULE.EXPECTED_RELEASE_ASSETS
        ]
        completed = self.completed(
            {
                "assets": assets,
                "draft": False,
                "id": 123,
                "prerelease": False,
            }
        )

        with mock.patch.object(MODULE.subprocess, "run", return_value=completed):
            remote = MODULE.remote_release("owner/repo", "1.2.3", False)

        self.assertEqual(remote["state"], "published")
        self.assertEqual(remote["missing_assets"], [])
        self.assertTrue(
            set(MODULE.EXPECTED_DOCUMENTATION_ASSETS).isdisjoint(remote["assets"])
        )
        action = MODULE.plan_recovery(
            [],
            [],
            [],
            remote,
            {"formulae": {"state": "verified"}, "pages": {"state": "verified"}},
        )
        self.assertEqual(action["name"], "complete")

    def test_missing_retained_docs_route_to_documentation_recovery(self) -> None:
        action = MODULE.plan_recovery(
            [],
            [],
            ["k8s.tgz"],
            {"missing_assets": [], "state": "published"},
            {"formulae": {"state": "verified"}, "pages": {"state": "verified"}},
        )

        self.assertEqual(action["name"], "restore-documentation-artifacts")
        self.assertNotIn("published release assets", action["summary"])
        unpublished = MODULE.plan_recovery(
            [],
            [],
            ["k8s.tgz"],
            {"state": "absent"},
            {"formulae": {"state": "deferred"}, "pages": {"state": "deferred"}},
        )
        self.assertEqual(unpublished["name"], "publish-retained-release")

    def test_successful_linked_retry_supersedes_its_failed_lineage(self) -> None:
        first = {
            "request_id": "11111111-1111-1111-1111-111111111111",
            "state": "failed",
        }
        second = {
            "previous_request_id": first["request_id"],
            "request_id": "22222222-2222-2222-2222-222222222222",
            "state": "failed",
        }
        successful = {
            "observed": {"conclusion": "success", "state": "completed"},
            "previous_request_id": second["request_id"],
            "request_id": "33333333-3333-3333-3333-333333333333",
            "state": "dispatched",
        }

        unresolved = MODULE.unresolved_failed_dispatches([first, second, successful])
        self.assertEqual(unresolved, [])
        action = MODULE.plan_recovery(
            [],
            unresolved,
            [],
            {"missing_assets": [], "state": "published"},
            {"formulae": {"state": "verified"}, "pages": {"state": "verified"}},
        )
        self.assertEqual(action["name"], "complete")

    def test_pure_plan_declares_authority_and_invalidated_descendants(self) -> None:
        action = MODULE.plan_recovery(
            [],
            [],
            [],
            {
                "missing_assets": ["asset"],
                "state": "published",
            },
            {
                "formulae": {"state": "deferred"},
                "pages": {"state": "deferred"},
            },
        )

        self.assertEqual(action["name"], "upload-missing-assets")
        self.assertEqual(action["invalidated_descendants"], ["formulae", "pages"])
        self.assertEqual(action["required_authority"], "retained publication authority")


if __name__ == "__main__":
    unittest.main()
