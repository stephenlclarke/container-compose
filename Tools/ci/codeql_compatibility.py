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

"""Exact, source-bound review of two upstream RSA/SHA1 compatibility findings."""

import hashlib
import json
from pathlib import Path
import subprocess

POLICY_NAME = "codeql-swift-compatibility.json"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_policy(path: Path) -> dict:
    policy = json.loads(path.read_text())
    entries = policy.get("findings", [])
    if (policy.get("schema") != 1 or policy.get("language") != "swift"
            or policy.get("expected_count") != 2 or len(entries) != 2
            or len({entry["id"] for entry in entries}) != 2):
        raise ValueError("Invalid exact CodeQL compatibility disposition")
    return policy


def source_receipt(root: Path, policy: dict, *, verify_checkout: bool) -> dict:
    dependency = policy["dependency"]
    locks = {}
    for name in dependency["lockfiles"]:
        path = root / name
        pins = [pin for pin in json.loads(path.read_text())["pins"]
                if pin["identity"] == dependency["identity"]]
        if (len(pins) != 1 or pins[0]["location"] != dependency["repository"]
                or pins[0]["state"]["revision"] != dependency["revision"]):
            raise ValueError("Reviewed CodeQL dependency pin or repository changed: " + name)
        locks[name] = digest(path)
    if verify_checkout:
        checkout = root / dependency["checkout"]
        revision = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"],
                                           text=True, timeout=10).strip()
        if revision != dependency["revision"]:
            raise ValueError("Reviewed CodeQL dependency checkout revision changed")
        source = root / dependency["file"]
        if source.is_symlink() or digest(source) != dependency["sha256"]:
            raise ValueError("Reviewed CodeQL dependency source hash changed")
    return {"identity": dependency["identity"], "repository": dependency["repository"],
            "revision": dependency["revision"], "file": dependency["file"],
            "source_sha256": dependency["sha256"], "lock_sha256": locks}


def findings(sarif: dict) -> list[dict]:
    return [row for run in sarif.get("runs", []) for row in run.get("results", [])]


def matches(row: dict, expected: dict) -> bool:
    locations = row.get("locations", [])
    if len(locations) != 1:
        return False
    physical = locations[0].get("physicalLocation", {})
    location = physical.get("artifactLocation", {})
    return (row.get("ruleId") == expected["rule_id"]
            and location.get("uri") == expected["uri"]
            and location.get("uriBaseId") == "%SRCROOT%"
            and physical.get("region") == expected["region"]
            and row.get("partialFingerprints") == expected["partial_fingerprints"]
            and not row.get("suppressions"))


def assessment(sarif: dict, policy: dict | None = None) -> dict:
    rows = findings(sarif)
    matched = []
    unreviewed = 0
    for row in rows:
        entries = [entry for entry in (policy["findings"] if policy else [])
                   if matches(row, entry)]
        if len(entries) == 1 and entries[0]["id"] not in matched:
            matched.append(entries[0]["id"])
        else:
            unreviewed += 1
    exact = (len(rows) == policy["expected_count"]
             and set(matched) == {entry["id"] for entry in policy["findings"]}
             and unreviewed == 0) if policy else not rows
    return {"alert_count": len(rows), "reviewed_compatibility_count": len(matched),
            "actionable_alert_count": unreviewed, "unreviewed_alert_count": unreviewed,
            "reviewed_compatibility_ids": sorted(matched),
            "compatibility_disposition_complete": exact}


def require_report(report: dict, sarif: dict, root: Path) -> None:
    """Use the same raw-result and policy checks in aggregate and local admission."""
    if (report.get("complete") is not True or report.get("clean") is not True
            or report.get("extraction_error_diagnostic_count") != 0):
        raise ValueError("CodeQL extraction is incomplete or has errors/findings")
    policy = None
    if report.get("language") == "swift":
        path = root / "Tools/ci" / POLICY_NAME
        policy = load_policy(path)
        if (report.get("compatibility_disposition_sha256") != digest(path)
                or report.get("compatibility_source") !=
                source_receipt(root, policy, verify_checkout=False)):
            raise ValueError("CodeQL reviewed dependency disposition/source receipt changed")
    expected = assessment(sarif, policy)
    if (not expected["compatibility_disposition_complete"]
            or any(report.get(key) != value for key, value in expected.items())):
        raise ValueError("CodeQL raw findings differ from the exact reviewed disposition")
