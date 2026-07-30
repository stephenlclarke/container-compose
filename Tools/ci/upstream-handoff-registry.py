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

"""Import, render, and validate the compact upstream handoff registry."""

from __future__ import annotations

import argparse
import json
import os
import posixpath
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable
from urllib.parse import quote, unquote, urlparse


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_REGISTRY = ROOT / "docs/upstream/HANDOFF-REGISTRY.json"
DEFAULT_RENDERED = ROOT / "docs/upstream/HANDOFF-REGISTRY.md"
LEGACY_PATTERN = re.compile(r"^(ISSUE|PR)-(.+)\.md$")
FULL_SHA_PATTERN = re.compile(r"(?<![0-9a-f])([0-9a-f]{40})(?![0-9a-f])")
DATE_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}$")
FULL_COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
ARCHIVE_URL_PATTERN = re.compile(
    r"^https://github\.com/stephenlclarke/container-compose/blob/"
    r"([0-9a-f]{40})/(.+)$"
)
MARKDOWN_LINK_PATTERN = re.compile(r"(\]\()([^)#\s]+\.md)(#[^)\s]+)?(\))")
ALLOWED_STATES = {
    "active-draft",
    "archived",
    "closed",
    "merged",
    "submitted",
    "tracked-upstream",
    "unsubmitted",
}
OWNER_BY_DIRECTORY = {
    "apple-container": "apple/container",
    "apple-containerization": "apple/containerization",
    "apple-container-builder-shim": "apple/container-builder-shim",
}


class RegistryError(ValueError):
    """Raised when registry data or generated output is invalid."""


@dataclass(frozen=True)
class LegacyDocument:
    kind: str
    slug: str
    path: Path
    title: str
    commits: tuple[str, ...]


def git_output(root: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", *arguments],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout


def markdown_title(text: str, fallback: str) -> str:
    for line in text.splitlines():
        if line.startswith("# "):
            return line[2:].strip()
    return fallback


def owner_for(relative_path: Path) -> str:
    parts = relative_path.parts
    if len(parts) >= 3:
        return OWNER_BY_DIRECTORY.get(
            parts[2],
            "stephenlclarke/container-compose",
        )
    return "stephenlclarke/container-compose"


def entry_id(relative_path: Path, slug: str) -> str:
    parts = relative_path.parts
    area = parts[2] if len(parts) >= 3 else "container-compose"
    nested = "-".join(parts[3:-1])
    prefix = "-".join(part for part in (area, nested) if part)
    return f"{prefix}-{slug}"


def read_legacy_documents(root: Path) -> list[LegacyDocument]:
    documents: list[LegacyDocument] = []
    for path in sorted((root / "docs/upstream").rglob("*.md")):
        match = LEGACY_PATTERN.match(path.name)
        if match is None:
            continue
        text = path.read_text(encoding="utf-8")
        relative_path = path.relative_to(root)
        documents.append(
            LegacyDocument(
                kind="issue" if match.group(1) == "ISSUE" else "pull-request",
                slug=match.group(2),
                path=relative_path,
                title=markdown_title(text, match.group(2).replace("-", " ")),
                commits=tuple(dict.fromkeys(FULL_SHA_PATTERN.findall(text))),
            )
        )
    return documents


def archive_url(commit: str, path: Path) -> str:
    encoded_path = quote(path.as_posix(), safe="/")
    return (
        "https://github.com/stephenlclarke/container-compose/blob/"
        f"{commit}/{encoded_path}"
    )


def import_legacy(
    root: Path,
    archive_commit: str,
    verified_at: str,
    active_paths: set[Path],
) -> dict[str, object]:
    if FULL_COMMIT_PATTERN.fullmatch(archive_commit) is None:
        raise RegistryError("archive commit must be a full lowercase Git SHA")
    if DATE_PATTERN.fullmatch(verified_at) is None:
        raise RegistryError("verified date must use YYYY-MM-DD")

    grouped: dict[str, list[LegacyDocument]] = {}
    for document in read_legacy_documents(root):
        grouped.setdefault(entry_id(document.path, document.slug), []).append(
            document
        )

    known_paths = {
        document.path
        for documents in grouped.values()
        for document in documents
    }
    unknown_active = sorted(active_paths - known_paths)
    if unknown_active:
        joined = ", ".join(path.as_posix() for path in unknown_active)
        raise RegistryError(
            f"active handoff path is not a legacy document: {joined}"
        )

    entries: list[dict[str, object]] = []
    for key, documents in sorted(grouped.items()):
        documents.sort(key=lambda item: (item.kind, item.path.as_posix()))
        active = any(document.path in active_paths for document in documents)
        preferred = next(
            (
                document
                for document in documents
                if document.kind == "pull-request"
            ),
            documents[0],
        )
        commits = tuple(
            dict.fromkeys(
                commit
                for document in documents
                for commit in document.commits
            )
        )
        entry_documents = []
        for document in documents:
            item: dict[str, object] = {
                "kind": document.kind,
                "archive": archive_url(archive_commit, document.path),
            }
            if document.path in active_paths:
                item["path"] = document.path.as_posix()
            entry_documents.append(item)
        entries.append(
            {
                "id": key,
                "owner": owner_for(preferred.path),
                "title": preferred.title,
                "state": "active-draft" if active else "archived",
                "lastVerified": verified_at,
                "commits": list(commits),
                "documents": entry_documents,
            }
        )

    return {
        "schemaVersion": 1,
        "archiveCommit": archive_commit,
        "generatedAt": verified_at,
        "entries": entries,
    }


def load_registry(path: Path) -> dict[str, object]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RegistryError(f"could not load registry: {error}") from error
    if not isinstance(payload, dict):
        raise RegistryError("registry root must be an object")
    return payload


def archived_document_links(
    payload: dict[str, object],
) -> dict[str, str]:
    links: dict[str, str] = {}
    entries = payload.get("entries")
    if not isinstance(entries, list):
        return links
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        documents = entry.get("documents")
        if not isinstance(documents, list):
            continue
        for document in documents:
            if not isinstance(document, dict):
                continue
            archive = document.get("archive")
            if not isinstance(archive, str):
                continue
            parsed = parse_archive_url(archive)
            if parsed is None:
                continue
            _, archive_path = parsed
            links[archive_path] = archive
    return links


def parse_archive_url(value: str) -> tuple[str, str] | None:
    match = ARCHIVE_URL_PATTERN.fullmatch(value)
    if match is None:
        return None
    commit = match.group(1)
    path = unquote(match.group(2))
    if archive_url(commit, Path(path)) != value:
        return None
    return commit, path


def archived_relative_link_errors(
    payload: dict[str, object],
    root: Path,
) -> list[str]:
    archived = archived_document_links(payload)
    errors: list[str] = []
    for source in markdown_sources(root):
        relative_source = source.relative_to(root).as_posix()
        text = source.read_text(encoding="utf-8")
        for match in MARKDOWN_LINK_PATTERN.finditer(text):
            target = match.group(2)
            if "://" in target:
                continue
            resolved = posixpath.normpath(
                posixpath.join(posixpath.dirname(relative_source), target)
            )
            if resolved in archived and not (root / resolved).is_file():
                errors.append(
                    f"{relative_source} links to retired handoff {target}; "
                    "use its immutable registry archive"
                )
    return errors


def markdown_sources(root: Path) -> list[Path]:
    sources: list[Path] = []
    for directory, child_directories, files in os.walk(root):
        child_directories[:] = [
            child
            for child in child_directories
            if child not in {".build", ".git"}
        ]
        directory_path = Path(directory)
        sources.extend(
            directory_path / filename
            for filename in files
            if filename.endswith(".md")
        )
    return sorted(sources)


def rewrite_archived_links(
    payload: dict[str, object],
    root: Path,
) -> list[Path]:
    archived = archived_document_links(payload)
    changed: list[Path] = []
    for source in markdown_sources(root):
        relative_source = source.relative_to(root).as_posix()
        original = source.read_text(encoding="utf-8")

        def replacement(match: re.Match[str]) -> str:
            target = match.group(2)
            if "://" in target:
                return match.group(0)
            resolved = posixpath.normpath(
                posixpath.join(posixpath.dirname(relative_source), target)
            )
            archive = archived.get(resolved)
            if archive is None or (root / resolved).is_file():
                return match.group(0)
            anchor = match.group(3) or ""
            return f"{match.group(1)}{archive}{anchor}{match.group(4)}"

        updated = MARKDOWN_LINK_PATTERN.sub(replacement, original)
        if updated != original:
            source.write_text(updated, encoding="utf-8")
            changed.append(source.relative_to(root))
    return changed


def validate_registry(
    payload: dict[str, object],
    root: Path,
) -> list[str]:
    errors: list[str] = []
    if payload.get("schemaVersion") != 1:
        errors.append("schemaVersion must be 1")
    archive_commit = payload.get("archiveCommit")
    if (
        not isinstance(archive_commit, str)
        or FULL_COMMIT_PATTERN.fullmatch(archive_commit) is None
    ):
        errors.append("archiveCommit must be a full lowercase Git SHA")
        archive_commit = ""
    generated_at = payload.get("generatedAt")
    if (
        not isinstance(generated_at, str)
        or DATE_PATTERN.fullmatch(generated_at) is None
    ):
        errors.append("generatedAt must use YYYY-MM-DD")

    archived_paths_by_commit: dict[str, set[str]] = {}
    if archive_commit:
        try:
            archived_paths_by_commit[archive_commit] = set(
                git_output(
                    root,
                    "ls-tree",
                    "-r",
                    "--name-only",
                    archive_commit,
                    "--",
                    "docs/upstream",
                ).splitlines()
            )
        except subprocess.CalledProcessError:
            errors.append(
                f"archiveCommit {archive_commit} is not available locally"
            )

    entries = payload.get("entries")
    if not isinstance(entries, list):
        return errors + ["entries must be an array"]

    seen_ids: set[str] = set()
    registered_active: set[Path] = set()
    registered_archives: set[str] = set()
    for index, entry in enumerate(entries):
        label = f"entries[{index}]"
        if not isinstance(entry, dict):
            errors.append(f"{label} must be an object")
            continue
        identifier = entry.get("id")
        if not isinstance(identifier, str) or not identifier:
            errors.append(f"{label}.id must be a non-empty string")
        elif identifier in seen_ids:
            errors.append(f"duplicate entry id: {identifier}")
        else:
            seen_ids.add(identifier)
            label = identifier
        for field in ("owner", "title"):
            value = entry.get(field)
            if not isinstance(value, str) or not value:
                errors.append(f"{label}.{field} must be a non-empty string")
        state = entry.get("state")
        if state not in ALLOWED_STATES:
            errors.append(f"{label}.state is invalid: {state!r}")
        upstream = entry.get("upstream")
        if upstream is not None:
            if not isinstance(upstream, str):
                errors.append(f"{label}.upstream must be a string")
            else:
                parsed = urlparse(upstream)
                if (
                    parsed.scheme != "https"
                    or parsed.netloc != "github.com"
                    or re.fullmatch(
                        r"/[^/]+/[^/]+/pull/[1-9][0-9]*",
                        parsed.path,
                    )
                    is None
                    or parsed.params
                    or parsed.query
                    or parsed.fragment
                ):
                    errors.append(
                        f"{label}.upstream must be a GitHub pull-request URL"
                    )
        last_verified = entry.get("lastVerified")
        if (
            not isinstance(last_verified, str)
            or DATE_PATTERN.fullmatch(last_verified) is None
        ):
            errors.append(f"{label}.lastVerified must use YYYY-MM-DD")
        commits = entry.get("commits")
        if not isinstance(commits, list) or any(
            not isinstance(commit, str)
            or FULL_COMMIT_PATTERN.fullmatch(commit) is None
            for commit in commits
        ):
            errors.append(
                f"{label}.commits must contain only full lowercase Git SHAs"
            )
        documents = entry.get("documents")
        if not isinstance(documents, list):
            errors.append(f"{label}.documents must be an array")
            continue
        for document_index, document in enumerate(documents):
            document_label = f"{label}.documents[{document_index}]"
            if not isinstance(document, dict):
                errors.append(f"{document_label} must be an object")
                continue
            if document.get("kind") not in {"issue", "pull-request"}:
                errors.append(f"{document_label}.kind is invalid")
            archive = document.get("archive")
            path = document.get("path")
            if path is not None:
                if not isinstance(path, str):
                    errors.append(f"{document_label}.path must be a string")
                else:
                    relative_path = Path(path)
                    if (
                        relative_path.is_absolute()
                        or ".." in relative_path.parts
                        or relative_path.parts[:2] != ("docs", "upstream")
                    ):
                        errors.append(
                            f"{document_label}.path must stay under "
                            "docs/upstream"
                        )
                    else:
                        if relative_path in registered_active:
                            errors.append(
                                "active handoff document is registered more "
                                f"than once: {path}"
                            )
                        else:
                            registered_active.add(relative_path)
                        if not (root / relative_path).is_file():
                            errors.append(
                                f"active handoff document is missing: {path}"
                            )
            if archive is None:
                if path is None:
                    errors.append(
                        f"{document_label} must have an active path or archive"
                    )
                continue
            if not isinstance(archive, str):
                errors.append(f"{document_label}.archive must be a string")
                continue
            parsed_archive = parse_archive_url(archive)
            if parsed_archive is None:
                errors.append(
                    f"{document_label}.archive must be a canonical "
                    "stephenlclarke/container-compose blob URL"
                )
                continue
            if archive in registered_archives:
                errors.append(
                    "archived handoff document is registered more than once: "
                    f"{archive}"
                )
            else:
                registered_archives.add(archive)
            document_commit, archive_path = parsed_archive
            if document_commit not in archived_paths_by_commit:
                try:
                    archived_paths_by_commit[document_commit] = set(
                        git_output(
                            root,
                            "ls-tree",
                            "-r",
                            "--name-only",
                            document_commit,
                            "--",
                            "docs/upstream",
                        ).splitlines()
                    )
                except subprocess.CalledProcessError:
                    errors.append(
                        f"archive commit {document_commit} is not "
                        "available locally"
                    )
                    archived_paths_by_commit[document_commit] = set()
            if archive_path not in archived_paths_by_commit[document_commit]:
                errors.append(
                    "archived handoff document is missing: "
                    f"{archive_path}"
                )

    current_legacy = {
        path.relative_to(root)
        for path in (root / "docs/upstream").rglob("*.md")
        if LEGACY_PATTERN.match(path.name)
    }
    errors.extend(
        "legacy handoff document is not registered as active: "
        f"{path.as_posix()}"
        for path in sorted(current_legacy - registered_active)
    )
    errors.extend(
        "registered active handoff document is absent: "
        f"{path.as_posix()}"
        for path in sorted(registered_active - current_legacy)
    )
    errors.extend(archived_relative_link_errors(payload, root))
    return errors


def markdown_link(label: str, target: str) -> str:
    return f"[{label}]({target})"


def markdown_table_text(value: str) -> str:
    return (
        value.replace("\\", "\\\\")
        .replace("|", "\\|")
        .replace("[", "\\[")
        .replace("]", "\\]")
    )


def registry_summary(entries: list[dict[str, object]]) -> tuple[int, int, str]:
    document_count = sum(len(entry["documents"]) for entry in entries)
    active_document_count = sum(
        1
        for entry in entries
        for document in entry["documents"]
        if "path" in document
    )
    state_counts: dict[str, int] = {}
    for entry in entries:
        state = entry["state"]
        state_counts[state] = state_counts.get(state, 0) + 1
    state_summary = ", ".join(
        f"`{state}` {count}"
        for state, count in sorted(state_counts.items())
    )
    return document_count, active_document_count, state_summary


def render_registry(payload: dict[str, object]) -> str:
    entries = payload["entries"]
    assert isinstance(entries, list)
    document_count, active_document_count, state_summary = registry_summary(
        entries
    )
    lines = [
        "# Upstream Handoff Registry",
        "",
        "<!-- Generated by Tools/ci/upstream-handoff-registry.py. "
        "Do not edit by hand. -->",
        "",
        "This registry replaces the retired issue and pull-request handoff "
        "pairs.",
        "Current supporting records remain as ordinary Markdown files; every "
        "retired "
        "document",
        "links to an immutable Git snapshot.",
        "",
        f"Last verified: {payload['generatedAt']}",
        "",
        f"Entries: {len(entries)}. Document snapshots: {document_count}. "
        f"Current supporting documents: {active_document_count}.",
        "",
        f"States: {state_summary}.",
        "",
        "| Owner | Capability or pull request | State | Referenced commits | Documents |",
        "| --- | --- | --- | --- | --- |",
    ]
    for entry in sorted(
        entries,
        key=lambda item: (item["owner"], item["id"]),
    ):
        commits = entry["commits"]
        commit_text = (
            ", ".join(f"`{commit[:12]}`" for commit in commits)
            if commits
            else "None recorded"
        )
        document_links = []
        for document in entry["documents"]:
            label = "Issue" if document["kind"] == "issue" else "PR"
            if "path" in document:
                relative_path = posixpath.relpath(
                    document["path"],
                    start="docs/upstream",
                )
                document_links.append(
                    markdown_link(
                        f"{label} details",
                        quote(relative_path, safe="/"),
                    )
                )
            if "archive" in document:
                document_links.append(
                    markdown_link(f"{label} archive", document["archive"])
                )
        title = markdown_table_text(entry["title"])
        if "upstream" in entry:
            title = markdown_link(title, entry["upstream"])
        lines.append(
            "| "
            + " | ".join(
                (
                    f"`{entry['owner']}`",
                    title,
                    f"`{entry['state']}`",
                    commit_text,
                    "; ".join(document_links) if document_links else "None",
                )
            )
            + " |"
        )
    lines.append("")
    return "\n".join(lines)


def write_json(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(payload, indent=2, sort_keys=False) + "\n",
        encoding="utf-8",
    )


def parse_active_paths(values: Iterable[str]) -> set[Path]:
    return {Path(value) for value in values}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY)
    parser.add_argument("--rendered", type=Path, default=DEFAULT_RENDERED)
    subparsers = parser.add_subparsers(dest="command", required=True)

    importer = subparsers.add_parser("import-legacy")
    importer.add_argument("--archive-commit", required=True)
    importer.add_argument("--verified-at", required=True)
    importer.add_argument("--active", action="append", default=[])

    subparsers.add_parser("render")
    subparsers.add_parser("rewrite-links")
    subparsers.add_parser("check")
    return parser


def resolved_path(root: Path, path: Path) -> Path:
    return path if path.is_absolute() else root / path


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    root = args.root.resolve()
    registry_path = resolved_path(root, args.registry)
    rendered_path = resolved_path(root, args.rendered)
    try:
        if args.command == "import-legacy":
            payload = import_legacy(
                root=root,
                archive_commit=args.archive_commit,
                verified_at=args.verified_at,
                active_paths=parse_active_paths(args.active),
            )
            write_json(registry_path, payload)
            rendered_path.parent.mkdir(parents=True, exist_ok=True)
            rendered_path.write_text(
                render_registry(payload),
                encoding="utf-8",
            )
            return 0

        payload = load_registry(registry_path)
        if args.command == "rewrite-links":
            for changed in rewrite_archived_links(payload, root):
                print(changed.as_posix())
            return 0
        if args.command == "render":
            errors = validate_registry(payload, root)
            if errors:
                raise RegistryError("\n".join(errors))
            rendered_path.write_text(
                render_registry(payload),
                encoding="utf-8",
            )
            return 0

        errors = validate_registry(payload, root)
        expected = render_registry(payload)
        try:
            actual = rendered_path.read_text(encoding="utf-8")
        except OSError as error:
            errors.append(f"could not read rendered registry: {error}")
        else:
            if actual != expected:
                errors.append(
                    "rendered handoff registry is stale; run "
                    "make upstream-handoff-registry-update"
                )
        if errors:
            raise RegistryError("\n".join(errors))
        return 0
    except (RegistryError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
