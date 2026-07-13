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

"""Verify that upstream pull-request code has immutable Stephen-owned snapshots."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
REPOSITORY_PATTERN = re.compile(r"^stephenlclarke/[A-Za-z0-9_.-]+$")
UPSTREAM_PATTERN = re.compile(r"^apple/[A-Za-z0-9_.-]+#[1-9][0-9]*$")
ARCHIVE_REF_PATTERN = re.compile(r"^refs/heads/upstream-pr-[1-9][0-9]*-[0-9a-f]{12}$")


@dataclass(frozen=True)
class ArchiveEntry:
    """An immutable Stephen-owned copy of one upstream proposal head."""

    upstream: str
    repository: str
    archive_ref: str
    commit: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--ledger",
        type=Path,
        default=Path("docs/upstream/PR-ARCHIVE.json"),
    )
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help="Validate ledger structure without making network calls.",
    )
    return parser.parse_args()


def load_ledger(path: Path) -> list[ArchiveEntry]:
    """Load and strictly validate the committed archive ledger."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise ValueError(f"archive ledger does not exist: {path}") from error
    except json.JSONDecodeError as error:
        raise ValueError(f"archive ledger is invalid JSON: {path}: {error}") from error

    if data.get("schemaVersion") != 1:
        raise ValueError("archive ledger schemaVersion must be 1")
    raw_entries = data.get("pullRequests")
    if not isinstance(raw_entries, list) or not raw_entries:
        raise ValueError("archive ledger pullRequests must be a non-empty list")

    entries: list[ArchiveEntry] = []
    refs: set[tuple[str, str]] = set()
    upstreams: set[str] = set()
    for raw in raw_entries:
        if not isinstance(raw, dict):
            raise ValueError("archive ledger entries must be objects")
        try:
            entry = ArchiveEntry(
                upstream=raw["upstream"],
                repository=raw["repository"],
                archive_ref=raw["archiveRef"],
                commit=raw["commit"],
            )
        except KeyError as error:
            raise ValueError(f"archive ledger entry is missing {error.args[0]}") from error
        if not UPSTREAM_PATTERN.fullmatch(entry.upstream):
            raise ValueError(f"invalid upstream pull request: {entry.upstream}")
        if not REPOSITORY_PATTERN.fullmatch(entry.repository):
            raise ValueError(f"archive repository must be Stephen-owned: {entry.repository}")
        if not ARCHIVE_REF_PATTERN.fullmatch(entry.archive_ref):
            raise ValueError(f"invalid immutable archive ref: {entry.archive_ref}")
        if not COMMIT_PATTERN.fullmatch(entry.commit):
            raise ValueError(f"invalid full commit SHA: {entry.commit}")
        key = (entry.repository, entry.archive_ref)
        if key in refs:
            raise ValueError(f"duplicate archive ref: {entry.repository} {entry.archive_ref}")
        if entry.upstream in upstreams:
            raise ValueError(f"duplicate upstream pull request: {entry.upstream}")
        refs.add(key)
        upstreams.add(entry.upstream)
        entries.append(entry)
    return entries


def remote_ref(repository: str, archive_ref: str) -> str | None:
    """Resolve one remote archive ref without trusting a local clone."""
    result = subprocess.run(
        ["git", "ls-remote", "--heads", f"https://github.com/{repository}.git", archive_ref],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"cannot reach {repository}: {result.stderr.strip()}")
    fields = result.stdout.strip().split()
    return fields[0] if fields else None


def verify(entries: list[ArchiveEntry]) -> list[str]:
    """Return all archive discrepancies so a repair is actionable in one run."""
    errors: list[str] = []
    for entry in entries:
        actual = remote_ref(entry.repository, entry.archive_ref)
        if actual is None:
            errors.append(
                f"missing archive: {entry.upstream} -> {entry.repository} {entry.archive_ref}"
            )
        elif actual != entry.commit:
            errors.append(
                f"archive moved: {entry.upstream} -> {entry.repository} {entry.archive_ref} "
                f"is {actual}, expected {entry.commit}"
            )
        else:
            print(f"verified {entry.upstream}: {entry.repository} {entry.archive_ref}")
    return errors


def main() -> int:
    args = parse_args()
    try:
        entries = load_ledger(args.ledger)
        if args.validate_only:
            print(f"validated {len(entries)} upstream PR archive entries")
            return 0
        errors = verify(entries)
    except (ValueError, RuntimeError) as error:
        print(error, file=sys.stderr)
        return 1

    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
