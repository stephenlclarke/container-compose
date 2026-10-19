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

"""Export retained native coverage without invoking Bazel or rerunning tests."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path, PurePosixPath
import re
import sqlite3
import tempfile
import xml.etree.ElementTree as ET

from input_identity import verify
from retain_evidence import digest


def require_clean_coverage_log(content: bytes) -> None:
    """Reject known collector failures even when Bazel reports test success."""
    if b"WARNING: Tracefile" in content or b"ERROR: Tracefile" in content:
        raise ValueError("Coverage merger rejected tracefile data; report is not authoritative")
    # Bazel 8's optional C collector does not propagate its failing status.
    # Match coverage-specific diagnostics, not intentional CLI error fixtures.
    failures = (
        rb"^(?:[^\n]*/)?collect_cc_coverage\.sh: line [0-9]+:",
        rb"^LLVM Profile Error:",
        rb"^(?:llvm-cov: )?error: Failed to load (?:coverage|profile)",
        rb"^(?:llvm-(?:cov|profdata): )?(?:error|warning): [^\n]*(?:malformed|invalid|unsupported) instrumentation profile",
        rb"^(?:llvm-cov: )?warning: [0-9]+ functions? have mismatched data",
    )
    if any(re.search(pattern, content, re.MULTILINE) for pattern in failures):
        raise ValueError("Coverage collector failed; report is not authoritative")


def retained_log_names(events: list[dict], expected: set[str]) -> set[str]:
    """Bind each retained diagnostic to the authenticated test-result inventory."""
    names, labels = set(), set()
    for event in events:
        if "testResult" not in event:
            continue
        identity = event["id"]["testResult"]
        label = identity["label"]
        outputs = [item for item in event["testResult"].get("testActionOutput", [])
                   if item.get("name") == "test.log"]
        name = f"{label}:{json.dumps(identity, sort_keys=True)}:test.log"
        if len(outputs) != 1 or label in labels:
            raise ValueError("Coverage requires one diagnostic log per test result")
        labels.add(label)
        names.add(name)
    if not expected or labels != expected:
        raise ValueError("Coverage diagnostic inventory does not match validated tests")
    return names


def sonar_xml(lcov: bytes, source_roots: tuple[str, ...] = ("Sources",)) -> tuple[bytes, int, int]:
    """Convert the exact first-party LCOV line denominator, without exclusions."""
    files = {}
    for record in lcov.decode("utf-8").split("end_of_record"):
        rows = record.strip().splitlines()
        if not rows:
            continue
        sources = [row[3:] for row in rows if row.startswith("SF:")]
        if len(sources) != 1:
            raise ValueError("Coverage record needs exactly one source")
        source = sources[0]
        path = PurePosixPath(source)
        if (not any(source.startswith(root + "/") for root in source_roots) or path.as_posix() != source
                or ".." in path.parts or "\\" in source or source in files):
            raise ValueError("Coverage source is duplicate or outside the maintained source tree")
        lines = {}
        for row in rows:
            if not row.startswith("DA:"):
                continue
            fields = row[3:].split(",")
            if len(fields) not in {2, 3} or not all(re.fullmatch(r"[0-9]+", field) for field in fields[:2]):
                raise ValueError("Invalid LCOV line counts")
            line, hits = map(int, fields[:2])
            if line <= 0 or line in lines or hits > 2**63 - 1:
                raise ValueError("Invalid or duplicate LCOV line")
            lines[line] = hits
        found = [row[3:] for row in rows if row.startswith("LF:")]
        hit = [row[3:] for row in rows if row.startswith("LH:")]
        if found != [str(len(lines))] or hit != [str(sum(count > 0 for count in lines.values()))]:
            raise ValueError("LCOV summary disagrees with measured lines")
        files[source] = lines
    root = ET.Element("coverage", {"version": "1"})
    total, covered = 0, 0
    for source, lines in sorted(files.items()):
        if not lines:
            continue
        element = ET.SubElement(root, "file", {"path": source})
        for line, hits in sorted(lines.items()):
            ET.SubElement(element, "lineToCover", {
                "lineNumber": str(line), "covered": "true" if hits > 0 else "false",
            })
            total += 1
            covered += hits > 0
    if not 0 < covered <= total:
        raise ValueError("Empty or unexecuted coverage")
    ET.indent(root)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True), covered, total


def report_bytes(database: Path, invocation: str) -> dict[str, bytes]:
    """Read only authenticated coverage/provenance, never raw event environments."""
    if database.is_symlink() or not database.is_file():
        raise ValueError("Missing or symlinked evidence database")
    with sqlite3.connect(f"{database.as_uri()}?mode=ro", uri=True) as db:
        row = db.execute("SELECT manifest, exit_code FROM invocations WHERE id=?", (invocation,)).fetchone()
        if row is None or row[1] != 0:
            raise ValueError("Coverage requires a successful retained invocation")
        manifest = json.loads(row[0])

        def read(name: str) -> bytes:
            expected = manifest.get(name)
            blob = db.execute("SELECT bytes FROM blobs WHERE sha256=?", (expected,)).fetchone()
            if blob is None or digest(blob[0]) != expected:
                raise ValueError("Missing or corrupt retained coverage evidence")
            return blob[0]

        before = json.loads(read("inputs-before.json"))
        after = json.loads(read("inputs-after.json"))
        verify(before, after)
        if (before.get("dirty") is not False or after.get("dirty") is not False
                or not re.fullmatch(r"[0-9a-f]{40}", before.get("commit", ""))):
            raise ValueError("Coverage export requires clean recorded source identity")
        outcome = json.loads(read("outcome.json"))
        if outcome != {"bazel_exit_code": 0, "validation_exit_code": 0, "suite": "source"}:
            raise ValueError("Coverage needs a validated complete source inventory")
        report = json.loads(read("source-tests.json"))
        events = [json.loads(line) for line in read("events.json").splitlines()]
        logs = retained_log_names(events, set(report["test_cases"]))
        if logs != {name for name in manifest if name.endswith(":test.log")}:
            raise ValueError("Missing or unexpected retained coverage diagnostic log")
        for name in logs:
            require_clean_coverage_log(read(name))
        lcov = read("build:build:coverage_report.lcov")
        roots = ("Sources",)
        if "policy_sha256" in report:
            policy_identity = before["files"].get("Tools/bazel/evidence-policy.json", {})
            if report["policy_sha256"] != policy_identity.get("sha256"):
                raise ValueError("Coverage policy differs from the recorded source identity")
            roots = tuple(report["source_roots"])
        xml, covered, total = sonar_xml(lcov, roots)
        counts = report["coverage"]
        if (counts["sha256"] != digest(lcov) or counts["hit"] != covered or counts["found"] != total
                or report.get("runtime_profile") not in {"stock", "enhanced"}):
            raise ValueError("Coverage does not match the validated invocation")
    receipt = {
        "schema": 1, "invocation": invocation, "sourceCommit": before["commit"],
        "runtimeProfile": report["runtime_profile"], "scope": counts["scope"],
        "sourceIdentitySHA256": digest(json.dumps(before, sort_keys=True).encode()),
        "lcovSHA256": digest(lcov), "sonarXMLSHA256": digest(xml),
        "coveredLines": covered, "measuredLines": total,
        "percent": round(100 * covered / total, 4), "releaseAuthority": False,
    }
    if "policy_sha256" in report:
        receipt["policySHA256"] = report["policy_sha256"]
    # Preserve byte-identical export of historical unit receipts.
    if "inventory" in report:
        if report["inventory"] not in {"unit", "unit-cli"} or (report["inventory"] == "unit-cli" and "policy_sha256" not in report):
            raise ValueError("Invalid coverage inventory")
        receipt["inventory"] = report["inventory"]
    return {"coverage.lcov": lcov, "coverage.xml": xml,
            "receipt.json": (json.dumps(receipt, indent=2, sort_keys=True) + "\n").encode()}


def require_minimum(receipt: dict, minimum: float) -> None:
    """A quality gate uses raw counts, never a rounded display percentage."""
    if not 0 <= minimum <= 100:
        raise ValueError("Coverage minimum must be between 0 and 100")
    if receipt["coveredLines"] * 100 < minimum * receipt["measuredLines"]:
        raise ValueError(f"Measured coverage {receipt['percent']:.4f}% is below {minimum:g}%")


def require_context(receipt: dict, commit: str, profile: str, policy: Path | None, inventory: str = "unit") -> None:
    """A requested quality gate must match the selected consumer and source head."""
    if receipt["sourceCommit"] != commit or receipt["runtimeProfile"] != profile:
        raise ValueError("Coverage does not match the requested source commit and runtime profile")
    expected = digest(policy.read_bytes()) if policy else None
    if receipt.get("policySHA256") != expected:
        raise ValueError("Coverage does not match the requested consumer policy")
    if inventory not in {"unit", "unit-cli"} or receipt.get("inventory", "unit") != inventory:
        raise ValueError("Coverage does not match the requested test inventory")


def export(database: Path, invocation: str, scratch: Path) -> Path:
    """Publish or reuse an exact disposable report from durable input bytes."""
    contents = report_bytes(database, invocation)
    parent = scratch / "coverage"
    parent.mkdir(exist_ok=True)
    if parent.resolve() != parent:
        raise ValueError("Refusing symlinked coverage destination")
    destination = parent / digest(invocation.encode())
    if destination.exists() or destination.is_symlink():
        if destination.is_symlink() or not destination.is_dir() or {p.name for p in destination.iterdir()} != set(contents):
            raise ValueError("Conflicting coverage destination")
        for name, data in contents.items():
            path = destination / name
            if path.is_symlink() or not path.is_file() or path.read_bytes() != data:
                raise ValueError("Conflicting exported coverage bytes")
        return destination
    with tempfile.TemporaryDirectory(dir=scratch / "tmp", prefix="coverage-") as temporary:
        stage = Path(temporary) / "report"
        stage.mkdir(mode=0o700)
        for name, data in contents.items():
            (stage / name).write_bytes(data)
        stage.rename(destination)
    return destination


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("invocation")
    parser.add_argument("--minimum-percent", type=float, default=0)
    parser.add_argument("--expected-commit")
    parser.add_argument("--expected-profile", choices=["stock", "enhanced"])
    parser.add_argument("--expected-policy", type=Path)
    parser.add_argument("--expected-inventory", choices=["unit", "unit-cli"], default="unit")
    args = parser.parse_args()
    root = Path.home() / "Library/Application Support/ContainerFamily/retained/container-compose"
    if root.resolve() != root or root.stat().st_dev != Path.home().stat().st_dev:
        raise ValueError("Evidence must be on non-symlinked internal storage")
    os.umask(0o077)
    destination = export(root / "bazel-evidence.sqlite", args.invocation, Path("/Volumes/SSD/cf/bazel"))
    print(destination, flush=True)
    receipt = json.loads((destination / "receipt.json").read_bytes())
    if args.expected_commit or args.expected_profile or args.expected_policy:
        if not args.expected_commit or not args.expected_profile:
            parser.error("Expected source commit and runtime profile must be supplied together")
        require_context(receipt, args.expected_commit, args.expected_profile, args.expected_policy, args.expected_inventory)
    require_minimum(receipt, args.minimum_percent)


if __name__ == "__main__":
    main()
