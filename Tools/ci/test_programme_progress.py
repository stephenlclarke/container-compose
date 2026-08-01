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

"""Tests for the generated Container-family programme progress register."""

from __future__ import annotations

import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from contextlib import redirect_stderr
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("programme-progress.py")
SPEC = importlib.util.spec_from_file_location("programme_progress", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
progress = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = progress
SPEC.loader.exec_module(progress)


class ProgrammeProgressTests(unittest.TestCase):
    def create_repository(
        self,
    ) -> tuple[tempfile.TemporaryDirectory[str], Path, str, dict[str, object]]:
        previous_base = progress.EXPECTED_PROGRAMME_BASE
        previous_contracts = progress.EXPECTED_DESIGN_CONTRACTS
        progress.EXPECTED_DESIGN_CONTRACTS = {
            "DEMO": (
                "focused",
                "docs/demo-design.md",
                "DEMO-WP-",
                ("DEMO-WP-01",),
                ("stephenlclarke/container-compose",),
                (),
                ("docs/demo-design.md",),
            )
        }
        self.addCleanup(
            setattr,
            progress,
            "EXPECTED_DESIGN_CONTRACTS",
            previous_contracts,
        )
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        subprocess.run(["git", "init", "-q", "-b", "main"], cwd=root, check=True)
        subprocess.run(
            ["git", "config", "user.name", "Test"], cwd=root, check=True
        )
        subprocess.run(
            ["git", "config", "user.email", "test@example.com"],
            cwd=root,
            check=True,
        )
        subprocess.run(
            [
                "git",
                "remote",
                "add",
                "origin",
                "https://github.com/stephenlclarke/container-compose.git",
            ],
            cwd=root,
            check=True,
        )
        design = root / "docs/demo-design.md"
        design.parent.mkdir(parents=True)
        design.write_text(
            "# Demo Design\n\n"
            '<a id="demo-wp-01"></a>`DEMO-WP-01`\n\n'
            "The acceptance contract.\n",
            encoding="utf-8",
        )
        evidence = root / "docs/evidence.md"
        evidence.write_text("# Exact evidence\n", encoding="utf-8")
        subprocess.run(["git", "add", "."], cwd=root, check=True)
        subprocess.run(
            ["git", "commit", "-qm", "accepted evidence"],
            cwd=root,
            check=True,
        )
        accepted = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        subprocess.run(
            ["git", "update-ref", "refs/remotes/origin/main", accepted],
            cwd=root,
            check=True,
        )
        progress.EXPECTED_PROGRAMME_BASE = accepted
        self.addCleanup(
            setattr,
            progress,
            "EXPECTED_PROGRAMME_BASE",
            previous_base,
        )
        payload: dict[str, object] = {
            "schemaVersion": 1,
            "programmeBase": accepted,
            "generatedAt": "2026-08-01",
            "designs": [
                {
                    "id": "DEMO",
                    "title": "Demo design",
                    "kind": "focused",
                    "path": "docs/demo-design.md",
                    "itemPrefix": "DEMO-WP-",
                    "documentationDependencies": ["docs/demo-design.md"],
                    "requiredRepositories": [
                        "stephenlclarke/container-compose"
                    ],
                    "repositoryRequirementOverrides": {},
                    "items": {
                        "not started": [],
                        "in progress": [],
                        "blocked": [],
                        "verified": ["DEMO-WP-01"],
                    },
                }
            ],
            "blockers": {},
            "evidence": {
                "DEMO-WP-01": {
                    "exactAcceptedHead": accepted,
                    "repositoryHeads": {
                        "stephenlclarke/container-compose": accepted
                    },
                    "evidencePaths": ["docs/evidence.md"],
                    "documentation": [
                        {
                            "path": "docs/demo-design.md",
                            "disposition": "updated",
                            "reviewedAtHead": accepted,
                            "rationale": "Defines the accepted demo contract.",
                        }
                    ],
                    "authorities": [
                        {
                            "kind": "delivery",
                            "url": (
                                "https://github.com/stephenlclarke/"
                                f"container-compose/commit/{accepted}"
                            ),
                        }
                    ],
                }
            },
        }
        return temporary, root, accepted, payload

    def create_external_repository(
        self, repository: str = "stephenlclarke/container"
    ) -> tuple[tempfile.TemporaryDirectory[str], Path, str]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        subprocess.run(["git", "init", "-q", "-b", "main"], cwd=root, check=True)
        subprocess.run(
            ["git", "config", "user.name", "Test"], cwd=root, check=True
        )
        subprocess.run(
            ["git", "config", "user.email", "test@example.com"],
            cwd=root,
            check=True,
        )
        subprocess.run(
            [
                "git",
                "remote",
                "add",
                "origin",
                f"https://github.com/{repository}.git",
            ],
            cwd=root,
            check=True,
        )
        (root / "README.md").write_text("# External repository\n", encoding="utf-8")
        subprocess.run(["git", "add", "README.md"], cwd=root, check=True)
        subprocess.run(
            ["git", "commit", "-qm", "accepted external head"],
            cwd=root,
            check=True,
        )
        head = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        subprocess.run(
            ["git", "update-ref", "refs/remotes/origin/main", head],
            cwd=root,
            check=True,
        )
        return temporary, root, head

    def require_repositories(
        self, payload: dict[str, object], *repositories: str
    ) -> None:
        required = tuple(
            sorted({"stephenlclarke/container-compose", *repositories})
        )
        design = payload["designs"][0]
        design["requiredRepositories"] = list(required)
        contract = progress.EXPECTED_DESIGN_CONTRACTS["DEMO"]
        progress.EXPECTED_DESIGN_CONTRACTS = {
            "DEMO": (*contract[:4], required, *contract[5:])
        }

    def test_valid_exact_head_register_renders_immutable_links(self) -> None:
        temporary, root, accepted, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)

        self.assertEqual(progress.validate_progress(payload, root), [])
        rendered = progress.render_progress(payload)

        self.assertIn("| verified | 1 |", rendered)
        self.assertIn("[`DEMO-WP-01`](../demo-design.md#demo-wp-01)", rendered)
        self.assertIn(f"/blob/{accepted}/docs/evidence.md", rendered)
        self.assertIn("Defines the accepted demo contract.", rendered)
        self.assertIn("#evidence-demo-wp-01", rendered)

    def test_uppercase_item_prefix_can_end_in_an_id_segment(self) -> None:
        temporary, root, _, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)
        design = payload["designs"][0]
        design["itemPrefix"] = "DEMO-WP"
        progress.EXPECTED_DESIGN_CONTRACTS = {
            "DEMO": (
                "focused",
                "docs/demo-design.md",
                "DEMO-WP",
                ("DEMO-WP-01",),
                ("stephenlclarke/container-compose",),
                (),
                ("docs/demo-design.md",),
            )
        }

        self.assertEqual(progress.validate_progress(payload, root), [])

    def test_required_item_cannot_disappear_from_design_and_register(self) -> None:
        temporary, root, _, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)
        design = payload["designs"][0]
        design["items"]["verified"] = []
        payload["evidence"] = {}
        (root / "docs/demo-design.md").write_text(
            "# Demo Design\n\nThe acceptance contract.\n",
            encoding="utf-8",
        )

        errors = progress.validate_progress(payload, root)

        self.assertIn("required programme item is missing: DEMO-WP-01", errors)

    def test_verified_item_requires_exact_head_evidence(self) -> None:
        temporary, root, _, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)
        payload["evidence"] = {}

        errors = progress.validate_progress(payload, root)

        self.assertIn(
            "verified item lacks exact-head evidence: DEMO-WP-01", errors
        )

    def test_evidence_is_rejected_for_non_verified_item(self) -> None:
        temporary, root, _, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)
        design = payload["designs"][0]
        design["items"]["verified"] = []
        design["items"]["in progress"] = ["DEMO-WP-01"]

        errors = progress.validate_progress(payload, root)

        self.assertTrue(
            any(
                "evidence is only valid for verified items: DEMO-WP-01"
                in error
                for error in errors
            )
        )

    def test_registered_item_requires_design_anchor_and_visible_id(self) -> None:
        temporary, root, _, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)
        design_path = root / "docs/demo-design.md"
        design_path.write_text("# Demo Design\n", encoding="utf-8")

        errors = progress.validate_progress(payload, root)

        self.assertIn(
            "registered design anchor is missing: docs/demo-design.md#demo-wp-01",
            errors,
        )

        design_path.write_text(
            '# Demo Design\n\n<a id="demo-wp-01"></a>\n',
            encoding="utf-8",
        )
        errors = progress.validate_progress(payload, root)
        self.assertIn(
            "design anchor docs/demo-design.md#demo-wp-01 does not display "
            "`DEMO-WP-01`",
            errors,
        )

    def test_unregistered_design_anchor_fails(self) -> None:
        temporary, root, _, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)
        design_path = root / "docs/demo-design.md"
        with design_path.open("a", encoding="utf-8") as stream:
            stream.write('\n<a id="demo-wp-02"></a>`DEMO-WP-02`\n')

        errors = progress.validate_progress(payload, root)

        self.assertIn(
            "design anchor is absent from the register: "
            "docs/demo-design.md#demo-wp-02",
            errors,
        )

    def test_active_design_authority_cannot_be_omitted(self) -> None:
        temporary, root, _, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)
        (root / "docs/extra-design.md").write_text(
            "# Extra active design\n", encoding="utf-8"
        )

        errors = progress.validate_progress(payload, root)

        self.assertIn(
            "active programme authority is absent from designs: "
            "docs/extra-design.md",
            errors,
        )

    def test_evidence_and_document_paths_must_exist_at_accepted_head(self) -> None:
        temporary, root, _, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)
        evidence = payload["evidence"]["DEMO-WP-01"]
        evidence["evidencePaths"] = ["docs/later.md"]
        evidence["documentation"][0]["path"] = "docs/later-design.md"

        errors = progress.validate_progress(payload, root)

        self.assertTrue(any("docs/later.md" in error for error in errors))
        self.assertTrue(any("docs/later-design.md" in error for error in errors))

    def test_document_review_must_name_the_same_exact_head(self) -> None:
        temporary, root, _, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)
        evidence = payload["evidence"]["DEMO-WP-01"]
        evidence["documentation"][0]["reviewedAtHead"] = "0" * 40

        errors = progress.validate_progress(payload, root)

        self.assertTrue(
            any(
                "reviewedAtHead must equal exactAcceptedHead" in error
                for error in errors
            )
        )

    def test_verified_item_must_review_every_declared_document_dependency(self) -> None:
        temporary, root, _, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)
        design = payload["designs"][0]
        design["documentationDependencies"] = [
            "docs/demo-design.md",
            "docs/evidence.md",
        ]

        errors = progress.validate_progress(payload, root)

        self.assertIn(
            "evidence.DEMO-WP-01 lacks review disposition for dependent "
            "documentation: docs/evidence.md",
            errors,
        )

    def test_reviewed_documentation_dependencies_cannot_shrink(self) -> None:
        temporary, root, _, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)
        contract = progress.EXPECTED_DESIGN_CONTRACTS["DEMO"]
        progress.EXPECTED_DESIGN_CONTRACTS = {
            "DEMO": (
                *contract[:6],
                ("docs/demo-design.md", "docs/evidence.md"),
            )
        }

        errors = progress.validate_progress(payload, root)

        self.assertTrue(
            any("reviewed documentation dependencies" in error for error in errors)
        )

    def test_document_review_requires_a_rationale(self) -> None:
        temporary, root, _, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)
        evidence = payload["evidence"]["DEMO-WP-01"]
        evidence["documentation"][0]["rationale"] = " "

        errors = progress.validate_progress(payload, root)

        self.assertTrue(
            any(
                "rationale must be a non-empty single line" in error
                for error in errors
            )
        )

    def test_blocked_item_requires_actionable_metadata(self) -> None:
        temporary, root, _, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)
        design = payload["designs"][0]
        design["items"]["verified"] = []
        design["items"]["blocked"] = ["DEMO-WP-01"]
        payload["evidence"] = {}

        errors = progress.validate_progress(payload, root)

        self.assertIn(
            "blocked item lacks owner/blocker/next action: DEMO-WP-01", errors
        )

        payload["blockers"] = {
            "DEMO-WP-01": {
                "owner": "runtime owner",
                "blocker": "missing authority",
                "nextAction": "obtain evidence",
                "nextReviewDate": "2026-08-15",
            }
        }
        self.assertEqual(progress.validate_progress(payload, root), [])
        rendered = progress.render_progress(payload)
        self.assertIn(
            "runtime owner: missing authority; next: obtain evidence; review "
            "2026-08-15",
            rendered,
        )

    def test_invalid_values_report_errors_instead_of_crashing(self) -> None:
        temporary, root, _, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)
        design = payload["designs"][0]
        design["items"]["verified"] = [7]
        evidence = payload["evidence"]["DEMO-WP-01"]
        evidence["evidencePaths"] = [5]

        errors = progress.validate_progress(payload, root)

        self.assertTrue(any("invalid stable ID" in error for error in errors))
        self.assertTrue(any("evidence is only valid" in error for error in errors))

    def test_unhashable_enum_values_report_errors_instead_of_crashing(self) -> None:
        temporary, root, _, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)
        design = payload["designs"][0]
        design["kind"] = []
        evidence = payload["evidence"]["DEMO-WP-01"]
        evidence["documentation"][0]["disposition"] = []
        evidence["authorities"][0]["kind"] = []

        errors = progress.validate_progress(payload, root)

        self.assertTrue(any("kind must be one of" in error for error in errors))
        self.assertTrue(
            any("disposition must be one of" in error for error in errors)
        )

    def test_dates_must_be_real_calendar_dates(self) -> None:
        temporary, root, _, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)
        payload["generatedAt"] = "2026-02-30"
        design = payload["designs"][0]
        design["items"]["verified"] = []
        design["items"]["blocked"] = ["DEMO-WP-01"]
        payload["evidence"] = {}
        payload["blockers"] = {
            "DEMO-WP-01": {
                "owner": "runtime owner",
                "blocker": "missing authority",
                "nextAction": "obtain evidence",
                "nextReviewDate": "2026-13-01",
            }
        }

        errors = progress.validate_progress(payload, root)

        self.assertIn("generatedAt must use YYYY-MM-DD", errors)
        self.assertTrue(any("nextReviewDate" in error for error in errors))

    def test_duplicate_evidence_paths_fail(self) -> None:
        temporary, root, _, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)
        evidence = payload["evidence"]["DEMO-WP-01"]
        evidence["evidencePaths"] = ["docs/evidence.md", "docs/evidence.md"]

        errors = progress.validate_progress(payload, root)

        self.assertTrue(any("must not contain duplicates" in error for error in errors))

    def test_authority_requires_a_trusted_kind_specific_github_resource(self) -> None:
        temporary, root, _, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)
        authority = payload["evidence"]["DEMO-WP-01"]["authorities"][0]
        authority["url"] = "https://example.com/nonexistent"

        errors = progress.validate_progress(payload, root)

        self.assertTrue(
            any("trusted GitHub HTTPS service" in error for error in errors)
        )

        authority["url"] = (
            "https://github.com/stephenlclarke/container-compose/actions/runs/7"
        )
        errors = progress.validate_progress(payload, root)
        self.assertTrue(
            any(
                "is not valid for delivery authority evidence" in error
                for error in errors
            )
        )

    def test_github_authority_reader_uses_a_bounded_clean_environment(self) -> None:
        completed = subprocess.CompletedProcess(
            args=[], returncode=0, stdout="{}", stderr=""
        )
        with (
            mock.patch.object(
                progress, "GITHUB_CLI_PATHS", (Path("/usr/bin/true"),)
            ),
            mock.patch.object(
                progress.subprocess, "run", return_value=completed
            ) as run,
            mock.patch.dict(
                os.environ,
                {
                    "DYLD_INSERT_LIBRARIES": "/tmp/untrusted.dylib",
                    "GH_TOKEN": "test-token",
                    "GH_DEBUG": "api",
                },
                clear=True,
            ),
        ):
            self.assertEqual(progress.github_api_json("repos/example/demo"), {})

        invocation = run.call_args
        environment = invocation.kwargs["env"]
        self.assertEqual(environment["GH_TOKEN"], "test-token")
        self.assertNotIn("DYLD_INSERT_LIBRARIES", environment)
        self.assertNotIn("GH_DEBUG", environment)
        self.assertEqual(invocation.kwargs["timeout"], 30)

    def test_pull_authority_must_exist_and_bind_the_exact_merged_head(self) -> None:
        temporary, root, accepted, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)
        authority = payload["evidence"]["DEMO-WP-01"]["authorities"][0]
        authority["kind"] = "review"
        authority["url"] = (
            "https://github.com/stephenlclarke/container-compose/"
            "pull/7#issuecomment-11"
        )
        responses: dict[str, object] = {
            "repos/stephenlclarke/container-compose/pulls/7": {
                "html_url": (
                    "https://github.com/stephenlclarke/"
                    "container-compose/pull/7"
                ),
                "merged": True,
                "merge_commit_sha": accepted,
            },
            "repos/stephenlclarke/container-compose/issues/comments/11": {
                "html_url": authority["url"],
                "issue_url": (
                    "https://api.github.com/repos/stephenlclarke/"
                    "container-compose/issues/7"
                ),
            },
        }

        self.assertEqual(
            progress.validate_progress(
                payload, root, authority_reader=responses.get
            ),
            [],
        )

        responses.pop(
            "repos/stephenlclarke/container-compose/issues/comments/11"
        )
        errors = progress.validate_progress(
            payload, root, authority_reader=responses.get
        )
        self.assertTrue(
            any("could not verify GitHub resource" in error for error in errors)
        )

    def test_quality_authority_must_be_a_successful_exact_head_run(self) -> None:
        temporary, root, accepted, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)
        authority = payload["evidence"]["DEMO-WP-01"]["authorities"][0]
        authority["kind"] = "quality"
        authority["url"] = (
            "https://github.com/stephenlclarke/container-compose/actions/runs/9"
        )
        run = {
            "html_url": authority["url"],
            "status": "completed",
            "conclusion": "success",
            "head_sha": accepted,
            "repository": {"full_name": "stephenlclarke/container-compose"},
        }

        self.assertEqual(
            progress.validate_progress(
                payload, root, authority_reader=lambda _: run
            ),
            [],
        )

        run["head_sha"] = "0" * 40
        errors = progress.validate_progress(
            payload, root, authority_reader=lambda _: run
        )
        self.assertTrue(
            any(
                "successful GitHub Actions run for exact head" in error
                for error in errors
            )
        )

    def test_recorded_heads_must_name_commit_objects_directly(self) -> None:
        temporary, root, _, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)
        subprocess.run(
            [
                "git",
                "-c",
                "tag.gpgSign=false",
                "tag",
                "-a",
                "accepted-evidence",
                "-m",
                "annotated evidence tag",
            ],
            cwd=root,
            check=True,
        )
        tag_object = subprocess.run(
            ["git", "rev-parse", "refs/tags/accepted-evidence"],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        evidence = payload["evidence"]["DEMO-WP-01"]
        evidence["exactAcceptedHead"] = tag_object
        evidence["repositoryHeads"]["stephenlclarke/container-compose"] = tag_object
        evidence["documentation"][0]["reviewedAtHead"] = tag_object
        evidence["authorities"][0]["url"] = (
            "https://github.com/stephenlclarke/container-compose/"
            f"commit/{tag_object}"
        )

        errors = progress.validate_progress(payload, root)

        self.assertTrue(
            any(
                "exactAcceptedHead does not identify a commit object directly"
                in error
                for error in errors
            )
        )
        self.assertTrue(
            any(
                "repositoryHeads.stephenlclarke/container-compose does not "
                "identify a commit object directly" in error
                for error in errors
            )
        )

    def test_unavailable_accepted_head_fails(self) -> None:
        temporary, root, _, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)
        evidence = payload["evidence"]["DEMO-WP-01"]
        evidence["exactAcceptedHead"] = "0" * 40
        evidence["repositoryHeads"]["stephenlclarke/container-compose"] = "0" * 40
        evidence["documentation"][0]["reviewedAtHead"] = "0" * 40

        errors = progress.validate_progress(payload, root)

        self.assertTrue(any("is not available locally" in error for error in errors))

    def test_current_pull_request_head_is_not_an_accepted_checkpoint(self) -> None:
        temporary, root, accepted, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)
        (root / "docs/evidence.md").write_text(
            "# Candidate evidence\n", encoding="utf-8"
        )
        subprocess.run(["git", "add", "docs/evidence.md"], cwd=root, check=True)
        subprocess.run(
            ["git", "commit", "-qm", "candidate implementation"],
            cwd=root,
            check=True,
        )
        candidate = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        evidence = payload["evidence"]["DEMO-WP-01"]
        evidence["exactAcceptedHead"] = candidate
        evidence["repositoryHeads"]["stephenlclarke/container-compose"] = candidate
        evidence["documentation"][0]["reviewedAtHead"] = candidate

        errors = progress.validate_progress(
            payload, root, accepted_through=accepted
        )

        self.assertTrue(
            any("is newer than trusted accepted checkpoint" in error for error in errors)
        )

    def test_verified_item_requires_every_declared_repository_head(self) -> None:
        temporary, root, _, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)
        self.require_repositories(payload, "stephenlclarke/container")

        errors = progress.validate_progress(payload, root)

        self.assertIn(
            "evidence.DEMO-WP-01.repositoryHeads lacks required repository: "
            "stephenlclarke/container",
            errors,
        )

    def test_repository_head_requires_a_declared_item_dependency(self) -> None:
        temporary, root, accepted, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)
        evidence = payload["evidence"]["DEMO-WP-01"]
        evidence["repositoryHeads"]["stephenlclarke/container"] = accepted

        errors = progress.validate_progress(payload, root)

        self.assertIn(
            "evidence.DEMO-WP-01.repositoryHeads names an undeclared repository: "
            "stephenlclarke/container",
            errors,
        )

    def test_reviewed_repository_requirement_cannot_shrink(self) -> None:
        temporary, root, _, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)
        contract = progress.EXPECTED_DESIGN_CONTRACTS["DEMO"]
        progress.EXPECTED_DESIGN_CONTRACTS = {
            "DEMO": (
                *contract[:4],
                (
                    "stephenlclarke/container",
                    "stephenlclarke/container-compose",
                ),
                contract[5],
                contract[6],
            )
        }

        errors = progress.validate_progress(payload, root)

        self.assertTrue(
            any("reviewed required repository set" in error for error in errors)
        )

    def test_item_repository_override_replaces_the_design_default(self) -> None:
        temporary, root, _, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)
        design = payload["designs"][0]
        design["requiredRepositories"] = [
            "stephenlclarke/container",
            "stephenlclarke/container-compose",
        ]
        design["repositoryRequirementOverrides"] = {
            "DEMO-WP-01": ["stephenlclarke/container-compose"]
        }
        contract = progress.EXPECTED_DESIGN_CONTRACTS["DEMO"]
        progress.EXPECTED_DESIGN_CONTRACTS = {
            "DEMO": (
                *contract[:4],
                (
                    "stephenlclarke/container",
                    "stephenlclarke/container-compose",
                ),
                (
                    (
                        "DEMO-WP-01",
                        ("stephenlclarke/container-compose",),
                    ),
                ),
                contract[6],
            )
        }

        self.assertEqual(progress.validate_progress(payload, root), [])

    def test_external_repository_head_must_exist_in_its_trusted_checkout(self) -> None:
        temporary, root, accepted, payload = self.create_repository()
        external_temporary, external_root, external_head = (
            self.create_external_repository()
        )
        self.addCleanup(temporary.cleanup)
        self.addCleanup(external_temporary.cleanup)
        self.require_repositories(payload, "stephenlclarke/container")
        evidence = payload["evidence"]["DEMO-WP-01"]
        evidence["repositoryHeads"]["stephenlclarke/container"] = external_head
        repositories = {
            "stephenlclarke/container-compose": root,
            "stephenlclarke/container": external_root,
        }

        self.assertEqual(
            progress.validate_progress(
                payload,
                root,
                accepted_through=accepted,
                repository_roots=repositories,
            ),
            [],
        )

        evidence["repositoryHeads"]["stephenlclarke/container"] = "0" * 40
        errors = progress.validate_progress(
            payload,
            root,
            accepted_through=accepted,
            repository_roots=repositories,
        )
        self.assertTrue(
            any("is not available in the trusted checkout" in error for error in errors)
        )

        (external_root / "README.md").write_text(
            "# Unmerged external candidate\n", encoding="utf-8"
        )
        subprocess.run(["git", "add", "README.md"], cwd=external_root, check=True)
        subprocess.run(
            ["git", "commit", "-qm", "unmerged external candidate"],
            cwd=external_root,
            check=True,
        )
        candidate = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=external_root,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        evidence["repositoryHeads"]["stephenlclarke/container"] = candidate
        errors = progress.validate_progress(
            payload,
            root,
            accepted_through=accepted,
            repository_roots=repositories,
        )
        self.assertTrue(
            any("is not accepted by fetched" in error for error in errors)
        )

    def test_external_repository_checkout_must_match_repository_identity(self) -> None:
        temporary, root, accepted, payload = self.create_repository()
        external_temporary, external_root, external_head = (
            self.create_external_repository("stephenlclarke/containerization")
        )
        self.addCleanup(temporary.cleanup)
        self.addCleanup(external_temporary.cleanup)
        self.require_repositories(payload, "stephenlclarke/container")
        evidence = payload["evidence"]["DEMO-WP-01"]
        evidence["repositoryHeads"]["stephenlclarke/container"] = external_head

        errors = progress.validate_progress(
            payload,
            root,
            accepted_through=accepted,
            repository_roots={
                "stephenlclarke/container-compose": root,
                "stephenlclarke/container": external_root,
            },
        )

        self.assertTrue(
            any("trusted checkout does not identify" in error for error in errors)
        )

    def test_exact_git_checks_ignore_replacement_objects(self) -> None:
        temporary, root, accepted, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)
        (root / "docs/evidence.md").unlink()
        subprocess.run(["git", "add", "-u"], cwd=root, check=True)
        subprocess.run(
            [
                "git",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-qm",
                "later tree",
            ],
            cwd=root,
            check=True,
        )
        replacement = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        subprocess.run(["git", "checkout", "-q", accepted], cwd=root, check=True)
        subprocess.run(["git", "replace", accepted, replacement], cwd=root, check=True)

        self.assertEqual(progress.validate_progress(payload, root), [])

    def test_ci_grants_read_only_actions_authority(self) -> None:
        workflow = (progress.ROOT / ".github/workflows/ci.yml").read_text(
            encoding="utf-8"
        )
        permissions = workflow.split("permissions:\n", maxsplit=1)[1].split(
            "\n\n", maxsplit=1
        )[0]

        self.assertIn("  actions: read", permissions)
        self.assertNotIn("write", permissions)

    def test_ci_provisions_every_trusted_evidence_repository(self) -> None:
        workflow = (progress.ROOT / ".github/workflows/ci.yml").read_text(
            encoding="utf-8"
        )
        source_checks = workflow.split("  source_checks:\n", maxsplit=1)[1].split(
            "  validate_runtime:\n", maxsplit=1
        )[0]
        lightweight = workflow.split("  validate-lightweight:\n", maxsplit=1)[1]

        self.assertGreaterEqual(source_checks.count("fetch-depth: 0"), 6)
        self.assertGreaterEqual(lightweight.count("fetch-depth: 0"), 6)
        self.assertIn("GH_TOKEN: ${{ github.token }}", source_checks)
        self.assertIn("GH_TOKEN: ${{ github.token }}", lightweight)
        for repository, (environment_name, sibling_name) in (
            progress.TRUSTED_REPOSITORY_LOCATIONS.items()
        ):
            self.assertIn(f"repository: {repository}", source_checks)
            self.assertIn(f"path: {sibling_name}", source_checks)
            self.assertIn(f"repository: {repository}", lightweight)
            self.assertIn(
                f"path: programme-repositories/{sibling_name}", lightweight
            )
            self.assertIn(environment_name, lightweight)
        self.assertIn("PROGRAMME_PROGRESS_ACCEPTED_THROUGH", workflow)
        self.assertIn("python3 Tools/ci/programme-progress.py check", lightweight)

    def test_programme_base_cannot_move(self) -> None:
        temporary, root, _, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)
        payload["programmeBase"] = "0" * 40

        errors = progress.validate_progress(payload, root)

        self.assertTrue(
            any(
                "must remain the reviewed programme root" in error
                for error in errors
            )
        )

    def test_check_fails_when_generated_projection_is_stale(self) -> None:
        temporary, root, accepted, payload = self.create_repository()
        self.addCleanup(temporary.cleanup)
        register = root / "docs/parity/PROGRAMME-PROGRESS.json"
        rendered = root / "docs/parity/PROGRAMME-PROGRESS.md"
        register.parent.mkdir(parents=True)
        register.write_text(json.dumps(payload), encoding="utf-8")

        self.assertEqual(
            progress.main(
                [
                    "--root",
                    str(root),
                    "--register",
                    str(register),
                    "--rendered",
                    str(rendered),
                    "--accepted-through",
                    accepted,
                    "render",
                ]
            ),
            0,
        )
        self.assertEqual(
            progress.main(
                [
                    "--root",
                    str(root),
                    "--register",
                    str(register),
                    "--rendered",
                    str(rendered),
                    "--accepted-through",
                    accepted,
                    "check",
                ]
            ),
            0,
        )
        rendered.write_text("stale\n", encoding="utf-8")
        stderr = io.StringIO()
        with redirect_stderr(stderr):
            status = progress.main(
                [
                    "--root",
                    str(root),
                    "--register",
                    str(register),
                    "--rendered",
                    str(rendered),
                    "--accepted-through",
                    accepted,
                    "check",
                ]
            )

        self.assertEqual(status, 1)
        self.assertIn("programme progress is stale", stderr.getvalue())

    def test_loader_rejects_duplicate_json_keys_and_nonfinite_numbers(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        register = Path(temporary.name) / "progress.json"
        register.write_text(
            '{"schemaVersion": 1, "schemaVersion": 2}\n', encoding="utf-8"
        )

        with self.assertRaisesRegex(progress.ProgressError, "repeats JSON key"):
            progress.load_register(register)

        register.write_text('{"schemaVersion": NaN}\n', encoding="utf-8")
        with self.assertRaisesRegex(progress.ProgressError, "invalid JSON number"):
            progress.load_register(register)


if __name__ == "__main__":
    unittest.main()
