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

"""Focused fixtures for CodeQL source-extraction evidence."""

import json
import copy
import hashlib
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import codeql_compatibility as compatibility


CHECKER = Path(__file__).with_name("check-codeql-extraction.py")
GO_INVENTORY = Path(__file__).with_name("write-go-codeql-inventory.py")


class ExtractionInventoryTests(unittest.TestCase):
    def check(self, language: str, paths: list[str], invocations: list[dict],
              *, require_clean: bool = False, alerts: list[dict] | None = None) -> tuple[int, dict]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            sarif = root / "results.sarif"
            inventory = root / "inventory.txt"
            output = root / "report.json"
            sarif.write_text(json.dumps({"runs": [{"invocations": invocations, "results": alerts or []}]}))
            inventory.write_text("\n".join(paths) + "\n")
            command = [sys.executable, str(CHECKER), "--language", language,
                       "--sarif", str(sarif), "--inventory", str(inventory),
                       "--output", str(output)]
            if require_clean:
                command.append("--require-clean")
            result = subprocess.run(
                command,
                capture_output=True, text=True, check=False,
            )
            return result.returncode, json.loads(output.read_text())

    @staticmethod
    def invocation(language: str, paths: list[str], succeeded: bool = True) -> dict:
        return {
            "executionSuccessful": succeeded,
            "toolExecutionNotifications": [{
                "descriptor": {"id": f"{language}/diagnostics/successfully-extracted-files"},
                "locations": [{"physicalLocation": {"artifactLocation": {
                    "uri": path, "uriBaseId": "%SRCROOT%"
                }}} for path in paths],
            }],
        }

    def test_swift_success_requires_every_inventoried_source(self) -> None:
        paths = ["Sources/ComposeCore/A.swift", "Sources/ComposePlugin/B.swift"]
        status, report = self.check("swift", paths, [self.invocation("swift", paths)])
        self.assertEqual(status, 0)
        self.assertTrue(report["complete"])
        self.assertEqual(report["inventory_extracted_count"], 2)

    def test_go_failure_cannot_be_covered_by_another_successful_invocation(self) -> None:
        path = "Tools/compose-normalizer/main.go"
        status, report = self.check("go", [path], [
            self.invocation("go", [path], succeeded=False),
            self.invocation("go", [], succeeded=True),
        ])
        self.assertEqual(status, 1)
        self.assertFalse(report["invocation_success"])
        self.assertEqual(report["missing"], [path])

    def test_go_excludes_test_files_from_production_inventory(self) -> None:
        path = "Tools/compose-normalizer/main.go"
        status, report = self.check("go", [path], [self.invocation("go", [path])])
        self.assertEqual(status, 0)
        self.assertTrue(report["complete"])

    def test_strict_gate_rejects_alerts_even_with_complete_extraction(self) -> None:
        path = "Sources/ComposeCore/A.swift"
        status, report = self.check("swift", [path], [self.invocation("swift", [path])],
                                    require_clean=True, alerts=[{"ruleId": "swift/example"}])
        self.assertEqual(status, 1)
        self.assertTrue(report["complete"])
        self.assertFalse(report["clean"])

    def test_go_scope_parser_and_selected_sources(self) -> None:
        spec = importlib.util.spec_from_file_location("go_codeql_inventory", GO_INVENTORY)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            package = root / "Tools/compose-normalizer/remote"
            package.mkdir(parents=True)
            payload = json.dumps({"Dir": str(package), "GoFiles": ["cache_unix.go"]})
            payload += "\n" + json.dumps({"Dir": str(package), "GoFiles": ["git_command_unix.go"]})
            packages = module.packages_from_json(payload)
            self.assertEqual(len(packages), 2)
            self.assertEqual(module.selected_sources(packages, root), {
                "Tools/compose-normalizer/remote/cache_unix.go",
                "Tools/compose-normalizer/remote/git_command_unix.go",
            })


class ReviewedCompatibilityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.policy = compatibility.load_policy(CHECKER.with_name(compatibility.POLICY_NAME))
        self.results = [{"ruleId": item["rule_id"],
                         "partialFingerprints": item["partial_fingerprints"],
                         "locations": [{"physicalLocation": {
                             "artifactLocation": {"uri": item["uri"], "uriBaseId": "%SRCROOT%"},
                             "region": item["region"]}}]} for item in self.policy["findings"]]

    def assess(self, rows: list[dict]) -> dict:
        return compatibility.assessment({"runs": [{"results": rows}]}, self.policy)

    def test_exact_pair_keeps_raw_alert_count(self) -> None:
        result = self.assess(self.results)
        self.assertEqual(result["alert_count"], 2)
        self.assertEqual(result["reviewed_compatibility_count"], 2)
        self.assertEqual(result["actionable_alert_count"], 0)
        self.assertEqual(result["unreviewed_alert_count"], 0)
        self.assertTrue(result["compatibility_disposition_complete"])

    def test_missing_duplicate_new_changed_and_suppressed_findings_fail(self) -> None:
        cases = [[], self.results[:1], self.results + self.results[:1],
                 self.results + [{"ruleId": "swift/new-risk"}]]
        for field in ("rule", "uri", "line", "fingerprint", "suppression"):
            rows = copy.deepcopy(self.results)
            if field == "rule":
                rows[0]["ruleId"] = "swift/other"
            elif field == "uri":
                rows[0]["locations"][0]["physicalLocation"]["artifactLocation"]["uri"] = "Sources/New.swift"
            elif field == "line":
                rows[0]["locations"][0]["physicalLocation"]["region"]["startLine"] += 1
            elif field == "fingerprint":
                rows[0]["partialFingerprints"]["primaryLocationLineHash"] = "changed"
            else:
                rows[0]["suppressions"] = [{"kind": "external"}]
            cases.append(rows)
        for rows in cases:
            with self.subTest(rows=rows):
                self.assertFalse(self.assess(rows)["compatibility_disposition_complete"])

    def test_source_pin_repository_commit_and_file_drift_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy = copy.deepcopy(self.policy)
            source = root / policy["dependency"]["file"]
            source.parent.mkdir(parents=True)
            source.write_text("reviewed fixture")
            policy["dependency"]["sha256"] = hashlib.sha256(source.read_bytes()).hexdigest()
            pin = {"identity": policy["dependency"]["identity"],
                   "location": policy["dependency"]["repository"],
                   "state": {"revision": policy["dependency"]["revision"]}}
            for name in policy["dependency"]["lockfiles"]:
                (root / name).write_text(json.dumps({"pins": [pin]}))
            with patch.object(compatibility.subprocess, "check_output",
                              return_value=pin["state"]["revision"]):
                receipt = compatibility.source_receipt(root, policy, verify_checkout=True)
                self.assertEqual(receipt["revision"], pin["state"]["revision"])
                source.write_text("changed")
                with self.assertRaisesRegex(ValueError, "source hash"):
                    compatibility.source_receipt(root, policy, verify_checkout=True)
            with patch.object(compatibility.subprocess, "check_output", return_value="b" * 40):
                with self.assertRaisesRegex(ValueError, "checkout revision"):
                    compatibility.source_receipt(root, policy, verify_checkout=True)
            for field in ("location", "revision"):
                changed = copy.deepcopy(pin)
                if field == "location":
                    changed["location"] = "https://github.com/other/swift-certificates.git"
                else:
                    changed["state"]["revision"] = "b" * 40
                (root / policy["dependency"]["lockfiles"][0]).write_text(json.dumps({"pins": [changed]}))
                with self.assertRaisesRegex(ValueError, "pin or repository"):
                    compatibility.source_receipt(root, policy, verify_checkout=False)

    def test_shared_consumer_recomputes_counts_and_rejects_errors(self) -> None:
        root = CHECKER.resolve().parents[2]
        sarif = {"runs": [{"results": self.results}]}
        report = {"language": "swift", "complete": True, "clean": True,
                  "extraction_error_diagnostic_count": 0, **self.assess(self.results),
                  "compatibility_disposition_sha256": compatibility.digest(
                      CHECKER.with_name(compatibility.POLICY_NAME)),
                  "compatibility_source": compatibility.source_receipt(
                      root, self.policy, verify_checkout=False)}
        compatibility.require_report(report, sarif, root)
        for change in ({"alert_count": 0}, {"reviewed_compatibility_count": 0},
                       {"actionable_alert_count": 1}, {"complete": False},
                       {"extraction_error_diagnostic_count": 1},
                       {"compatibility_disposition_sha256": "0" * 64}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                compatibility.require_report({**report, **change}, sarif, root)
        with self.assertRaisesRegex(ValueError, "raw findings"):
            compatibility.require_report(report, {"runs": [{"results": self.results[:1]}]}, root)


if __name__ == "__main__":
    unittest.main()
