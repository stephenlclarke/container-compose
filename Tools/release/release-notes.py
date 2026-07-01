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
PRE_RELEASE_PATTERN = re.compile(r"^[0-9]+[.][0-9]+[.][0-9]+-pre$")


@dataclass(frozen=True)
class CommitSummary:
    short_hash: str
    subject: str


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


def is_moving_release_tag(release_tag: str) -> bool:
    return PRE_RELEASE_PATTERN.fullmatch(release_tag) is not None


def is_stable_release_tag(release_tag: str) -> bool:
    return STABLE_RELEASE_PATTERN.fullmatch(release_tag) is not None


def promoted_prerelease_ref(repo: Path, release_tag: str) -> tuple[str, str] | None:
    if not is_stable_release_tag(release_tag):
        return None

    prerelease_tag = f"{release_tag}-pre"
    commit = commit_for_ref(repo, f"refs/tags/{prerelease_tag}")
    if commit is None:
        return None
    return prerelease_tag, commit


def release_range(repo: Path, release_tag: str, head_ref: str) -> ReleaseRange:
    head_commit = commit_for_ref(repo, head_ref)
    if head_commit is None:
        raise ValueError(f"could not resolve release head: {head_ref}")

    tagged_commit = commit_for_ref(repo, f"refs/tags/{release_tag}")
    if tagged_commit is not None:
        if tagged_commit != head_commit or is_moving_release_tag(release_tag):
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
    output = git_output(repo, "log", "--pretty=format:%h%x09%s", revision)
    if output is None:
        return []

    commits: list[CommitSummary] = []
    for line in output.splitlines():
        short_hash, separator, subject = line.partition("\t")
        if separator:
            commits.append(CommitSummary(short_hash=short_hash, subject=subject))
    return commits


def change_range(repo: Path, release_tag: str, head_ref: str) -> tuple[ReleaseRange, str | None]:
    selected_range = release_range(repo, release_tag, head_ref)
    promoted = promoted_prerelease_ref(repo, release_tag)
    if promoted is None:
        return selected_range, None

    prerelease_tag, prerelease_commit = promoted
    previous_tag = previous_stable_tag(repo, release_tag, head_ref)
    if previous_tag is None:
        return (
            ReleaseRange(
                base_ref=None,
                base_label=None,
                head_ref=f"refs/tags/{prerelease_tag}",
                head_commit=prerelease_commit,
            ),
            prerelease_tag,
        )

    return (
        ReleaseRange(
            base_ref=f"refs/tags/{previous_tag}",
            base_label=previous_tag,
            head_ref=f"refs/tags/{prerelease_tag}",
            head_commit=prerelease_commit,
        ),
        prerelease_tag,
    )


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
    selected_range, promoted_tag = change_range(repo, release_tag, head_ref)
    commits = commits_for_range(repo, selected_range)
    head_short = selected_range.head_commit[:12]

    lines = [
        "## Summary",
        "",
        f"- {release_label} package for the `{compose_version}` container-compose slice.",
        "- Keeps the fork-backed container, containerization, and builder-shim compatibility metadata intact.",
        "- Publishes the release-quality Swift plugin and non-debug Go normalizer package.",
        "",
        "## Changes",
        "",
    ]

    if promoted_tag is not None and selected_range.base_label is None:
        lines.append(f"- Promoted changes from `{promoted_tag}` through `{head_short}`:")
    elif promoted_tag is not None:
        lines.append(
            f"- Promoted changes from `{promoted_tag}` since `{selected_range.base_label}` through `{head_short}`:"
        )
    elif selected_range.base_label is None:
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
            "- The stable release updates `stephenlclarke/tap/container-compose` to the stable asset and semver formula version.",
            "- The `develop/VERSION` pre-release updates `stephenlclarke/tap/container-compose-pre` to the latest prerelease asset.",
            "- The formula depends on the matched `stephenlclarke/tap/container` runtime package.",
            "",
            "## Promotion",
            "",
            "- A pre-release is not renamed into a stable release.",
            "- Promotion means merging the validated development slice back to `main`, creating the bare semver source tag, and letting the stable tag workflow build fresh release assets.",
            "- The stable workflow then marks the semver release as GitHub `Latest` and updates the stable Homebrew formula.",
            "",
            "## Asset Retention",
            "",
            "- Release automation keeps binary assets on one pre-release and one stable release.",
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
