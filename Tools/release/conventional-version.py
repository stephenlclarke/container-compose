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

"""Resolve the next stable version from Conventional Commits."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence


SEMVER = re.compile(r"(?P<major>0|[1-9][0-9]*)[.](?P<minor>0|[1-9][0-9]*)[.](?P<patch>0|[1-9][0-9]*)")
CONVENTIONAL_SUBJECT = re.compile(
    r"(?P<type>[a-z][a-z0-9-]*)(?:[(][^)\r\n]+[)])?(?P<breaking>!)?: (?P<description>\S.*)"
)
BREAKING_FOOTER = re.compile(r"^BREAKING(?:[ -]CHANGE)?:\s*\S", re.MULTILINE)
PATCH_TYPES = frozenset(("fix", "perf", "revert"))


class VersionError(RuntimeError):
    """Raised when release history cannot produce a safe version."""


@dataclass(frozen=True, order=True)
class Version:
    major: int
    minor: int
    patch: int

    @classmethod
    def parse(cls, value: str) -> Version:
        match = SEMVER.fullmatch(value)
        if match is None:
            raise VersionError(f"version is not bare semantic versioning: {value}")
        return cls(*(int(match.group(name)) for name in ("major", "minor", "patch")))

    def bump(self, level: str) -> Version:
        if level == "major":
            return Version(self.major + 1, 0, 0)
        if level == "minor":
            return Version(self.major, self.minor + 1, 0)
        if level == "patch":
            return Version(self.major, self.minor, self.patch + 1)
        raise VersionError("no release-producing Conventional Commit exists")

    def __str__(self) -> str:
        return f"{self.major}.{self.minor}.{self.patch}"


@dataclass(frozen=True)
class Commit:
    object_id: str
    subject: str
    body: str


def checked_git(repository: Path, *arguments: str) -> str:
    completed = subprocess.run(
        ["/usr/bin/git", "-C", str(repository), *arguments],
        check=False,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        diagnostic = completed.stderr.strip() or "unknown Git failure"
        raise VersionError(f"could not inspect release history: {diagnostic}")
    return completed.stdout


def latest_tag(repository: Path) -> str | None:
    tags = checked_git(
        repository,
        "tag",
        "--merged",
        "HEAD",
        "--sort=-version:refname",
        "--format=%(refname:strip=2)",
    ).splitlines()
    return next((tag for tag in tags if SEMVER.fullmatch(tag)), None)


def commits_since(repository: Path, tag: str | None) -> tuple[Commit, ...]:
    revision = f"{tag}..HEAD" if tag else "HEAD"
    field_separator = "%x1f"
    record_separator = "%x1e"
    output = checked_git(
        repository,
        "log",
        "--first-parent",
        f"--format=%H{field_separator}%s{field_separator}%b{record_separator}",
        revision,
    )
    commits: list[Commit] = []
    for record in output.split("\x1e"):
        record = record.strip("\n")
        if not record:
            continue
        fields = record.split("\x1f", 2)
        if len(fields) != 3:
            raise VersionError("Git returned malformed commit metadata")
        commits.append(Commit(fields[0], fields[1], fields[2].rstrip("\n")))
    return tuple(commits)


def commit_level(commit: Commit) -> str | None:
    subject = commit.subject
    body = commit.body
    if subject.startswith("Merge pull request "):
        body_lines = body.splitlines()
        if not body_lines:
            return None
        subject = body_lines[0]
        body = "\n".join(body_lines[1:])
    match = CONVENTIONAL_SUBJECT.fullmatch(subject)
    if match is None:
        raise VersionError(
            f"commit {commit.object_id[:12]} is not Conventional Commits compliant: "
            f"{subject}"
        )
    if match.group("breaking") or BREAKING_FOOTER.search(body):
        return "major"
    if match.group("type") == "feat":
        return "minor"
    if match.group("type") in PATCH_TYPES:
        return "patch"
    return None


def release_level(commits: Sequence[Commit]) -> str:
    levels = {level for commit in commits if (level := commit_level(commit)) is not None}
    for level in ("major", "minor", "patch"):
        if level in levels:
            return level
    raise VersionError("no release-producing Conventional Commit exists since the latest tag")


def selector(level: str) -> str:
    return {"major": "+--", "minor": "-+-", "patch": "--+"}[level]


def plan(repository: Path) -> dict[str, object]:
    resolved_repository = repository.resolve(strict=True)
    if not (resolved_repository / ".git").exists() and not checked_git(
        resolved_repository, "rev-parse", "--git-dir"
    ).strip():
        raise VersionError(f"repository is not a Git checkout: {resolved_repository}")
    tag = latest_tag(resolved_repository)
    commits = commits_since(resolved_repository, tag)
    level = release_level(commits)
    current = Version.parse(tag) if tag else Version(0, 0, 0)
    return {
        "base": str(current),
        "commits": len(commits),
        "level": level,
        "next": str(current.bump(level)),
        "schema": 1,
        "selector": selector(level),
    }


def parse_arguments(arguments: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repository",
        type=Path,
        default=Path.cwd(),
        help="Git checkout to inspect (default: current directory)",
    )
    parser.add_argument(
        "--format",
        choices=("json", "selector", "version"),
        default="json",
    )
    parser.add_argument(
        "--allow-no-release",
        action="store_true",
        help="return an empty value when valid history contains no release change",
    )
    return parser.parse_args(arguments)


def main(arguments: Sequence[str] | None = None) -> int:
    options = parse_arguments(sys.argv[1:] if arguments is None else arguments)
    try:
        value = plan(options.repository)
    except (OSError, VersionError) as error:
        if options.allow_no_release and str(error).startswith(
            "no release-producing Conventional Commit exists"
        ):
            print("")
            return 0
        print(f"conventional version error: {error}", file=sys.stderr)
        return 2
    if options.format == "selector":
        print(value["selector"])
    elif options.format == "version":
        print(value["next"])
    else:
        print(json.dumps(value, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
