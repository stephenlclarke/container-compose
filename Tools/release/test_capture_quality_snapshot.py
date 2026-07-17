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
import sys
import unittest
from pathlib import Path


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

    def test_render_snapshot_contains_static_sonarqube_and_codeql_badges(self) -> None:
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
        self.assertIn("non-clickable badges", snapshot)
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
            self.assertIn(f"![{label}]", snapshot)
        self.assertIn("message=Passed", snapshot)
        self.assertIn("message=90.8%25", snapshot)
        self.assertIn("![CodeQL Analysis]", snapshot)
        self.assertIn("![CodeQL Results]", snapshot)
        self.assertIn("message=34", snapshot)
        self.assertEqual(snapshot.count("![]"), 0)
        self.assertEqual(snapshot.count("!["), 14)
        badge_lines = [line for line in snapshot.splitlines() if line.startswith("![")]
        self.assertEqual(len(badge_lines), 1)
        self.assertIn(
            ") ![Bugs](https://img.shields.io/static/v1?label=Bugs", badge_lines[0]
        )
        self.assertNotIn("[![", snapshot)
        self.assertNotIn("sonarcloud.io", snapshot)
        self.assertNotIn("Release", snapshot)
        self.assertNotIn("Visitor", snapshot)

    def test_default_wait_covers_the_full_codeql_workflow_window(self) -> None:
        module = load_module()
        self.assertEqual(module.POLL_TIMEOUT_SECONDS, 1800)

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

    def test_stable_and_current_snapshots_keep_the_same_horizontal_metric_row(self) -> None:
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
            return [line for line in snapshot.splitlines() if line.startswith("![")]

        self.assertEqual(metric_rows(current), metric_rows(stable))
        self.assertEqual(len(metric_rows(stable)), 1)
        self.assertEqual(metric_rows(stable)[0].count("!["), 14)

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
