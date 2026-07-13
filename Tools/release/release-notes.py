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
import json
import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path


STABLE_RELEASE_PATTERN = re.compile(r"^[0-9]+[.][0-9]+[.][0-9]+$")
STACK_REFS_PATH = "Tools/release/stack-refs.json"
EXPLICIT_RELEASE_LINE_PATTERN = re.compile(
    r"^Release-(?:Note|Highlight):[ \t]*(?P<value>.*)$"
)
REFERENCE_TRAILER_PATTERN = re.compile(
    r"^(?:Upstream-Ref|Bug-Ref|Refs|Follow-up-To):[ \t]*(?P<value>.*)$",
    re.IGNORECASE,
)
GENERIC_COMMIT_TRAILER_NAMES = {
    "change-id",
    "container-test",
    "related",
    "upstream-issue",
}
SUPPRESSED_RELEASE_NOTE_VALUES = {"none", "n/a", "na", "skip"}
GITHUB_REFERENCE_PATTERN = re.compile(
    r"(?<![A-Za-z0-9_.-])(?P<reference>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+)\b"
)


@dataclass(frozen=True)
class CommitSummary:
    short_hash: str
    subject: str
    body_summary: str | None
    suppress_automatic_highlights: bool
    highlights: tuple[str, ...]
    upstream_references: tuple[str, ...]


@dataclass(frozen=True)
class ReleaseRange:
    base_ref: str | None
    base_label: str | None
    head_ref: str
    head_commit: str


@dataclass(frozen=True)
class ComponentChange:
    name: str
    repository: str
    previous_ref: str
    current_ref: str
    commits: tuple[CommitSummary, ...]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=".")
    parser.add_argument("--release-tag", required=True)
    parser.add_argument("--release-label", required=True)
    parser.add_argument("--compose-version", required=True)
    parser.add_argument("--asset", required=True)
    parser.add_argument("--asset-sha", required=True)
    parser.add_argument("--runtime-asset")
    parser.add_argument("--runtime-asset-sha")
    parser.add_argument(
        "--quality-snapshot",
        type=Path,
        help="Static SonarQube and CodeQL badge block captured for a stable release.",
    )
    parser.add_argument(
        "--highlights-json",
        type=Path,
        help="Write the immutable machine-readable highlight manifest to this path.",
    )
    parser.add_argument("--head", default="HEAD")
    parser.add_argument(
        "--release-repo",
        default=os.environ.get("GITHUB_REPOSITORY"),
        help=(
            "GitHub owner/repository used to find the previous published stable "
            "release. Defaults to GITHUB_REPOSITORY when set."
        ),
    )
    parser.add_argument(
        "--component-repo",
        action="append",
        default=[],
        metavar="NAME=PATH",
        help="Component repository checkout used to summarize stack changes.",
    )
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


def gh_output(*arguments: str) -> str | None:
    result = subprocess.run(
        ["gh", *arguments],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    output = result.stdout.strip()
    return output or None


def git_success(repo: Path, *arguments: str) -> bool:
    result = subprocess.run(
        ["git", "-C", str(repo), *arguments],
        capture_output=True,
        text=True,
        check=False,
    )
    return result.returncode == 0


def commit_for_ref(repo: Path, ref: str) -> str | None:
    return git_output(repo, "rev-parse", "--verify", f"{ref}^{{commit}}")


def stable_release_version(release_tag: str) -> tuple[int, int, int] | None:
    if STABLE_RELEASE_PATTERN.fullmatch(release_tag) is None:
        return None
    major, minor, patch = release_tag.split(".")
    return (int(major), int(minor), int(patch))


def ref_is_ancestor(repo: Path, ancestor_ref: str, descendant_ref: str) -> bool:
    return git_success(repo, "merge-base", "--is-ancestor", ancestor_ref, descendant_ref)


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


def previous_published_stable_tag(
    repo: Path,
    *,
    release_tag: str,
    head_ref: str,
    release_repo: str | None,
) -> str | None:
    if not release_repo:
        return None

    releases = gh_output(
        "release",
        "list",
        "--repo",
        release_repo,
        "--exclude-drafts",
        "--exclude-pre-releases",
        "--json",
        "tagName,publishedAt",
        "--limit",
        "100",
    )
    if releases is None:
        return None

    try:
        parsed = json.loads(releases)
    except json.JSONDecodeError:
        return None
    if not isinstance(parsed, list):
        return None

    release_version = stable_release_version(release_tag)
    candidates: dict[str, tuple[int, int, int]] = {}
    for item in parsed:
        if not isinstance(item, dict):
            continue
        tag = item.get("tagName")
        if not isinstance(tag, str) or tag == release_tag:
            continue
        version = stable_release_version(tag)
        if release_version is not None and version is not None:
            if version >= release_version:
                continue
        if version is not None:
            candidates[tag] = version

    for tag, _version in sorted(
        candidates.items(),
        key=lambda item: item[1],
        reverse=True,
    ):
        ref = f"refs/tags/{tag}"
        if commit_for_ref(repo, ref) is None:
            continue
        if ref_is_ancestor(repo, ref, head_ref):
            return tag

    return None


def is_stable_release_tag(release_tag: str) -> bool:
    return STABLE_RELEASE_PATTERN.fullmatch(release_tag) is not None


def release_range(
    repo: Path,
    release_tag: str,
    head_ref: str,
    release_repo: str | None = None,
) -> ReleaseRange:
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

    previous_tag = previous_published_stable_tag(
        repo,
        release_tag=release_tag,
        head_ref=head_ref,
        release_repo=release_repo,
    )
    if previous_tag is None:
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


def commits_for_revision(repo: Path, revision: str) -> list[CommitSummary]:
    output = git_output(
        repo,
        "log",
        "--pretty=format:%h%x1f%s%x1f%b%x1e",
        revision,
    )
    if output is None:
        return []

    commits: list[CommitSummary] = []
    for record in output.rstrip("\x1e").split("\x1e"):
        line = record.strip("\n")
        if not line:
            continue
        parts = line.split("\x1f", maxsplit=2)
        if len(parts) < 2:
            continue
        short_hash = parts[0]
        subject = parts[1]
        body = parts[2] if len(parts) >= 3 else ""
        commits.append(
            CommitSummary(
                short_hash=short_hash,
                subject=subject,
                body_summary=release_summary_from_body(body),
                suppress_automatic_highlights=release_note_suppresses_highlights(body),
                highlights=tuple(explicit_release_highlights_from_body(body)),
                upstream_references=tuple(upstream_references_from_body(body)),
            )
        )
    return commits


def commits_for_range(repo: Path, selected_range: ReleaseRange) -> list[CommitSummary]:
    revision = (
        f"{selected_range.base_ref}..{selected_range.head_ref}"
        if selected_range.base_ref is not None
        else selected_range.head_ref
    )
    return commits_for_revision(repo, revision)


def explicit_release_highlights(*values: str) -> list[str]:
    highlights: list[str] = []
    for value in values:
        for item in value.split("\x1f"):
            normalized = item.strip()
            if not normalized:
                continue
            if normalized.lower() in SUPPRESSED_RELEASE_NOTE_VALUES:
                continue
            highlights.append(ensure_sentence(normalized))
    return highlights


def explicit_release_highlights_from_body(body: str) -> list[str]:
    values: list[str] = []
    for line in body.splitlines():
        match = EXPLICIT_RELEASE_LINE_PATTERN.match(line.strip())
        if match is not None:
            values.append(match.group("value"))
    return explicit_release_highlights(*values)


def release_note_suppresses_highlights(body: str) -> bool:
    for line in body.splitlines():
        match = EXPLICIT_RELEASE_LINE_PATTERN.match(line.strip())
        if match is None:
            continue
        if any(
            item.strip().lower() in SUPPRESSED_RELEASE_NOTE_VALUES
            for item in match.group("value").split("\x1f")
        ):
            return True
    return False


USER_FACING_LEADING_VERBS = {
    "accept": "Accepts",
    "add": "Adds",
    "enable": "Enables",
    "fix": "Fixes",
    "improve": "Improves",
    "map": "Maps",
    "preserve": "Preserves",
    "support": "Supports",
    "update": "Updates",
}


def release_summary_from_body(body: str) -> str | None:
    """Return the first prose paragraph suitable for a user-facing highlight."""

    for paragraph in re.split(r"\n[ \t]*\n", body.strip()):
        lines = [
            line.strip()
            for line in paragraph.splitlines()
            if line.strip() and not is_commit_trailer(line.strip())
        ]
        if not lines:
            continue

        summary = " ".join(lines)
        match = re.match(r"^(?P<verb>[A-Za-z]+)(?P<remainder>\b.*)$", summary)
        if match is not None:
            verb = USER_FACING_LEADING_VERBS.get(match.group("verb").lower())
            if verb is not None:
                summary = f"{verb}{match.group('remainder')}"
        return ensure_sentence(summary)
    return None


def is_commit_trailer(line: str) -> bool:
    if EXPLICIT_RELEASE_LINE_PATTERN.match(line) or REFERENCE_TRAILER_PATTERN.match(line):
        return True
    name, separator, _value = line.partition(":")
    normalized_name = name.lower()
    return bool(separator) and (
        normalized_name.endswith("-by")
        or normalized_name in GENERIC_COMMIT_TRAILER_NAMES
    )


def upstream_references_from_body(body: str) -> list[str]:
    references: list[str] = []
    seen: set[str] = set()
    for line in body.splitlines():
        trailer = REFERENCE_TRAILER_PATTERN.match(line.strip())
        value = trailer.group("value") if trailer is not None else line
        for match in GITHUB_REFERENCE_PATTERN.finditer(value):
            reference = match.group("reference")
            key = reference.lower()
            if key in seen:
                continue
            seen.add(key)
            references.append(reference)
    return references


CONVENTIONAL_SUBJECT_PATTERN = re.compile(
    r"^(?P<type>[a-z]+)(?:[(](?P<scope>[^)]+)[)])?(?P<breaking>!)?: (?P<summary>.+)$"
)
HIGHLIGHT_TYPES = {"feat", "fix", "perf"}
INTERNAL_HIGHLIGHT_SCOPES = {
    "ci",
    "deps",
    "docs",
    "integration",
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
    if not highlight_eligible(match):
        return None

    summary = match.group("summary").strip()
    if not summary:
        return None
    return ensure_sentence(summary[:1].upper() + summary[1:])


def highlight_eligible(match: re.Match[str]) -> bool:
    if match.group("type") not in HIGHLIGHT_TYPES:
        return False
    scope = (match.group("scope") or "").lower()
    return scope not in INTERNAL_HIGHLIGHT_SCOPES


def release_highlights(commits: list[CommitSummary]) -> list[str]:
    highlights: list[str] = []
    seen: set[str] = set()

    for commit in reversed(commits):
        match = CONVENTIONAL_SUBJECT_PATTERN.fullmatch(commit.subject)
        if match is None:
            if not commit.highlights:
                continue
        elif not highlight_eligible(match):
            continue

        commit_highlights = list(commit.highlights)
        if not commit_highlights and not commit.suppress_automatic_highlights:
            fallback = commit.body_summary or conventional_highlight(commit.subject)
            if fallback is not None:
                commit_highlights = [fallback]

        missing_references = [
            reference
            for reference in commit.upstream_references
            if not any(
                reference.lower() in highlight.lower()
                for highlight in commit_highlights
            )
        ]
        if commit_highlights and missing_references:
            label = (
                "Upstream reference"
                if len(missing_references) == 1
                else "Upstream references"
            )
            commit_highlights[-1] = (
                f"{ensure_sentence(commit_highlights[-1])} {label}: "
                f"{', '.join(missing_references)}."
            )

        for highlight in commit_highlights:
            if highlight in seen:
                continue
            seen.add(highlight)
            highlights.append(highlight)

    return highlights


def combined_release_highlights(
    commits: list[CommitSummary],
    component_changes: list[ComponentChange],
) -> list[str]:
    highlights: list[str] = []
    seen: set[str] = set()

    def append_unique(values: list[str]) -> None:
        for value in values:
            if value in seen:
                continue
            seen.add(value)
            highlights.append(value)

    append_unique(release_highlights(commits))
    for change in component_changes:
        append_unique(release_highlights(list(change.commits)))
    return highlights


def ensure_sentence(value: str) -> str:
    value = value.strip()
    if not value:
        return value
    if value[-1] in ".!?":
        return value
    return f"{value}."


def short_ref(ref: str) -> str:
    return ref[:12]


def parse_component_repos(values: list[str]) -> dict[str, Path]:
    repos: dict[str, Path] = {}
    for value in values:
        if "=" not in value:
            raise ValueError(f"component repo must be NAME=PATH: {value}")
        name, path = value.split("=", maxsplit=1)
        name = name.strip()
        path = path.strip()
        if not name or not path:
            raise ValueError(f"component repo must be NAME=PATH: {value}")
        repos[name] = Path(path)
    return repos


def stack_refs_for_ref(repo: Path, ref: str | None) -> dict[str, dict[str, str]]:
    if ref is None:
        return {}
    output = git_output(repo, "show", f"{ref}:{STACK_REFS_PATH}")
    if output is None:
        return {}
    try:
        data = json.loads(output)
    except json.JSONDecodeError:
        return {}
    components = data.get("components")
    if not isinstance(components, dict):
        return {}

    refs: dict[str, dict[str, str]] = {}
    for name, value in components.items():
        if not isinstance(name, str) or not isinstance(value, dict):
            continue
        repository = value.get("repository")
        ref_value = value.get("ref")
        if isinstance(repository, str) and isinstance(ref_value, str):
            refs[name] = {"repository": repository, "ref": ref_value}
    return refs


def has_commit(repo: Path, ref: str) -> bool:
    return commit_for_ref(repo, ref) is not None


def component_changes(
    *,
    repo: Path,
    selected_range: ReleaseRange,
    component_repos: dict[str, Path],
) -> list[ComponentChange]:
    current_refs = stack_refs_for_ref(repo, selected_range.head_ref)
    previous_refs = stack_refs_for_ref(repo, selected_range.base_ref)
    changes: list[ComponentChange] = []

    for name, current in current_refs.items():
        current_ref = current["ref"]
        previous_ref = previous_refs.get(name, {}).get("ref")
        if previous_ref is None or previous_ref == current_ref:
            continue

        commits: tuple[CommitSummary, ...] = ()
        component_repo = component_repos.get(name)
        if (
            component_repo is not None
            and has_commit(component_repo, previous_ref)
            and has_commit(component_repo, current_ref)
        ):
            commits = tuple(
                commits_for_revision(component_repo, f"{previous_ref}..{current_ref}")
            )

        changes.append(
            ComponentChange(
                name=name,
                repository=current["repository"],
                previous_ref=previous_ref,
                current_ref=current_ref,
                commits=commits,
            )
        )

    return changes


def release_summary(
    *,
    repo: Path,
    release_tag: str,
    head_ref: str,
    release_repo: str | None,
    component_repos: dict[str, Path],
) -> tuple[ReleaseRange, list[CommitSummary], list[ComponentChange], list[str]]:
    """Collect the one canonical release range used by notes and the manifest."""
    selected_range = release_range(repo, release_tag, head_ref, release_repo)
    commits = commits_for_range(repo, selected_range)
    component_deltas = component_changes(
        repo=repo,
        selected_range=selected_range,
        component_repos=component_repos,
    )
    return (
        selected_range,
        commits,
        component_deltas,
        combined_release_highlights(commits, component_deltas),
    )


def highlights_manifest(
    *,
    release_tag: str,
    release_label: str,
    compose_version: str,
    selected_range: ReleaseRange,
    component_deltas: list[ComponentChange],
    highlights: list[str],
) -> str:
    """Serialize stable user-facing release facts alongside the prose notes."""
    return json.dumps(
        {
            "schemaVersion": 1,
            "releaseTag": release_tag,
            "releaseLabel": release_label,
            "composeVersion": compose_version,
            "head": selected_range.head_commit,
            "base": selected_range.base_label,
            "highlights": highlights,
            "components": [
                {
                    "name": change.name,
                    "repository": change.repository,
                    "from": change.previous_ref,
                    "to": change.current_ref,
                }
                for change in component_deltas
            ],
        },
        indent=2,
        sort_keys=True,
    ) + "\n"


def render_release_notes(
    *,
    repo: Path,
    release_tag: str,
    release_label: str,
    compose_version: str,
    asset: str,
    asset_sha: str,
    head_ref: str,
    runtime_asset: str | None = None,
    runtime_asset_sha: str | None = None,
    quality_snapshot: str | None = None,
    release_repo: str | None = None,
    component_repos: dict[str, Path] | None = None,
) -> str:
    selected_range, commits, component_deltas, highlights = release_summary(
        repo=repo,
        release_tag=release_tag,
        head_ref=head_ref,
        release_repo=release_repo,
        component_repos=component_repos or {},
    )
    head_short = selected_range.head_commit[:12]
    stable_release = is_stable_release_tag(release_tag)
    if (runtime_asset is None) != (runtime_asset_sha is None):
        raise ValueError("runtime asset name and checksum must be provided together")

    lines = [
        "## Summary",
        "",
        f"- {release_label} package for the `{compose_version}` container-compose slice.",
        "- Keeps the fork-backed container, containerization, and builder-shim compatibility metadata intact.",
        "- Publishes the release-quality Swift plugin and non-debug Go normalizer package.",
    ]
    if not stable_release:
        lines.append(
            f"- Mutable `current` pointer targets main commit `{selected_range.head_commit}`."
        )
    lines.append("")

    lines.extend(["## Highlights", ""])
    if highlights:
        lines.extend(f"- {highlight}" for highlight in highlights)
    else:
        lines.append("- No user-facing highlights were declared for this build.")
    lines.append("")

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

    if component_deltas:
        lines.extend(["", "## Component Changes", ""])
        for change in component_deltas:
            lines.append(
                f"- `{change.name}` `{short_ref(change.previous_ref)}` -> `{short_ref(change.current_ref)}`"
            )
            if change.commits:
                lines.extend(
                    f"  - `{commit.short_hash}` {commit.subject}"
                    for commit in change.commits
                )
            else:
                lines.append("  - Commit details unavailable in this workflow checkout.")

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
                "- The stable release atomically updates `stephenlclarke/tap/container-compose` and `stephenlclarke/tap/container`.",
                "- The formula pair uses the exact immutable runtime package pinned by this release's stack manifest.",
            ]
        )
    else:
        lines.extend(
            [
                "- The current build atomically updates `stephenlclarke/tap/container-compose-current` and `stephenlclarke/tap/container-current`.",
                "- Both formulae download the exact matched assets from this one mutable prerelease.",
                "- It never changes the stable formula pair.",
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
                "- Promotion creates a bare semver tag at the green `main` head, waits for the hosted Stable Release Gate, then publishes the immutable release.",
                "- The stable package workflow marks the semver release as GitHub `Latest` and atomically updates the stable formula pair.",
            ]
        )
    else:
        lines.extend(
            [
                "- The single `Current build` prerelease and its `current` tag move together only after green `main` CI.",
                "- They do not move semantic source tags or the stable formula pair.",
            ]
        )

    lines.extend(
        [
            "",
            "## Asset Retention",
            "",
            "- Stable release objects, notes, and source tags are retained as history.",
            "- Only the newest published stable release and the one `current` prerelease retain downloadable assets and tap-backed installation.",
            "- Superseded generated current-release objects are deleted, while their source tags remain available for reference.",
            "- Superseded stable releases lose binary assets and gain exact source-build instructions on this page.",
            "",
            "## Validation",
            "",
            "- Current packages require green `main` CI; that is where SonarQube analyses the source.",
            "- Stable releases additionally require the hosted Stable Release Gate, which runs builder, containerization, and container coverage and runtime integration checks, Compose CI, and full Docker Compose parity.",
            "- The package workflow verifies the exact immutable runtime asset before it writes either Homebrew formula.",
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
    if runtime_asset is not None and runtime_asset_sha is not None:
        lines.extend(
            [
                f"- `{runtime_asset}` SHA-256:",
                f"  `{runtime_asset_sha}`.",
            ]
        )
    if quality_snapshot is not None:
        if not stable_release:
            raise ValueError("quality snapshots are supported only for stable releases")
        lines.extend(["", quality_snapshot.rstrip()])
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
                runtime_asset=args.runtime_asset,
                runtime_asset_sha=args.runtime_asset_sha,
                quality_snapshot=(
                    args.quality_snapshot.read_text(encoding="utf-8")
                    if args.quality_snapshot is not None
                    else None
                ),
                head_ref=args.head,
                release_repo=args.release_repo,
                component_repos=parse_component_repos(args.component_repo),
            ),
            end="",
        )
        if args.highlights_json is not None:
            selected_range, _commits, component_deltas, highlights = release_summary(
                repo=Path(args.repo),
                release_tag=args.release_tag,
                head_ref=args.head,
                release_repo=args.release_repo,
                component_repos=parse_component_repos(args.component_repo),
            )
            args.highlights_json.write_text(
                highlights_manifest(
                    release_tag=args.release_tag,
                    release_label=args.release_label,
                    compose_version=args.compose_version,
                    selected_range=selected_range,
                    component_deltas=component_deltas,
                    highlights=highlights,
                ),
                encoding="utf-8",
            )
    except ValueError as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
