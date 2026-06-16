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
"""Convert LCOV line coverage into SonarQube generic coverage XML."""

import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def usage() -> None:
    """Print command usage for invalid invocations."""
    print("usage: lcov-to-sonarqube-generic.py <input.lcov> <output.xml> [project-root]", file=sys.stderr)


def relative_path(path: str, root: Path) -> str:
    """Return a Sonar-friendly path relative to the project when possible."""
    source = Path(path)
    if source.is_absolute():
        try:
            return source.resolve().relative_to(root).as_posix()
        except ValueError:
            return source.as_posix()
    return source.as_posix()


def parse_lcov(path: Path, root: Path) -> dict[str, dict[int, bool]]:
    """Parse LCOV records into per-file covered line maps."""
    files: dict[str, dict[int, bool]] = {}
    current: str | None = None

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if line.startswith("SF:"):
            current = relative_path(line[3:], root)
            files.setdefault(current, {})
            continue
        if line.startswith("DA:") and current is not None:
            line_number_text, count_text, *_ = line[3:].split(",")
            files[current][int(line_number_text)] = int(count_text) > 0
            continue
        if line == "end_of_record":
            current = None

    return files


def write_generic_coverage(files: dict[str, dict[int, bool]], output: Path) -> None:
    """Write SonarQube generic coverage XML from parsed line coverage."""
    coverage = ET.Element("coverage", version="1")
    for file_path in sorted(files):
        file_element = ET.SubElement(coverage, "file", path=file_path)
        for line_number in sorted(files[file_path]):
            ET.SubElement(
                file_element,
                "lineToCover",
                lineNumber=str(line_number),
                covered=str(files[file_path][line_number]).lower(),
            )

    tree = ET.ElementTree(coverage)
    ET.indent(tree, space="  ")
    tree.write(output, encoding="utf-8", xml_declaration=True)


def main() -> int:
    """Convert the input LCOV file to SonarQube generic coverage XML."""
    if len(sys.argv) not in (3, 4):
        usage()
        return 2

    input_path = Path(sys.argv[1])
    output_path = Path(sys.argv[2])
    root = Path(sys.argv[3] if len(sys.argv) == 4 else ".").resolve()
    files = parse_lcov(input_path, root)
    write_generic_coverage(files, output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
