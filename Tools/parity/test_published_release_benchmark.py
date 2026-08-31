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

"""Focused tests for published release benchmark orchestration."""

from __future__ import annotations

import csv
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).parents[2]
TOOL = REPOSITORY / "Tools" / "parity" / "published_release_benchmark.py"
WORKFLOW = REPOSITORY / ".github" / "workflows" / "published-benchmark.yml"
DOCUMENTATION_WORKFLOW = REPOSITORY / ".github" / "workflows" / "docs.yml"
CI_WORKFLOW = REPOSITORY / ".github" / "workflows" / "ci.yml"
CODEQL_WORKFLOW = REPOSITORY / ".github" / "workflows" / "codeql.yml"
PERFORMANCE_MATRIX = REPOSITORY / "Tools" / "parity" / "check-compose-performance-matrix.sh"
SPEC = importlib.util.spec_from_file_location("published_release_benchmark", TOOL)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ResolvePublishedVersionsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.releases = [
            {"tagName": "0.12.0", "isDraft": False, "isPrerelease": False},
            {"tagName": "0.13.0", "isDraft": False, "isPrerelease": False},
            {"tagName": "0.14.0", "isDraft": False, "isPrerelease": False},
            {"tagName": "current", "isDraft": False, "isPrerelease": True},
            {"tagName": "0.15.0", "isDraft": True, "isPrerelease": False},
        ]

    def test_default_comparison_is_immediately_preceding_stable_release(self) -> None:
        self.assertEqual(
            MODULE.resolve_versions(self.releases, "0.14.0", None),
            {"target": "0.14.0", "baseline": "0.13.0"},
        )

    def test_explicit_comparison_can_select_any_other_stable_release(self) -> None:
        self.assertEqual(
            MODULE.resolve_versions(self.releases, "0.14.0", "0.12.0"),
            {"target": "0.14.0", "baseline": "0.12.0"},
        )

    def test_draft_target_is_rejected(self) -> None:
        with self.assertRaises(MODULE.BenchmarkInputError):
            MODULE.resolve_versions(self.releases, "0.15.0", None)


class ResolvePublishedArtifactsTests(unittest.TestCase):
    def test_newest_successful_immutable_package_run_is_selected(self) -> None:
        repository = "https://github.com/stephenlclarke/container-compose"
        runs = [
            {
                "databaseId": 10,
                "displayTitle": "Prebuilt Binaries · 0.13.0",
                "event": "workflow_dispatch",
                "status": "completed",
                "conclusion": "success",
                "createdAt": "2026-08-23T10:00:00Z",
                "url": f"{repository}/actions/runs/10",
            },
            {
                "databaseId": 11,
                "displayTitle": "Prebuilt Binaries · 0.13.0",
                "event": "workflow_dispatch",
                "status": "completed",
                "conclusion": "failure",
                "createdAt": "2026-08-24T10:00:00Z",
                "url": f"{repository}/actions/runs/11",
            },
            {
                "databaseId": 12,
                "displayTitle": "Prebuilt Binaries · 0.13.0",
                "event": "workflow_dispatch",
                "status": "completed",
                "conclusion": "success",
                "createdAt": "2026-08-24T11:00:00Z",
                "url": f"{repository}/actions/runs/12",
            },
            {
                "databaseId": 13,
                "displayTitle": "Prebuilt Binaries · 0.13.0",
                "event": "push",
                "status": "completed",
                "conclusion": "success",
                "createdAt": "2026-08-25T10:00:00Z",
                "url": f"{repository}/actions/runs/13",
            },
        ]

        self.assertEqual(
            MODULE.resolve_packaging_run(runs, "0.13.0"),
            {
                "runId": 12,
                "url": f"{repository}/actions/runs/12",
                "createdAt": "2026-08-24T11:00:00Z",
            },
        )

    def test_missing_successful_package_run_is_rejected(self) -> None:
        with self.assertRaisesRegex(
            MODULE.BenchmarkInputError, "no successful immutable package run"
        ):
            MODULE.resolve_packaging_run([], "0.13.0")

    def test_required_unexpired_package_artifacts_are_validated(self) -> None:
        payload = {
            "artifacts": [
                {
                    "id": 1,
                    "name": "container-release-arm64.tar.gz",
                    "expired": False,
                },
                {
                    "id": 2,
                    "name": "container-compose-plugin-release-arm64.tar.gz",
                    "expired": False,
                },
                {"id": 3, "name": "unrelated", "expired": False},
            ]
        }

        self.assertEqual(
            MODULE.validate_packaging_artifacts(payload),
            {
                "container-compose-plugin-release-arm64.tar.gz": 2,
                "container-release-arm64.tar.gz": 1,
            },
        )

    def test_expired_or_duplicate_package_artifact_is_rejected(self) -> None:
        payload = {
            "artifacts": [
                {
                    "id": 1,
                    "name": "container-release-arm64.tar.gz",
                    "expired": False,
                },
                {
                    "id": 2,
                    "name": "container-release-arm64.tar.gz",
                    "expired": False,
                },
                {
                    "id": 3,
                    "name": "container-compose-plugin-release-arm64.tar.gz",
                    "expired": True,
                },
            ]
        }

        with self.assertRaises(MODULE.BenchmarkInputError):
            MODULE.validate_packaging_artifacts(payload)


class HomebrewAuthorityTests(unittest.TestCase):
    def test_release_tag_resolves_to_peeled_commit(self) -> None:
        with tempfile.TemporaryDirectory(prefix="published-source-") as directory:
            repository = Path(directory)
            self.git(repository, "init", "-b", "main")
            self.git(repository, "config", "user.email", "test@example.com")
            self.git(repository, "config", "user.name", "Test")
            (repository / "README.md").write_text("release\n", encoding="utf-8")
            stack_manifest = repository / "Tools" / "release" / "stack-refs.json"
            stack_manifest.parent.mkdir(parents=True)
            stack_manifest.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "components": {
                            "container": {
                                "repository": "stephenlclarke/container",
                                "ref": "1" * 40,
                            },
                            "containerization": {
                                "repository": "stephenlclarke/containerization",
                                "ref": "2" * 40,
                            },
                        },
                    }
                ),
                encoding="utf-8",
            )
            self.git(repository, "add", "README.md", str(stack_manifest))
            self.git(repository, "commit", "-m", "chore: initialize release")
            self.git(repository, "tag", "-a", "0.14.0", "-m", "0.14.0")

            expected = subprocess.run(
                ["git", "-C", str(repository), "rev-parse", "HEAD"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()

            self.assertEqual(
                MODULE.release_tag_commit(repository, "0.14.0"), expected
            )
            self.assertEqual(
                MODULE.release_tag_stack(repository, expected),
                {
                    "container": {
                        "repository": "stephenlclarke/container",
                        "ref": "1" * 40,
                    },
                    "containerization": {
                        "repository": "stephenlclarke/containerization",
                        "ref": "2" * 40,
                    },
                },
            )

    def test_side_branch_cannot_authorize_unpublished_formula(self) -> None:
        with tempfile.TemporaryDirectory(prefix="published-tap-") as directory:
            repository = Path(directory)
            self.git(repository, "init", "-b", "main")
            self.git(repository, "config", "user.email", "test@example.com")
            self.git(repository, "config", "user.name", "Test")
            formula = repository / "Formula" / "container.rb"
            formula.parent.mkdir()
            formula.write_text("class Container\nend\n", encoding="utf-8")
            self.git(repository, "add", str(formula))
            self.git(repository, "commit", "-m", "chore: initialize formula")
            self.git(repository, "switch", "-c", "unmerged-proof")
            asset = "container-release-arm64.tar.gz"
            digest = "a" * 64
            formula.write_text(
                "class Container\n"
                f'  url "https://github.com/{MODULE.REPOSITORY}/releases/'
                f'download/0.14.0/{asset}"\n'
                f'  sha256 "{digest}"\n'
                "end\n",
                encoding="utf-8",
            )
            self.git(repository, "add", str(formula))
            self.git(repository, "commit", "-m", "test: add branch-only proof")

            with self.assertRaisesRegex(
                MODULE.BenchmarkInputError, "Homebrew main history never distributed"
            ):
                MODULE.formula_authority(
                    repository,
                    "Formula/container.rb",
                    "0.14.0",
                    asset,
                    digest,
                )

            self.git(repository, "switch", "main")
            self.git(repository, "merge", "--ff-only", "unmerged-proof")
            authority = MODULE.formula_authority(
                repository,
                "Formula/container.rb",
                "0.14.0",
                asset,
                digest,
            )
            self.assertRegex(authority, r"^[0-9a-f]{40}$")

    @staticmethod
    def git(repository: Path, *arguments: str) -> None:
        subprocess.run(
            ["git", "-C", str(repository), *arguments],
            check=True,
            capture_output=True,
            text=True,
        )


class PublishedReportTests(unittest.TestCase):
    def test_report_compares_exact_published_samples(self) -> None:
        with tempfile.TemporaryDirectory(prefix="published-benchmark-") as directory:
            root = Path(directory)
            baseline = root / "baseline"
            target = root / "target"
            baseline.mkdir()
            target.mkdir()
            self.write_evidence(baseline, 1.0, 1.0)
            self.write_evidence(target, 0.8, 1.0)
            baseline_manifest = self.write_manifest(root, "0.13.0")
            target_manifest = self.write_manifest(root, "0.14.0")
            output = root / "report.md"

            MODULE.render_report(
                target,
                baseline,
                target_manifest,
                baseline_manifest,
                output,
                "https://github.example/actions/runs/1",
            )
            report = output.read_text(encoding="utf-8")

        self.assertIn("# Published release benchmark: 0.14.0 versus 0.13.0", report)
        self.assertIn("-20.0%", report)
        self.assertIn("Improved", report)
        self.assertIn("No source product was built", report)
        self.assertIn("excluded to keep the unattended run free", report)
        self.assertIn("Artifact source:", report)

    def test_report_rejects_mismatched_benchmark_conditions(self) -> None:
        with tempfile.TemporaryDirectory(prefix="published-benchmark-") as directory:
            root = Path(directory)
            baseline = root / "baseline"
            target = root / "target"
            baseline.mkdir()
            target.mkdir()
            self.write_evidence(baseline, 1.0, 1.0)
            self.write_evidence(target, 0.8, 1.0)
            fingerprints = json.loads(
                (target / "fingerprints.json").read_text(encoding="utf-8")
            )
            fingerprints["conditions"]["image"] = "alpine:3.21"
            (target / "fingerprints.json").write_text(
                json.dumps(fingerprints), encoding="utf-8"
            )

            with self.assertRaisesRegex(
                MODULE.BenchmarkInputError, "benchmark conditions differ"
            ):
                MODULE.render_report(
                    target,
                    baseline,
                    self.write_manifest(root, "0.14.0"),
                    self.write_manifest(root, "0.13.0"),
                    root / "report.md",
                    "https://github.example/actions/runs/1",
                )

    def test_report_rejects_sample_count_that_disagrees_with_conditions(self) -> None:
        with tempfile.TemporaryDirectory(prefix="published-benchmark-") as directory:
            root = Path(directory)
            baseline = root / "baseline"
            target = root / "target"
            baseline.mkdir()
            target.mkdir()
            self.write_evidence(baseline, 1.0, 1.0)
            self.write_evidence(target, 0.8, 1.0)
            for evidence in (target, baseline):
                fingerprints = json.loads(
                    (evidence / "fingerprints.json").read_text(encoding="utf-8")
                )
                fingerprints["conditions"]["repetitions"] = 3
                (evidence / "fingerprints.json").write_text(
                    json.dumps(fingerprints), encoding="utf-8"
                )

            with self.assertRaisesRegex(
                MODULE.BenchmarkInputError, "2 samples; expected 3"
            ):
                MODULE.render_report(
                    target,
                    baseline,
                    self.write_manifest(root, "0.14.0"),
                    self.write_manifest(root, "0.13.0"),
                    root / "report.md",
                    "https://github.example/actions/runs/1",
                )

    def test_report_rejects_compose_version_from_another_release(self) -> None:
        with tempfile.TemporaryDirectory(prefix="published-benchmark-") as directory:
            root = Path(directory)
            baseline = root / "baseline"
            target = root / "target"
            baseline.mkdir()
            target.mkdir()
            self.write_evidence(baseline, 1.0, 1.0, "0.13.0")
            self.write_evidence(target, 0.8, 1.0, "0.13.0")

            with self.assertRaisesRegex(
                MODULE.BenchmarkInputError,
                "target Compose version is '0.13.0'; expected '0.14.0'",
            ):
                MODULE.render_report(
                    target,
                    baseline,
                    self.write_manifest(root, "0.14.0"),
                    self.write_manifest(root, "0.13.0"),
                    root / "report.md",
                    "https://github.example/actions/runs/1",
                )

    def test_report_rejects_runtime_from_another_matched_stack(self) -> None:
        with tempfile.TemporaryDirectory(prefix="published-benchmark-") as directory:
            root = Path(directory)
            baseline = root / "baseline"
            target = root / "target"
            baseline.mkdir()
            target.mkdir()
            self.write_evidence(baseline, 1.0, 1.0, "0.13.0")
            self.write_evidence(target, 0.8, 1.0, "0.14.0")
            fingerprints = json.loads(
                (target / "fingerprints.json").read_text(encoding="utf-8")
            )
            fingerprints["containerRuntime"]["version"][0]["commit"] = "f" * 40
            (target / "fingerprints.json").write_text(
                json.dumps(fingerprints), encoding="utf-8"
            )

            with self.assertRaisesRegex(
                MODULE.BenchmarkInputError, "target runtime commit"
            ):
                MODULE.render_report(
                    target,
                    baseline,
                    self.write_manifest(root, "0.14.0"),
                    self.write_manifest(root, "0.13.0"),
                    root / "report.md",
                    "https://github.example/actions/runs/1",
                )

    def test_report_rejects_debug_runtime_helper(self) -> None:
        with tempfile.TemporaryDirectory(prefix="published-benchmark-") as directory:
            root = Path(directory)
            baseline = root / "baseline"
            target = root / "target"
            baseline.mkdir()
            target.mkdir()
            self.write_evidence(baseline, 1.0, 1.0, "0.13.0")
            self.write_evidence(target, 0.8, 1.0, "0.14.0")
            fingerprints = json.loads(
                (target / "fingerprints.json").read_text(encoding="utf-8")
            )
            fingerprints["containerRuntime"]["version"][1]["buildType"] = "debug"
            (target / "fingerprints.json").write_text(
                json.dumps(fingerprints), encoding="utf-8"
            )

            with self.assertRaisesRegex(
                MODULE.BenchmarkInputError,
                "runtime component 'container-apiserver' is not a release build",
            ):
                MODULE.render_report(
                    target,
                    baseline,
                    self.write_manifest(root, "0.14.0"),
                    self.write_manifest(root, "0.13.0"),
                    root / "report.md",
                    "https://github.example/actions/runs/1",
                )

    def test_report_rejects_compose_commit_outside_release_tag(self) -> None:
        with tempfile.TemporaryDirectory(prefix="published-benchmark-") as directory:
            root = Path(directory)
            baseline = root / "baseline"
            target = root / "target"
            baseline.mkdir()
            target.mkdir()
            self.write_evidence(baseline, 1.0, 1.0, "0.13.0")
            self.write_evidence(target, 0.8, 1.0, "0.14.0")
            target_manifest = self.write_manifest(root, "0.14.0")
            manifest = json.loads(target_manifest.read_text(encoding="utf-8"))
            manifest["sourceCommit"] = "f" * 40
            target_manifest.write_text(json.dumps(manifest), encoding="utf-8")

            with self.assertRaisesRegex(
                MODULE.BenchmarkInputError, "does not match release tag commit"
            ):
                MODULE.render_report(
                    target,
                    baseline,
                    target_manifest,
                    self.write_manifest(root, "0.13.0"),
                    root / "report.md",
                    "https://github.example/actions/runs/1",
                )

    def test_report_rejects_matched_runtime_outside_tagged_stack(self) -> None:
        with tempfile.TemporaryDirectory(prefix="published-benchmark-") as directory:
            root = Path(directory)
            baseline = root / "baseline"
            target = root / "target"
            baseline.mkdir()
            target.mkdir()
            self.write_evidence(baseline, 1.0, 1.0, "0.13.0")
            self.write_evidence(target, 0.8, 1.0, "0.14.0")
            fingerprints = json.loads(
                (target / "fingerprints.json").read_text(encoding="utf-8")
            )
            fingerprints["containerCompose"]["version"]["containerRef"] = "f" * 40
            for component in fingerprints["containerRuntime"]["version"]:
                component["commit"] = "f" * 40
            (target / "fingerprints.json").write_text(
                json.dumps(fingerprints), encoding="utf-8"
            )

            with self.assertRaisesRegex(
                MODULE.BenchmarkInputError, "target Compose containerRef"
            ):
                MODULE.render_report(
                    target,
                    baseline,
                    self.write_manifest(root, "0.14.0"),
                    self.write_manifest(root, "0.13.0"),
                    root / "report.md",
                    "https://github.example/actions/runs/1",
                )

    def test_report_uses_docker_control_for_verdicts_and_headline(self) -> None:
        with tempfile.TemporaryDirectory(prefix="published-benchmark-") as directory:
            root = Path(directory)
            baseline = root / "baseline"
            target = root / "target"
            baseline.mkdir()
            target.mkdir()
            self.write_evidence(baseline, 1.0, 1.0, "0.13.0")
            self.write_evidence(target, 2.0, 2.0, "0.14.0")
            output = root / "report.md"

            MODULE.render_report(
                target,
                baseline,
                self.write_manifest(root, "0.14.0"),
                self.write_manifest(root, "0.13.0"),
                output,
                "https://github.example/actions/runs/1",
            )
            report = output.read_text(encoding="utf-8")

        self.assertIn("Docker-normalized geometric-mean median changed +0.0%", report)
        self.assertIn("| +100.0% |", report)
        self.assertIn("| +0.0% | +0.0% | Within noise |", report)

    @staticmethod
    def write_evidence(
        root: Path,
        candidate: float,
        docker: float,
        version: str | None = None,
    ) -> None:
        with (root / "timings.tsv").open("w", encoding="utf-8", newline="") as handle:
            writer = csv.writer(handle, delimiter="\t", lineterminator="\n")
            writer.writerow(
                [
                    "fixture",
                    "lane",
                    "repetition",
                    "schedule_position",
                    "direction",
                    "duration_seconds",
                    "outcome",
                    "command",
                ]
            )
            for repetition in (1, 2):
                writer.writerow(
                    ["startup-1-services", "docker", repetition, 1, "lower-is-better", docker, "success", "docker"]
                )
                writer.writerow(
                    ["startup-1-services", "container-compose", repetition, 2, "lower-is-better", candidate, "success", "compose"]
                )
        release_version = version or ("0.13.0" if "baseline" in root.name else "0.14.0")
        container_ref = ("1" if release_version == "0.13.0" else "2") * 40
        containerization_ref = ("3" if release_version == "0.13.0" else "4") * 40
        fingerprints = {
            "conditions": {
                "comparableNoisePercent": 5,
                "image": "alpine:3.20",
                "repetitions": 2,
            },
            "docker": {"composeVersion": "5.4.0", "engine": {"Version": "29.2.1"}},
            "containerCompose": {
                "sha256": "a" * 64,
                "version": {
                    "version": release_version,
                    "source": MODULE.REPOSITORY,
                    "lane": "stable",
                    "commit": ("5" if release_version == "0.13.0" else "6") * 40,
                    "buildType": "release",
                    "containerSource": "stephenlclarke/container",
                    "containerRef": container_ref,
                    "containerizationSource": "stephenlclarke/containerization",
                    "containerizationRef": containerization_ref,
                },
            },
            "containerRuntime": {
                "sha256": "b" * 64,
                "version": [
                    {
                        "appName": "container",
                        "buildType": "release",
                        "commit": container_ref,
                        "source": "stephenlclarke/container",
                        "containerization": (
                            "stephenlclarke/containerization@"
                            + containerization_ref
                        ),
                    },
                    {
                        "appName": "container-apiserver",
                        "buildType": "release",
                        "commit": container_ref,
                    },
                ],
            },
            "host": {
                "architecture": "arm64",
                "hardwareMemoryBytes": 16,
                "hardwareModel": "Mac",
                "macOSVersion": "26.6",
            },
        }
        (root / "fingerprints.json").write_text(
            json.dumps(fingerprints), encoding="utf-8"
        )

    @staticmethod
    def write_manifest(root: Path, version: str) -> Path:
        path = root / f"{version}.json"
        container_ref = ("1" if version == "0.13.0" else "2") * 40
        containerization_ref = ("3" if version == "0.13.0" else "4") * 40
        path.write_text(
            json.dumps(
                {
                    "version": version,
                    "sourceCommit": (
                        "5" if version == "0.13.0" else "6"
                    ) * 40,
                    "stack": {
                        "container": {
                            "repository": "stephenlclarke/container",
                            "ref": container_ref,
                        },
                        "containerization": {
                            "repository": "stephenlclarke/containerization",
                            "ref": containerization_ref,
                        },
                    },
                    "release": f"https://github.example/{version}",
                    "artifactSource": (
                        "https://github.com/stephenlclarke/container-compose/"
                        f"releases/tag/{version}"
                    ),
                    "assets": {
                        "runtime": {
                            "asset": "container-release-arm64.tar.gz",
                            "sha256": "a" * 64,
                            "homebrewCommit": "b" * 40,
                        },
                        "compose": {
                            "asset": "container-compose-plugin-release-arm64.tar.gz",
                            "sha256": "c" * 64,
                            "homebrewCommit": "d" * 40,
                        },
                    },
                }
            ),
            encoding="utf-8",
        )
        return path


class PublishedBenchmarkWorkflowTests(unittest.TestCase):
    def test_performance_matrix_records_structured_release_identities(self) -> None:
        matrix = PERFORMANCE_MATRIX.read_text(encoding="utf-8")

        self.assertIn('"$CONTAINER_COMPOSE" version --format json', matrix)
        self.assertIn('"$CONTAINER_BINARY" system version --format json', matrix)
        self.assertIn('"version": decode(compose_version)', matrix)

    def test_workflow_accepts_target_and_optional_comparison_versions(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("version:", workflow)
        self.assertIn("compare_to:", workflow)
        self.assertIn("published_release_benchmark.py", workflow)
        self.assertIn("            resolve\n", workflow)
        self.assertIn("--source-repository .", workflow)

    def test_workflow_downloads_published_assets_without_building_products(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("gh release download", workflow)
        self.assertIn("resolve-package-run", workflow)
        self.assertIn("validate-package-artifacts", workflow)
        self.assertIn("gh run download", workflow)
        self.assertIn("--artifact-source", workflow)
        self.assertIn("No source products are built", workflow)
        self.assertIn("PARITY_INCLUDE_REMOTE_LOGGING=0", workflow)
        self.assertNotIn("PARITY_SINK_BIND_ADDRESS=0.0.0.0", workflow)
        self.assertIn(
            "CONTAINER_RUNTIME_ANONYMOUS_REGISTRY_HOSTS=ghcr.io,docker.io",
            workflow,
        )
        for forbidden in ("swift build", "swift test", "make build", "make package"):
            self.assertNotIn(forbidden, workflow)

    def test_workflow_rejects_interactive_documentation_signing(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        preflight = workflow.index("Verify unattended documentation signing")
        benchmark = workflow.index("Run same-host published comparisons")

        self.assertLess(preflight, benchmark)
        self.assertIn("ssh-keygen -y -P ''", workflow)
        self.assertIn("git config commit.gpgsign true", workflow)

    def test_workflow_exposes_the_signing_runner_only_from_protected_main(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        resolve = workflow[workflow.index("  resolve:") : workflow.index("  benchmark:")]
        benchmark = workflow[workflow.index("  benchmark:") :]

        for job in (resolve, benchmark):
            self.assertIn("github.repository == 'stephenlclarke/container-compose'", job)
            self.assertIn("github.ref == 'refs/heads/main'", job)
            self.assertIn("ref: main", job)

    def test_workflow_reruns_use_a_fresh_publication_branch(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")

        self.assertIn(
            "${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}",
            workflow,
        )

    def test_benchmark_report_only_change_skips_docc_builds(self) -> None:
        workflow = DOCUMENTATION_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("Classify documented API and site inputs", workflow)
        self.assertIn("classify-documentation-changes.py", workflow)
        self.assertIn("needs.classify-changes.outputs.build_docc == 'true'", workflow)

    def test_documentation_pr_dispatches_only_lightweight_protected_checks(self) -> None:
        benchmark = WORKFLOW.read_text(encoding="utf-8")
        ci = CI_WORKFLOW.read_text(encoding="utf-8")
        codeql = CODEQL_WORKFLOW.read_text(encoding="utf-8")

        self.assertIn("gh workflow run ci.yml", benchmark)
        self.assertNotIn("gh workflow run codeql.yml", benchmark)
        self.assertIn("documentation_pr:", ci)
        self.assertNotIn("documentation_pr:", codeql)
        self.assertIn("release_ref:", codeql)
        self.assertIn("CodeQL Release Recovery", codeql)
        self.assertIn(".head.repo.full_name", ci)
        self.assertIn(".head.sha", ci)
        self.assertIn("${GITHUB_SHA}", ci)
        self.assertIn(".base.ref", ci)


if __name__ == "__main__":
    unittest.main()
