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

"""Tests for immutable release-quality badge snapshots."""

import importlib.util
import io
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock


def load_module():
    module_path = Path(__file__).with_name("capture-quality-snapshot.py")
    spec = importlib.util.spec_from_file_location("capture_quality_snapshot", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load module: {module_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["capture_quality_snapshot"] = module
    spec.loader.exec_module(module)
    return module


class CaptureQualitySnapshotTests(unittest.TestCase):
    """The release block is static and contains every required quality measure."""

    def test_render_snapshot_uses_native_metric_rows_and_links_owned_evidence(self) -> None:
        module = load_module()
        measures = {
            "alert_status": "OK",
            "bugs": "0",
            "code_smells": "15",
            "coverage": "90.8",
            "duplicated_lines_density": "0.7",
            "ncloc": "26901",
            "reliability_rating": "1.0",
            "security_rating": "1.0",
            "sqale_index": "199",
            "sqale_rating": "1.0",
            "vulnerabilities": "0",
        }

        snapshot = module.render_snapshot(
            commit="0123456789abcdef",
            sonar_analysis={"date": "2026-07-13T16:28:33+0000"},
            sonar_measures=measures,
            codeql_analysis={
                "results_count": 0,
                "rules_count": 34,
                "error": "",
                "warning": "",
            },
        )

        self.assertIn("## Quality Snapshot", snapshot)
        self.assertIn("static metrics", snapshot)
        self.assertIn("`0123456789abcdef`", snapshot)
        for label in (
            "Quality Gate Status",
            "Bugs",
            "Code Smells",
            "Coverage",
            "Duplicated Lines (%)",
            "Lines of Code",
            "Reliability Rating",
            "Security Rating",
            "Technical Debt",
            "Maintainability Rating",
            "Vulnerabilities",
        ):
            self.assertIn(label, snapshot)
        self.assertIn("**Quality Gate Status:** Passed", snapshot)
        self.assertIn("**Coverage:** 90.8%", snapshot)
        self.assertIn("**CodeQL Analysis:** Completed", snapshot)
        self.assertIn("**CodeQL Results:** 0", snapshot)
        self.assertIn("**CodeQL Rules:** 34", snapshot)
        self.assertIn("### Validated metrics", snapshot)
        metric_rows = [line for line in snapshot.splitlines() if line.startswith("- **")]
        self.assertEqual(
            metric_rows,
            [
                "- **Quality Gate Status:** Passed",
                "- **Bugs:** 0",
                "- **Code Smells:** 15",
                "- **Coverage:** 90.8%",
                "- **Duplicated Lines (%):** 0.7%",
                "- **Lines of Code:** 26,901",
                "- **Reliability Rating:** A",
                "- **Security Rating:** A",
                "- **Technical Debt:** 3h 19m",
                "- **Maintainability Rating:** A",
                "- **Vulnerabilities:** 0",
                "- **CodeQL Analysis:** Completed",
                "- **CodeQL Results:** 0",
                "- **CodeQL Rules:** 34",
            ],
        )
        self.assertIn("[Download the self-contained SVG evidence](quality-snapshot.svg)", snapshot)
        self.assertNotIn("![", snapshot)
        self.assertNotIn("img.shields.io", snapshot)
        self.assertNotIn("sonarcloud.io", snapshot)
        self.assertNotIn("Release", snapshot)
        self.assertNotIn("Visitor", snapshot)

    def test_default_wait_covers_the_full_codeql_workflow_window(self) -> None:
        module = load_module()
        self.assertEqual(module.POLL_TIMEOUT_SECONDS, 1800)

    def test_current_snapshot_can_omit_sonarqube_after_a_lightweight_ci_run(self) -> None:
        module = load_module()

        snapshot = module.render_snapshot(
            commit="0123456789abcdef",
            sonar_analysis=None,
            sonar_measures=None,
            codeql_analysis={
                "results_count": 0,
                "rules_count": 34,
                "error": "",
                "warning": "",
            },
            release_kind="current",
        )

        self.assertIn("CodeQL analysis covers `0123456789abcdef`", snapshot)
        self.assertIn("did not produce a SonarQube scan", snapshot)
        self.assertIn("**CodeQL Analysis:** Completed", snapshot)
        self.assertIn("**CodeQL Results:** 0", snapshot)
        self.assertIn("**CodeQL Rules:** 34", snapshot)
        self.assertNotIn("Quality Gate Status", snapshot)
        self.assertNotIn("SonarQube `main` analysis", snapshot)

    def test_optional_sonarqube_waits_only_for_codeql(self) -> None:
        module = load_module()
        module.find_sonarqube_analysis = lambda **_kwargs: self.fail(
            "optional SonarQube snapshots must not query SonarQube"
        )
        module.find_codeql_analysis = lambda **_kwargs: {
            "results_count": 0,
            "rules_count": 34,
            "error": "",
            "warning": "",
        }

        sonar_analysis, codeql_analysis = module.wait_for_analyses(
            host="https://example.invalid",
            project="example",
            branch="main",
            gh="gh",
            repository="example/repo",
            codeql_ref="refs/heads/main",
            commit="0123456789abcdef",
            poll_interval=1,
            poll_timeout=1,
            require_sonarqube=False,
        )

        self.assertIsNone(sonar_analysis)
        self.assertEqual(codeql_analysis["rules_count"], 34)

    def test_prebuilt_workflow_derives_the_sonarqube_requirement_from_ci(self) -> None:
        workflow = (
            Path(__file__).parents[2] / ".github/workflows/prebuilt-binaries.yml"
        ).read_text(encoding="utf-8")

        self.assertIn("sonarqube_snapshot_required", workflow)
        self.assertIn('select(.name == "SonarQube scan")', workflow)
        self.assertIn("--allow-missing-sonarqube", workflow)
        self.assertIn("quality_snapshot_asset", workflow)
        self.assertIn("--svg-output", workflow)
        self.assertIn("--asset-url", workflow)
        retention_step = workflow.split(
            "- name: Retain only current release assets", 1
        )[1].split("\n\n  repair-stable-tap:", 1)[0]
        self.assertIn(
            "QUALITY_SNAPSHOT_ASSET: ${{ steps.lane.outputs.quality_snapshot_asset }}",
            retention_step,
        )
        self.assertIn('--current-asset "${QUALITY_SNAPSHOT_ASSET}"', retention_step)

    def test_missing_sonarqube_metric_is_rejected(self) -> None:
        module = load_module()
        response = {
            "measures": [
                {
                    "metric": "coverage",
                    "history": [
                        {"date": "2026-07-13T16:28:33+0000", "value": "90.8"}
                    ],
                }
            ]
        }
        module.request_json = lambda _url: response

        with self.assertRaisesRegex(ValueError, "missing required metrics"):
            module.sonar_measures_for_analysis(
                host="https://example.invalid",
                project="example",
                branch="main",
                analysis={"date": "2026-07-13T16:28:33+0000"},
            )

    def test_current_snapshot_is_replaced_when_the_mutable_pointer_moves(self) -> None:
        module = load_module()
        measures = {
            "alert_status": "OK",
            "bugs": "0",
            "code_smells": "0",
            "coverage": "100",
            "duplicated_lines_density": "0",
            "ncloc": "1",
            "reliability_rating": "1.0",
            "security_rating": "1.0",
            "sqale_index": "0",
            "sqale_rating": "1.0",
            "vulnerabilities": "0",
        }

        snapshot = module.render_snapshot(
            commit="0123456789abcdef",
            sonar_analysis={"date": "2026-07-14T00:00:00+0000"},
            sonar_measures=measures,
            codeql_analysis={
                "results_count": 0,
                "rules_count": 34,
                "error": "",
                "warning": "",
            },
            release_kind="current",
        )

        self.assertIn("mutable Current build", snapshot)
        self.assertIn("replaced when `current` moves", snapshot)
        self.assertNotIn("retained as historical evidence", snapshot)

    def test_stable_and_current_snapshots_keep_the_same_native_metrics_and_evidence_link(self) -> None:
        module = load_module()
        measures = {
            "alert_status": "OK",
            "bugs": "0",
            "code_smells": "15",
            "coverage": "90.8",
            "duplicated_lines_density": "0.7",
            "ncloc": "26901",
            "reliability_rating": "1.0",
            "security_rating": "1.0",
            "sqale_index": "199",
            "sqale_rating": "1.0",
            "vulnerabilities": "0",
        }
        analysis = {"date": "2026-07-14T00:00:00+0000"}
        codeql = {
            "results_count": 0,
            "rules_count": 34,
            "error": "",
            "warning": "",
        }

        current = module.render_snapshot(
            commit="0123456789abcdef",
            sonar_analysis=analysis,
            sonar_measures=measures,
            codeql_analysis=codeql,
            release_kind="current",
        )
        stable = module.render_snapshot(
            commit="0123456789abcdef",
            sonar_analysis=analysis,
            sonar_measures=measures,
            codeql_analysis=codeql,
            release_kind="stable",
        )

        def metric_rows(snapshot: str) -> list[str]:
            return [line for line in snapshot.splitlines() if line.startswith("- **")]

        self.assertEqual(metric_rows(current), metric_rows(stable))
        self.assertEqual(len(metric_rows(stable)), 14)
        self.assertNotIn("![", current)
        self.assertNotIn("![", stable)
        self.assertIn("(quality-snapshot.svg)", stable)

    def test_render_badges_svg_is_self_contained_and_escapes_metric_text(self) -> None:
        module = load_module()

        svg = module.render_badges_svg(
            [
                module.snapshot_badge("Coverage & Quality", "80.8%", "orange"),
                module.snapshot_badge("Lines of Code", "30,546", "blue"),
            ]
        )

        self.assertIn('<svg xmlns="http://www.w3.org/2000/svg"', svg)
        self.assertIn("Coverage &amp; Quality", svg)
        self.assertIn("Lines of Code", svg)
        self.assertIn("80.8%", svg)
        self.assertIn("30,546", svg)
        self.assertNotIn("https://", svg)
        self.assertNotIn("img.shields.io", svg)

    def test_snapshot_badge_rejects_unknown_color(self) -> None:
        module = load_module()

        with self.assertRaisesRegex(ValueError, "unsupported quality badge color"):
            module.snapshot_badge("Coverage", "80.8%", "purple")

    def test_cli_requires_the_release_asset_url_when_writing_an_svg(self) -> None:
        module = load_module()

        with mock.patch.object(
            sys,
            "argv",
            [
                "capture-quality-snapshot.py",
                "--repo",
                "example/repo",
                "--commit",
                "0123456789abcdef",
                "--svg-output",
                "quality-snapshot.svg",
            ],
        ):
            with self.assertRaisesRegex(SystemExit, "supplied together"):
                module.main()

    def test_cli_writes_self_contained_svg_and_native_evidence_link(self) -> None:
        module = load_module()
        measures = {
            "alert_status": "OK",
            "bugs": "0",
            "code_smells": "1",
            "coverage": "80.8",
            "duplicated_lines_density": "0.5",
            "ncloc": "30546",
            "reliability_rating": "1.0",
            "security_rating": "1.0",
            "sqale_index": "1",
            "sqale_rating": "1.0",
            "vulnerabilities": "0",
        }
        module.wait_for_analyses = lambda **_kwargs: (
            {"date": "2026-07-19T09:11:45+0000"},
            {"results_count": 0, "rules_count": 34, "error": "", "warning": ""},
        )
        module.sonar_measures_for_analysis = lambda **_kwargs: measures

        with tempfile.TemporaryDirectory() as directory:
            asset_path = Path(directory) / "quality-snapshot.svg"
            output = io.StringIO()
            with mock.patch.object(
                sys,
                "argv",
                [
                    "capture-quality-snapshot.py",
                    "--repo",
                    "example/repo",
                    "--commit",
                    "0123456789abcdef",
                    "--svg-output",
                    str(asset_path),
                    "--asset-url",
                    "https://github.com/example/repo/releases/download/current/quality-snapshot.svg",
                ],
            ), redirect_stdout(output):
                module.main()

            svg = asset_path.read_text(encoding="utf-8")
            self.assertIn("Coverage", svg)
            self.assertIn("30,546", svg)
            self.assertNotIn("https://", svg)
            self.assertIn("https://github.com/example/repo/releases/download/current/quality-snapshot.svg", output.getvalue())
            self.assertNotIn("![", output.getvalue())
            self.assertNotIn("img.shields.io", output.getvalue())

    def test_codeql_warning_is_rejected(self) -> None:
        module = load_module()

        with self.assertRaisesRegex(ValueError, "error or warning"):
            list(
                module.snapshot_badges(
                    sonar_measures={
                        "alert_status": "OK",
                        "bugs": "0",
                        "code_smells": "0",
                        "coverage": "100",
                        "duplicated_lines_density": "0",
                        "ncloc": "1",
                        "reliability_rating": "1.0",
                        "security_rating": "1.0",
                        "sqale_index": "0",
                        "sqale_rating": "1.0",
                        "vulnerabilities": "0",
                    },
                    codeql_analysis={
                        "results_count": 0,
                        "rules_count": 34,
                        "error": "",
                        "warning": "partial analysis",
                    },
                )
            )


if __name__ == "__main__":
    unittest.main()
