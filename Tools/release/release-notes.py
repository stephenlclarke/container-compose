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

"""Render GitHub release notes for prebuilt container-compose packages."""

from __future__ import annotations

import argparse
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path


STABLE_RELEASE_PATTERN = re.compile(r"^[0-9]+[.][0-9]+[.][0-9]+$")


@dataclass(frozen=True)
class CommitSummary:
    short_hash: str
    subject: str
    highlights: tuple[str, ...]


@dataclass(frozen=True)
class ReleaseRange:
    base_ref: str | None
    base_label: str | None
    head_ref: str
    head_commit: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=".")
    parser.add_argument("--release-tag", required=True)
    parser.add_argument("--release-label", required=True)
    parser.add_argument("--compose-version", required=True)
    parser.add_argument("--asset", required=True)
    parser.add_argument("--asset-sha", required=True)
    parser.add_argument("--head", default="HEAD")
    return parser.parse_args()


def git_output(repo: Path, *arguments: str) -> str | None:
    result = subprocess.run(
        ["git", "-C", str(repo), *arguments],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    output = result.stdout.strip()
    return output or None


def commit_for_ref(repo: Path, ref: str) -> str | None:
    return git_output(repo, "rev-parse", "--verify", f"{ref}^{{commit}}")


def previous_stable_tag(repo: Path, release_tag: str, head_ref: str) -> str | None:
    tags = git_output(
        repo,
        "for-each-ref",
        "--merged",
        head_ref,
        "--sort=-creatordate",
        "--format=%(refname:short)",
        "refs/tags",
    )
    if tags is None:
        return None

    for tag in tags.splitlines():
        if tag == release_tag:
            continue
        if STABLE_RELEASE_PATTERN.fullmatch(tag):
            return tag
    return None


def is_stable_release_tag(release_tag: str) -> bool:
    return STABLE_RELEASE_PATTERN.fullmatch(release_tag) is not None


def release_range(repo: Path, release_tag: str, head_ref: str) -> ReleaseRange:
    head_commit = commit_for_ref(repo, head_ref)
    if head_commit is None:
        raise ValueError(f"could not resolve release head: {head_ref}")

    tagged_commit = commit_for_ref(repo, f"refs/tags/{release_tag}")
    if tagged_commit is not None:
        if tagged_commit != head_commit:
            return ReleaseRange(
                base_ref=f"refs/tags/{release_tag}",
                base_label=release_tag,
                head_ref=head_ref,
                head_commit=head_commit,
            )

    previous_tag = previous_stable_tag(repo, release_tag, head_ref)
    if previous_tag is not None:
        return ReleaseRange(
            base_ref=f"refs/tags/{previous_tag}",
            base_label=previous_tag,
            head_ref=head_ref,
            head_commit=head_commit,
        )

    return ReleaseRange(
        base_ref=None,
        base_label=None,
        head_ref=head_ref,
        head_commit=head_commit,
    )


def commits_for_range(repo: Path, selected_range: ReleaseRange) -> list[CommitSummary]:
    revision = (
        f"{selected_range.base_ref}..{selected_range.head_ref}"
        if selected_range.base_ref is not None
        else selected_range.head_ref
    )
    output = git_output(
        repo,
        "log",
        (
            "--pretty=format:"
            "%h%x09%s%x09"
            "%(trailers:key=Release-Note,valueonly,separator=%x1f)%x09"
            "%(trailers:key=Release-Highlight,valueonly,separator=%x1f)%x1e"
        ),
        revision,
    )
    if output is None:
        return []

    commits: list[CommitSummary] = []
    for record in output.rstrip("\x1e").split("\x1e"):
        line = record.strip("\n")
        if not line:
            continue
        parts = line.split("\t", maxsplit=3)
        if len(parts) < 2:
            continue
        short_hash = parts[0]
        subject = parts[1]
        release_note_values = parts[2] if len(parts) >= 3 else ""
        release_highlight_values = parts[3] if len(parts) >= 4 else ""
        commits.append(
            CommitSummary(
                short_hash=short_hash,
                subject=subject,
                highlights=tuple(
                    explicit_release_highlights(
                        release_note_values,
                        release_highlight_values,
                    )
                ),
            )
        )
    return commits


def explicit_release_highlights(*values: str) -> list[str]:
    highlights: list[str] = []
    for value in values:
        for item in value.split("\x1f"):
            normalized = item.strip()
            if not normalized:
                continue
            if normalized.lower() in {"none", "n/a", "na", "skip"}:
                continue
            highlights.append(ensure_sentence(normalized))
    return highlights


CONVENTIONAL_SUBJECT_PATTERN = re.compile(
    r"^(?P<type>[a-z]+)(?:[(](?P<scope>[^)]+)[)])?(?P<breaking>!)?: (?P<summary>.+)$"
)
HIGHLIGHT_TYPES = {"feat", "fix", "perf"}
INTERNAL_HIGHLIGHT_SCOPES = {
    "ci",
    "deps",
    "docs",
    "quality",
    "release",
    "status",
    "test",
    "tests",
}


def conventional_highlight(subject: str) -> str | None:
    match = CONVENTIONAL_SUBJECT_PATTERN.fullmatch(subject)
    if match is None:
        return None
    if match.group("type") not in HIGHLIGHT_TYPES:
        return None
    scope = (match.group("scope") or "").lower()
    if scope in INTERNAL_HIGHLIGHT_SCOPES:
        return None

    summary = match.group("summary").strip()
    if not summary:
        return None
    return ensure_sentence(summary[:1].upper() + summary[1:])


def release_highlights(commits: list[CommitSummary]) -> list[str]:
    highlights: list[str] = []
    seen: set[str] = set()

    for commit in reversed(commits):
        commit_highlights = list(commit.highlights)
        if not commit_highlights:
            fallback = conventional_highlight(commit.subject)
            if fallback is not None:
                commit_highlights = [fallback]

        for highlight in commit_highlights:
            if highlight in seen:
                continue
            seen.add(highlight)
            highlights.append(highlight)

    return highlights


def ensure_sentence(value: str) -> str:
    value = value.strip()
    if not value:
        return value
    if value[-1] in ".!?":
        return value
    return f"{value}."


def render_release_notes(
    *,
    repo: Path,
    release_tag: str,
    release_label: str,
    compose_version: str,
    asset: str,
    asset_sha: str,
    head_ref: str,
) -> str:
    selected_range = release_range(repo, release_tag, head_ref)
    commits = commits_for_range(repo, selected_range)
    highlights = release_highlights(commits)
    head_short = selected_range.head_commit[:12]
    stable_release = is_stable_release_tag(release_tag)

    lines = [
        "## Summary",
        "",
        f"- {release_label} package for the `{compose_version}` container-compose slice.",
        "- Keeps the fork-backed container, containerization, and builder-shim compatibility metadata intact.",
        "- Publishes the release-quality Swift plugin and non-debug Go normalizer package.",
        "",
    ]

    if highlights:
        lines.extend(
            [
                "## Highlights",
                "",
                *[f"- {highlight}" for highlight in highlights],
                "",
            ]
        )

    lines.extend(["## Changes", ""])

    if selected_range.base_label is None:
        lines.append(f"- Commits included through `{head_short}`:")
    else:
        lines.append(
            f"- Commits since `{selected_range.base_label}` through `{head_short}`:"
        )

    if commits:
        lines.extend(f"- `{commit.short_hash}` {commit.subject}" for commit in commits)
    else:
        lines.append("- No source commits changed since the previous package for this lane.")

    lines.extend(
        [
            "",
            "## Homebrew Formula",
            "",
        ]
    )
    if stable_release:
        lines.extend(
            [
                "- The stable release updates `stephenlclarke/tap/container-compose` to the stable asset and semver formula version.",
                "- The formula depends on the matched `stephenlclarke/tap/container` runtime package.",
            ]
        )
    else:
        lines.extend(
            [
                "- Main validation packages do not update the stable Homebrew formula.",
                "- Installable packages come from stable semantic release tags.",
            ]
        )

    lines.extend(
        [
            "",
            "## Promotion",
            "",
        ]
    )
    if stable_release:
        lines.extend(
            [
                "- Promotion means validating `main`, creating the bare semver source tag, and dispatching the stable package workflow for that tag.",
                "- The stable package workflow marks the semver release as GitHub `Latest` and updates the stable Homebrew formula.",
            ]
        )
    else:
        lines.extend(
            [
                "- Main validation packages are CI artifacts for the current `main` branch.",
                "- They do not move semantic source tags or Homebrew formulae.",
            ]
        )

    lines.extend(
        [
            "",
            "## Asset Retention",
            "",
            "- Release automation keeps binary assets on the latest main validation release and the latest stable release.",
            "- Older release objects and source tags are retained, but their binary assets may be deleted after their notes include a source-build Homebrew install block.",
            "",
            "## Validation",
            "",
            "- The package commit passed CI `Validate`, or the manual release-validation fallback passed before packaging.",
            "- CI runs `make ci-fast` plus the release coverage gate; the manual fallback runs `make ci` when no successful CI result exists for the same SHA.",
            f"- `make package-release PLUGIN_ARCHIVE={asset}` passed.",
            "- `make go-release-check` passed as part of package validation.",
            "- `git diff --check` passed as part of `make check`.",
            "",
            "## Assets",
            "",
            f"- `{asset}` SHA-256:",
            f"  `{asset_sha}`.",
        ]
    )
    return "\n".join(lines) + "\n"


def main() -> None:
    args = parse_args()
    try:
        print(
            render_release_notes(
                repo=Path(args.repo),
                release_tag=args.release_tag,
                release_label=args.release_label,
                compose_version=args.compose_version,
                asset=args.asset,
                asset_sha=args.asset_sha,
                head_ref=args.head,
            ),
            end="",
        )
    except ValueError as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
