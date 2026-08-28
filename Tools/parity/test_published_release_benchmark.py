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


class HomebrewAuthorityTests(unittest.TestCase):
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

    @staticmethod
    def write_evidence(root: Path, candidate: float, docker: float) -> None:
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
        fingerprints = {
            "conditions": {
                "comparableNoisePercent": 5,
                "image": "alpine:3.20",
                "repetitions": 2,
            },
            "docker": {"composeVersion": "5.4.0", "engine": {"Version": "29.2.1"}},
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
        path.write_text(
            json.dumps(
                {
                    "version": version,
                    "release": f"https://github.example/{version}",
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
    def test_workflow_accepts_target_and_optional_comparison_versions(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("version:", workflow)
        self.assertIn("compare_to:", workflow)
        self.assertIn("published_release_benchmark.py", workflow)
        self.assertIn("            resolve\n", workflow)

    def test_workflow_downloads_published_assets_without_building_products(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("gh release download", workflow)
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

    def test_benchmark_report_only_change_skips_docc_builds(self) -> None:
        workflow = DOCUMENTATION_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("Keep benchmark-only reports out of the DocC build path", workflow)
        self.assertIn("^docs/benchmarks/[^/]+[.]md$", workflow)
        self.assertIn("needs.classify-changes.outputs.build_docc == 'true'", workflow)

    def test_documentation_pr_dispatches_only_lightweight_protected_checks(self) -> None:
        benchmark = WORKFLOW.read_text(encoding="utf-8")
        ci = CI_WORKFLOW.read_text(encoding="utf-8")
        codeql = CODEQL_WORKFLOW.read_text(encoding="utf-8")

        self.assertIn("gh workflow run ci.yml", benchmark)
        self.assertIn("gh workflow run codeql.yml", benchmark)
        self.assertIn("documentation_pr:", ci)
        self.assertIn("documentation_pr:", codeql)
        self.assertIn('inputs.documentation_pr != \'\'', codeql)
        self.assertIn("Analyze Go (No Go changes)", codeql)
        for workflow in (ci, codeql):
            self.assertIn(".head.repo.full_name", workflow)
            self.assertIn(".head.sha", workflow)
            self.assertIn("${GITHUB_SHA}", workflow)
            self.assertIn(".base.ref", workflow)


if __name__ == "__main__":
    unittest.main()
