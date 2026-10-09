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

"""Retain exact-source Swift coverage and union the two shipping profiles."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET

PROFILES = ("enhanced", "stock")
RUNTIMES = {"enhanced": "Sources/ComposeContainerRuntime/",
            "stock": "Sources/ComposeEngineRuntime/"}
SCOPES = {"core": "Sources/ComposeCore/", "runtime-spi": "Sources/ComposeRuntimeSPI/",
          "provider": RUNTIMES["enhanced"], "plugin": "Sources/ComposePlugin/",
          "aggregate": "Sources/"}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(root: Path, *arguments: str) -> str:
    return subprocess.check_output(["git", "-C", str(root), *arguments],
                                   text=True, timeout=30).strip()


def source_identity(root: Path, sha: str) -> dict[str, str]:
    """Reject a different checkout or any tracked source change between lanes."""
    if (not re.fullmatch(r"[0-9a-f]{40}", sha) or git(root, "rev-parse", "HEAD") != sha
            or git(root, "status", "--porcelain", "--untracked-files=no")):
        raise ValueError("Coverage requires the exact clean source SHA")
    files = [path for path in git(root, "ls-files", "Sources").splitlines()
             if path.endswith(".swift")]
    if not files:
        raise ValueError("Coverage source inventory is empty")
    return {path: digest(root / path) for path in files}


def read_coverage(path: Path, sources: dict[str, str], root: Path) -> dict[str, dict[int, bool]]:
    """Read only first-party line observations, retaining uncovered lines."""
    document = ET.parse(path).getroot()
    if document.tag != "coverage" or document.get("version") != "1":
        raise ValueError("Expected Sonar generic line coverage version 1")
    files: dict[str, dict[int, bool]] = {}
    for element in document:
        name = element.get("path", "")
        if element.tag != "file" or name not in sources or name in files:
            raise ValueError("Unexpected or duplicate coverage source: " + name)
        source_lines = len((root / name).read_bytes().splitlines())
        lines: dict[int, bool] = {}
        for line in element:
            number = int(line.get("lineNumber", "0"))
            covered = line.get("covered")
            if (line.tag != "lineToCover" or not 0 < number <= source_lines or number in lines
                    or covered not in ("true", "false")):
                raise ValueError("Invalid or duplicate line coverage: " + name)
            lines[number] = covered == "true"
        files[name] = lines
    if not any(files.values()):
        raise ValueError("Coverage has no executable lines")
    return files


def require_runtime(files: dict[str, dict[int, bool]], profile: str) -> None:
    """Do not admit an enhanced-only report as stock runtime coverage."""
    prefix = RUNTIMES[profile]
    if not any(covered for name, lines in files.items() if name.startswith(prefix)
               for covered in lines.values()):
        raise ValueError("No executed runtime lines for profile " + profile)
    other = RUNTIMES["stock" if profile == "enhanced" else "enhanced"]
    if any(lines for name, lines in files.items() if name.startswith(other)):
        raise ValueError("Coverage contains the other profile's runtime")


def write_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


def capture(root: Path, sha: str, profile: str, output: Path) -> dict:
    sources = source_identity(root, sha)
    report = root / "coverage.xml"
    files = read_coverage(report, sources, root)
    require_runtime(files, profile)
    output.mkdir(parents=True, exist_ok=False)
    shutil.copyfile(report, output / "coverage.xml")
    receipt = {"schema": 1, "source_sha": sha, "profile": profile,
               "source_files": sources, "coverage_sha256": digest(output / "coverage.xml")}
    write_json(output / "receipt.json", receipt)
    return receipt


def write_coverage(path: Path, files: dict[str, dict[int, bool]]) -> None:
    document = ET.Element("coverage", version="1")
    for name, lines in sorted(files.items()):
        element = ET.SubElement(document, "file", path=name)
        for number, covered in sorted(lines.items()):
            ET.SubElement(element, "lineToCover", lineNumber=str(number),
                          covered=str(covered).lower())
    tree = ET.ElementTree(document)
    ET.indent(tree, space="  ")
    tree.write(path, encoding="utf-8", xml_declaration=True)


def merge(root: Path, sha: str, inputs: Path, output: Path) -> dict:
    sources = source_identity(root, sha)
    merged: dict[str, dict[int, bool]] = {}
    records = {}
    for profile in PROFILES:
        directory = inputs / profile
        receipt = json.loads((directory / "receipt.json").read_text())
        report = directory / "coverage.xml"
        if (receipt.get("schema") != 1 or receipt.get("source_sha") != sha
                or receipt.get("profile") != profile or receipt.get("source_files") != sources
                or receipt.get("coverage_sha256") != digest(report)):
            raise ValueError("Coverage profile source/report identity differs: " + profile)
        files = read_coverage(report, sources, root)
        require_runtime(files, profile)
        for name, lines in files.items():
            current = merged.setdefault(name, {})
            for number, covered in lines.items():
                current[number] = current.get(number, False) or covered
        records[profile] = {"receipt_sha256": digest(directory / "receipt.json"),
                            "coverage_sha256": digest(report)}
    output.mkdir(parents=True, exist_ok=True)
    for scope, prefix in SCOPES.items():
        files = {name: lines for name, lines in merged.items() if name.startswith(prefix)}
        write_coverage(output / f"coverage-{scope}.xml", files)
    shutil.copyfile(output / "coverage-aggregate.xml", output / "coverage.xml")
    result = {"schema": 1, "kind": "stock-and-enhanced-line-union", "source_sha": sha,
              "profiles": list(PROFILES), "profile_inputs": records,
              "coverage_sha256": digest(output / "coverage.xml")}
    write_json(output / "profile-union.json", result)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("capture", "merge"))
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--profile", choices=PROFILES)
    parser.add_argument("--inputs", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "capture":
        if args.profile is None:
            parser.error("capture requires --profile")
        capture(args.root.resolve(), args.source_sha, args.profile, args.output)
    else:
        if args.inputs is None:
            parser.error("merge requires --inputs")
        merge(args.root.resolve(), args.source_sha, args.inputs, args.output)


if __name__ == "__main__":
    main()
