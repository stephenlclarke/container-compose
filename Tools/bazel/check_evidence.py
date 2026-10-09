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

"""Validate Bazel test evidence; never schedule or execute builds."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import xml.etree.ElementTree as ET
from urllib.parse import unquote, urlparse

from coverage_report import require_clean_coverage_log, sonar_xml


EXPECTED = {
    "//:BazelFrameworkTests": 2,
    "//:DevContainerModelTests": 11,
    "//:DevContainerProjectTests": 1,
    "//:DevContainerStateTests": 7,
    "//Tools/bazel:version_generator_tests": 1,
}

SOURCE_TESTS = {
    "//:DevContainerModelTests": 11,
    "//:DevContainerStateTests": 7,
    "//:DevContainerCoreTests": 13,
    "//:DevContainerCLITests": 13,
    "//:DevContainerProcessTests": 2,
    "//:DevContainerDockerAPITests": 53,
    "//:DevContainerComposeProviderTests": 12,
    "//:DevContainerComposeCLITests": 10,
    "//:DevContainerAppleRuntimeTests": 97,
    "//:DevContainerServiceTests": 5,
}


def policy_paths(values: object) -> list[str]:
    """Validate unique relative paths before using them as source boundaries."""
    if not isinstance(values, list) or not values or not all(isinstance(value, str) for value in values):
        raise ValueError("Policy requires nonempty source paths")
    if len(set(values)) != len(values):
        raise ValueError("Policy source paths must be unique")
    for value in values:
        path = PurePosixPath(value)
        if not value or value == "." or path.as_posix() != value or path.is_absolute() or ".." in path.parts or "\\" in value:
            raise ValueError("Policy source paths must be canonical repository paths")
    return values


def validate_inventory(inventory: dict, roots: list[str]) -> None:
    """Require concrete test discovery minima and executed source probes."""
    if set(inventory) != {"tests", "required_sources"} or not isinstance(inventory["tests"], dict) or not inventory["tests"]:
        raise ValueError("Policy requires explicit nonempty test inventories")
    for label, minimum in inventory["tests"].items():
        if not re.fullmatch(r"//[A-Za-z0-9_./-]*:[A-Za-z0-9_.-]+", label) or type(minimum) is not int or minimum < 1:
            raise ValueError("Invalid test label or minimum discovery count")
    for source in policy_paths(inventory["required_sources"]):
        if not any(source.startswith(root + "/") for root in roots):
            raise ValueError("Required source is outside the declared production roots")


def validate_profile_inventory(entry: dict, roots: list[str], schema: int) -> None:
    """Keep schema-2 components disjoint from the complete unchanged unit set."""
    unit = {key: value for key, value in entry.items() if key != "component_tests"} if schema == 2 else entry
    validate_inventory(unit, roots)
    if schema == 2:
        validate_inventory({"tests": entry.get("component_tests"), "required_sources": entry["required_sources"]}, roots)
        if set(entry["tests"]) & set(entry["component_tests"]):
            raise ValueError("Component inventory cannot replace unit tests or discovery minima")


def load_policy(path: Path, profile: str, inventory: str = "unit") -> dict:
    """Read a consumer-owned, source-fingerprinted inventory, not executable code."""
    contents = path.read_bytes()
    policy = json.loads(contents)
    schema = policy.get("schema")
    fields = {"schema", "scope", "source_roots", "profiles"}
    if schema == 2:
        fields.add("component_scope")
    if (set(policy) != fields or type(schema) is not int or schema not in {1, 2}
            or not isinstance(policy["scope"], str) or not policy["scope"].strip()
            or set(policy["profiles"]) != {"stock", "enhanced"}):
        raise ValueError("Invalid consumer evidence policy")
    if inventory not in {"unit", "unit-cli"} or (inventory == "unit-cli" and schema != 2):
        raise ValueError("Policy does not declare the requested inventory")
    if schema == 2 and (not isinstance(policy["component_scope"], str) or not policy["component_scope"].strip()):
        raise ValueError("Combined inventory requires an explicit scope")
    roots = policy_paths(policy["source_roots"])
    for entry in policy["profiles"].values():
        validate_profile_inventory(entry, roots, schema)
    selected = policy["profiles"][profile]
    tests = dict(selected["tests"])
    if inventory == "unit-cli":
        tests.update(selected["component_tests"])
    return {"tests": tests, "required_sources": selected["required_sources"],
            "inventory": inventory, "source_roots": roots,
            "scope": policy["component_scope"] if inventory == "unit-cli" else policy["scope"],
            "sha256": hashlib.sha256(contents).hexdigest()}


def expected_tests(suite: str, profile: str) -> dict[str, int]:
    """Retain minimum discovery counts for both explicitly selected graphs."""
    if suite == "qualification":
        return EXPECTED
    result = dict(SOURCE_TESTS)
    if profile == "enhanced":
        result["//:DevContainerAppleRuntimeTests"] = 108
    return result


def coverage_counts(text: str) -> tuple[int, int]:
    """Reject an empty or impossible LCOV report instead of accepting zero tests."""
    records = [line.split(":", 1) for line in text.splitlines() if line.startswith(("LF:", "LH:"))]
    found = sum(int(value) for key, value in records if key == "LF")
    hit = sum(int(value) for key, value in records if key == "LH")
    if not 0 < hit <= found:
        raise ValueError("Coverage must contain positive measured and covered line counts")
    return hit, found


def case_count(text: str, minimum: int) -> int:
    """Count actual cases, rejecting failures and skipped discovery probes."""
    root = ET.fromstring(text)
    cases = list(root.iter("testcase"))
    if len(cases) < minimum or any(element.tag in {"failure", "error", "skipped"} for element in root.iter()):
        raise ValueError("Missing, failed or skipped qualification test cases")
    return len(cases)


def require_source_hits(text: str, required: set[str]) -> None:
    """Each mandatory production file must have measured and executed lines."""
    covered = set()
    for record in text.split("end_of_record"):
        sources = [line[3:] for line in record.splitlines() if line.startswith("SF:")]
        if not sources or sources[0] not in required:
            continue
        coverage_counts(record)
        covered.add(sources[0])
    if not required <= covered:
        raise ValueError("Coverage is missing migrated production sources")


def validate(events: list[dict], warm: bool, expected: dict[str, int] | None = None) -> dict:
    """Check exact target results, completion, optional cache reuse, and XML."""
    expected = EXPECTED if expected is None else expected
    finished = [event["finished"] for event in events if "finished" in event]
    if len(finished) != 1 or finished[0]["exitCode"].get("code", 0) != 0:
        raise ValueError("Build did not finish successfully")
    summaries = {event["id"]["testSummary"]["label"]: event["testSummary"] for event in events if "testSummary" in event}
    if set(summaries) != set(expected):
        raise ValueError("Qualification target set is incomplete or unexpected")
    for summary in summaries.values():
        if summary.get("overallStatus") != "PASSED" or summary.get("totalRunCount") != 1:
            raise ValueError("Qualification must pass on its first single attempt")
        if warm and summary.get("totalNumCached") != 1:
            raise ValueError("Warm qualification unexpectedly executed a test")
    counts = {}
    for event in events:
        if "testResult" not in event:
            continue
        label = event["id"]["testResult"]["label"]
        for output in event["testResult"].get("testActionOutput", []):
            if output["name"] != "test.xml":
                continue
            uri = urlparse(output["uri"])
            path = Path(unquote(uri.path)).resolve()
            if uri.scheme != "file" or uri.netloc or not path.is_relative_to("/Volumes/SSD/cf/bazel"):
                raise ValueError("Test evidence must be a local SSD file")
            counts[label] = case_count(path.read_text(), expected[label])
    if set(counts) != set(expected):
        raise ValueError("Missing test XML evidence")
    return {"test_cases": counts, "all_tests_cached": all(s.get("totalNumCached") == 1 for s in summaries.values())}


def require_coverage_logs(events: list[dict]) -> None:
    """Check each executed/cached test's diagnostics before trusting merged data."""
    for event in events:
        if "testResult" not in event:
            continue
        logs = [item for item in event["testResult"].get("testActionOutput", []) if item.get("name") == "test.log"]
        if len(logs) != 1:
            raise ValueError("Coverage requires one diagnostic log per test result")
        uri = urlparse(logs[0]["uri"])
        path = Path(unquote(uri.path)).resolve()
        if uri.scheme != "file" or uri.netloc or not path.is_relative_to("/Volumes/SSD/cf/bazel"):
            raise ValueError("Coverage diagnostics must be a local SSD file")
        with path.open("rb") as incoming:
            contents = incoming.read(128 * 1024**2 + 1)
        if len(contents) > 128 * 1024**2:
            raise ValueError("Coverage diagnostic log exceeds the evidence bound")
        require_clean_coverage_log(contents)


def validate_report(events: list[dict], coverage: Path, suite: str = "qualification", policy: dict | None = None) -> dict:
    """Bind coverage to this invocation and require the migrated source modules."""
    starts = [event["started"] for event in events if "started" in event]
    if len(starts) != 1 or starts[0].get("command") != "coverage":
        raise ValueError("Evidence must come from a coverage invocation")
    require_coverage_logs(events)
    reports = [log for event in events for log in event.get("buildToolLogs", {}).get("log", []) if log.get("name") == "coverage_report.lcov"]
    if len(reports) != 1:
        raise ValueError("Missing unique Bazel combined coverage output")
    uri = urlparse(reports[0]["uri"])
    if uri.scheme != "file" or uri.netloc or Path(unquote(uri.path)).resolve() != coverage.resolve():
        raise ValueError("Coverage path does not match the invocation")
    contents = coverage.read_bytes()
    text = contents.decode("utf-8")
    # DevContainerProject only declares static metadata; LLVM reports LF=0.
    # Require execution in files with executable bodies, not declaration-only files.
    required = {"Sources/DevContainerModel/BuildInfo.swift", "Sources/DevContainerState/SQLiteStateStore.swift", "Tools/version-generator/main.swift"}
    if suite == "source":
        required = {
            "Sources/DevContainerModel/AtomicFile.swift",
            "Sources/DevContainerState/SQLiteStateStore.swift",
            "Sources/DevContainerCore/DevContainerConfiguration.swift",
            "Sources/DevContainerCLI/PluginCommand.swift",
            "Sources/DevContainerService/DevContainerServiceCommand.swift",
            "Sources/DevContainerAppleRuntime/AppleContainerRuntime.swift",
        }
    require_source_hits(text, set(policy["required_sources"]) if policy else required)
    roots = tuple(policy["source_roots"]) if policy else ("Sources", "Tools/version-generator")
    _, hit, found = sonar_xml(contents, roots)
    scope = "qualification subset, not whole project" if suite == "qualification" else "source unit tests; excludes host integration"
    return {"hit": hit, "found": found, "sha256": hashlib.sha256(contents).hexdigest(), "scope": policy["scope"] if policy else scope}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("events", type=Path)
    parser.add_argument("coverage", type=Path, nargs="?", help="Defaults to this invocation's BEP coverage output")
    parser.add_argument("--warm", action="store_true")
    parser.add_argument("--tests-only", action="store_true", help="Validate discovery and results without a coverage claim")
    parser.add_argument("--policy", type=Path, help="Consumer-owned source evidence policy")
    parser.add_argument("--inventory", choices=["unit", "unit-cli"], default="unit")
    parser.add_argument("--suite", choices=["qualification", "source"], default="qualification")
    parser.add_argument("--profile", choices=["stock", "enhanced"], default="enhanced")
    args = parser.parse_args()
    if args.policy and args.suite != "source":
        parser.error("A consumer policy describes only the source suite")
    if args.inventory != "unit" and not args.policy:
        parser.error("Combined coverage requires an explicit consumer policy")
    policy = load_policy(args.policy, args.profile, args.inventory) if args.policy else None
    events = [json.loads(line) for line in args.events.read_text().splitlines()]
    report = validate(events, args.warm, policy["tests"] if policy else expected_tests(args.suite, args.profile))
    report["runtime_profile"] = args.profile
    report["inventory"] = args.inventory
    if policy:
        report["policy_sha256"] = policy["sha256"]
        report["source_roots"] = policy["source_roots"]
    if args.tests_only:
        print(json.dumps(report, indent=2, sort_keys=True))
        return
    coverage = args.coverage
    if coverage is None:
        reports = [log for event in events for log in event.get("buildToolLogs", {}).get("log", []) if log.get("name") == "coverage_report.lcov"]
        if len(reports) != 1:
            raise ValueError("Missing unique Bazel combined coverage output")
        coverage = Path(unquote(urlparse(reports[0]["uri"]).path))
    report["coverage"] = validate_report(events, coverage, args.suite, policy)
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
