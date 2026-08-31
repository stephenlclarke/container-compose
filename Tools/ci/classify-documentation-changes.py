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

"""Classify whether a repository change can affect generated documentation.

The classifier intentionally avoids compiling the package. It compares a
conservative fingerprint of documented Swift declarations and separately
tracks every non-source input consumed by the DocC workflow. Unsupported or
ambiguous Swift syntax requests a DocC build rather than risking stale pages.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path


DOCUMENTATION_INPUTS = (
    ".github/workflows/docs.yml",
    ".swift-version",
    "Package.resolved",
    "Package.swift",
    "scripts/make-docs.sh",
)
REPOSITORY_DOCUMENTATION = re.compile(r"^docs/")
SWIFT_SOURCE = re.compile(r"^Sources/.+[.]swift$")
NON_SWIFT_API_SOURCE = re.compile(r"^Sources/.+[.](?:h|hpp|modulemap)$")
ATTRIBUTE_PREFIX = r"(?:(?:@\w+(?:\([^\n]*\))?)\s+)*"
DECLARATION_MODIFIER = (
    r"(?:__consuming|borrowing|class|consuming|convenience|distributed|dynamic|"
    r"final|indirect|infix|isolated|lazy|"
    r"mutating|nonisolated(?:\(unsafe\))?|nonmutating|optional|override|postfix|"
    r"prefix|required|sending|static|unowned(?:\(safe\)|\(unsafe\))?|weak)"
)
SETTER_ACCESS = r"(?:private|fileprivate|internal|package|public)\(set\)"
DECLARATION_KIND = (
    r"(?:actor|associatedtype|class|enum|extension|func|import|init|let|macro|"
    r"operator|precedencegroup|protocol|struct|subscript|typealias|var)"
)
ACCESS_DECLARATION = re.compile(
    rf"^\s*{ATTRIBUTE_PREFIX}(?:{DECLARATION_MODIFIER}\s+)*"
    rf"(?:public|open|package)\s+(?:(?:{DECLARATION_MODIFIER}|{SETTER_ACCESS})\s+)*"
    rf"{DECLARATION_KIND}\b"
)
PUBLIC_CONTAINER = re.compile(
    rf"^\s*{ATTRIBUTE_PREFIX}(?:{DECLARATION_MODIFIER}\s+)*"
    rf"(?:public|open|package)\s+(?:{DECLARATION_MODIFIER}\s+)*"
    r"(enum|extension|protocol)\b"
)
PROTOCOL_MEMBER = re.compile(
    rf"^\s*{ATTRIBUTE_PREFIX}(?:(?:{DECLARATION_MODIFIER}|{SETTER_ACCESS})\s+)*"
    r"(?:associatedtype|func|init|let|macro|operator|subscript|typealias|var)\b"
)
ENUM_CASE = re.compile(rf"^\s*{ATTRIBUTE_PREFIX}(?:indirect\s+)?case\b")
DOC_COMMENT = re.compile(r"^\s*(?:///|/\*\*|\*)")
ATTRIBUTE = re.compile(r"^\s*@")
MACRO_IMPLEMENTATION = re.compile(r"#externalMacro\b")


class AmbiguousSwiftSource(ValueError):
    """Raised when the source cannot be classified without a compiler."""


@dataclass(frozen=True)
class Classification:
    build_docc: bool
    reason: str
    changed_files: tuple[str, ...]
    base_api_fingerprint: str | None = None
    head_api_fingerprint: str | None = None

    def as_json(self) -> str:
        return json.dumps(
            {
                "build_docc": self.build_docc,
                "reason": self.reason,
                "changed_files": list(self.changed_files),
                "base_api_fingerprint": self.base_api_fingerprint,
                "head_api_fingerprint": self.head_api_fingerprint,
            },
            sort_keys=True,
        )


def run_git(repository: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repository), *arguments],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return result.stdout


def changed_files(repository: Path, base: str, head: str) -> tuple[str, ...]:
    output = run_git(repository, "diff", "--name-only", "--diff-filter=ACDMRTUXB", base, head)
    return tuple(line for line in output.splitlines() if line)


def source_at(repository: Path, revision: str, path: str) -> str | None:
    result = subprocess.run(
        ["git", "-C", str(repository), "show", f"{revision}:{path}"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode == 0:
        return result.stdout
    return None


def _brace_delta(line: str) -> int:
    """Count structural braces after removing strings and line comments."""

    scrubbed = re.sub(r'"(?:\\.|[^"\\])*"', '""', line)
    scrubbed = scrubbed.split("//", 1)[0]
    return scrubbed.count("{") - scrubbed.count("}")


def _declaration_header(lines: list[str], start: int) -> tuple[str, int, int]:
    """Return a normalized declaration header, end line, and opening braces."""

    pieces: list[str] = []
    declaration_start = lines[start].strip()
    parens = 0
    brackets = 0
    angles = 0
    opening_braces = 0
    for index in range(start, min(len(lines), start + 80)):
        line = lines[index]
        pieces.append(line.strip())
        scrubbed = re.sub(r'"(?:\\.|[^"\\])*"', '""', line)
        scrubbed = scrubbed.split("//", 1)[0]
        for character in scrubbed:
            if character == "(":
                parens += 1
            elif character == ")":
                parens -= 1
            elif character == "[":
                brackets += 1
            elif character == "]":
                brackets -= 1
            elif character == "<":
                angles += 1
            elif character == ">" and angles:
                angles -= 1
            elif character == "{" and parens == 0 and brackets == 0:
                opening_braces += 1
                prefix = scrubbed.split("{", 1)[0].strip()
                pieces[-1] = prefix
                return " ".join(piece for piece in pieces if piece), index, opening_braces
        if parens < 0 or brackets < 0:
            raise AmbiguousSwiftSource("unbalanced declaration delimiters")
        if parens == 0 and brackets == 0:
            stripped = scrubbed.strip()
            if ENUM_CASE.match(declaration_start):
                return " ".join(piece for piece in pieces if piece), index, opening_braces
            if re.search(
                r"\b(?:typealias|associatedtype|import|operator|precedencegroup)\b",
                declaration_start,
            ):
                return " ".join(piece for piece in pieces if piece), index, opening_braces
            if re.search(r"\b(?:let|var)\b", declaration_start):
                if "=" in stripped:
                    pieces[-1] = stripped.split("=", 1)[0].strip()
                return " ".join(piece for piece in pieces if piece), index, opening_braces
            if re.search(
                r"\b(?:func|init|macro|subscript)\b", declaration_start
            ) and not stripped.endswith(
                ("(", ",", "->", "where")
            ):
                next_line = lines[index + 1].strip() if index + 1 < len(lines) else ""
                if not re.match(r"^(?:async|throws|rethrows|where|->)\b", next_line):
                    return " ".join(piece for piece in pieces if piece), index, opening_braces
            if stripped.endswith((")", "get", "set")):
                return " ".join(piece for piece in pieces if piece), index, opening_braces
    raise AmbiguousSwiftSource("declaration header exceeded classifier boundary")


def documented_api(source: str) -> str:
    """Extract a stable, conservative representation of documented Swift API."""

    lines = source.splitlines()
    if MACRO_IMPLEMENTATION.search(source):
        raise AmbiguousSwiftSource("macro implementation requires symbol extraction")
    records: list[str] = []
    pending: list[str] = []
    brace_depth = 0
    implicit_containers: list[tuple[int, str]] = []
    index = 0

    while index < len(lines):
        line = lines[index]
        stripped = line.strip()
        while implicit_containers and brace_depth < implicit_containers[-1][0]:
            implicit_containers.pop()

        if DOC_COMMENT.match(line) or ATTRIBUTE.match(line):
            pending.append(stripped)
            brace_depth += _brace_delta(line)
            index += 1
            continue

        container_kind = implicit_containers[-1][1] if implicit_containers else None
        implicit_member = (
            container_kind in {"extension", "protocol"} and PROTOCOL_MEMBER.match(line)
        ) or (container_kind == "enum" and ENUM_CASE.match(line))
        declaration = ACCESS_DECLARATION.match(line) or implicit_member
        if declaration:
            header, end, opening_braces = _declaration_header(lines, index)
            records.extend(pending)
            pending.clear()
            records.append(re.sub(r"\s+", " ", header).strip())
            container = PUBLIC_CONTAINER.match(line)
            if container and opening_braces:
                opening_line = lines[end]
                contents_after_brace = opening_line.split("{", 1)[1].strip()
                if contents_after_brace and contents_after_brace != "}":
                    raise AmbiguousSwiftSource(
                        "single-line public container requires symbol extraction"
                    )
            for consumed in range(index, end + 1):
                brace_depth += _brace_delta(lines[consumed])
            if container and opening_braces:
                implicit_containers.append((brace_depth, container.group(1)))
            index = end + 1
            continue

        pending.clear()
        brace_depth += _brace_delta(line)
        if brace_depth < 0:
            raise AmbiguousSwiftSource("unbalanced source braces")
        index += 1

    if brace_depth != 0:
        raise AmbiguousSwiftSource("unbalanced source braces")
    return "\n".join(records) + "\n"


def api_fingerprint(repository: Path, revision: str) -> str:
    paths = run_git(repository, "ls-tree", "-r", "--name-only", revision, "--", "Sources")
    digest = hashlib.sha256()
    for path in sorted(line for line in paths.splitlines() if SWIFT_SOURCE.match(line)):
        source = source_at(repository, revision, path)
        if source is None:
            raise AmbiguousSwiftSource(f"could not read {path} at {revision}")
        digest.update(path.encode("utf-8"))
        digest.update(b"\0")
        digest.update(documented_api(source).encode("utf-8"))
        digest.update(b"\0")
    return digest.hexdigest()


def classify(repository: Path, base: str, head: str) -> Classification:
    changes = changed_files(repository, base, head)
    if not changes:
        return Classification(False, "no changed files", changes)
    if all(REPOSITORY_DOCUMENTATION.match(path) for path in changes):
        return Classification(
            False, "repository documentation does not feed DocC", changes
        )
    if any(path in DOCUMENTATION_INPUTS for path in changes):
        return Classification(True, "documentation input changed", changes)
    if any(NON_SWIFT_API_SOURCE.match(path) for path in changes):
        return Classification(True, "non-Swift API source changed", changes)
    if not any(path.startswith("Sources/") for path in changes):
        return Classification(False, "no documentation or source input changed", changes)
    if any(path.startswith("Sources/") and not SWIFT_SOURCE.match(path) for path in changes):
        return Classification(True, "ambiguous source input changed", changes)

    try:
        base_fingerprint = api_fingerprint(repository, base)
        head_fingerprint = api_fingerprint(repository, head)
    except AmbiguousSwiftSource as error:
        return Classification(True, f"ambiguous Swift API: {error}", changes)
    return Classification(
        base_fingerprint != head_fingerprint,
        "documented Swift API changed"
        if base_fingerprint != head_fingerprint
        else "implementation-only Swift change",
        changes,
        base_fingerprint,
        head_fingerprint,
    )


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=Path.cwd())
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--github-output", type=Path)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    result = classify(arguments.repository.resolve(), arguments.base, arguments.head)
    print(result.as_json())
    if arguments.github_output:
        with arguments.github_output.open("a", encoding="utf-8") as output:
            output.write(f"build_docc={'true' if result.build_docc else 'false'}\n")
            output.write(f"reason={result.reason}\n")
            output.write(f"base_api_fingerprint={result.base_api_fingerprint or ''}\n")
            output.write(f"head_api_fingerprint={result.head_api_fingerprint or ''}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
