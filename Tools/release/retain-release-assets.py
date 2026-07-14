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

"""Retain binary assets for only the newest stable and current releases."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import tempfile
from collections.abc import Iterable
from pathlib import Path


RETENTION_START = "<!-- container-release-retention:start -->"
RETENTION_END = "<!-- container-release-retention:end -->"
LEGACY_PIN_HIGHLIGHT = re.compile(
    r"(?m)^- Release automation pins .+ by exact SwiftPM revision [0-9a-f]{12}\.\n?"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, help="owner/repository")
    parser.add_argument(
        "--bootstrap-command",
        required=True,
        help="Homebrew command that installs the source-build prerequisites",
    )
    parser.add_argument(
        "--build-command",
        required=True,
        help="command that builds the checked-out source tag",
    )
    parser.add_argument(
        "--source-guidance",
        required=True,
        help="versioned documentation file or files to use after the source build",
    )
    parser.add_argument(
        "--stable-install-command",
        required=True,
        help="Homebrew command for the active stable release",
    )
    parser.add_argument(
        "--current-install-command",
        required=True,
        help="Homebrew command for the active prerelease",
    )
    parser.add_argument(
        "--install-command",
        help="optional command that installs the locally-built artifact",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="delete stale assets and edit stale release notes; otherwise report only",
    )
    parser.add_argument(
        "--delete-superseded-current-releases",
        action="store_true",
        help="delete obsolete mutable current release objects while preserving their tags",
    )
    parser.add_argument(
        "--current-asset",
        action="append",
        default=[],
        help=(
            "asset name that belongs to the finalized current build; may be repeated. "
            "All other current-release assets are retired after promotion."
        ),
    )
    return parser.parse_args()


def run_gh(*arguments: str) -> str:
    return subprocess.run(
        ["gh", *arguments],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    ).stdout


def published_releases(releases: Iterable[dict]) -> list[dict]:
    return [release for release in releases if not release.get("draft") and release.get("published_at")]


def current_release_candidates(releases: Iterable[dict]) -> list[dict]:
    """Return published prereleases that implement the mutable current lane."""
    return [
        release
        for release in published_releases(releases)
        if release.get("prerelease")
        and release.get("tag_name") in {"current"}
    ]


def obsolete_current_release(release: dict) -> bool:
    """Return whether a prerelease is an old generated current-build release."""
    tag = str(release.get("tag_name") or "")
    return bool(release.get("prerelease")) and (
        tag.startswith("current-") or tag.startswith("homebrew-main-")
    )


def retained_release_ids(releases: Iterable[dict]) -> set[int]:
    """Return newest stable and the sole mutable current prerelease ids."""

    keep: set[int] = set()
    stable_candidates = [
        release
        for release in published_releases(releases)
        if not release.get("prerelease")
    ]
    if stable_candidates:
        keep.add(max(stable_candidates, key=lambda release: release["published_at"])["id"])

    current_candidates = current_release_candidates(releases)
    if not current_candidates:
        current_candidates = [
            release
            for release in published_releases(releases)
            if release.get("prerelease")
        ]
    if current_candidates:
        keep.add(max(current_candidates, key=lambda release: release["published_at"])["id"])
    return keep


def historical_source_note(
    *,
    repo: str,
    tag: str,
    bootstrap_command: str,
    build_command: str,
    source_guidance: str,
    install_command: str | None,
) -> str:
    directory = repo.rsplit("/", maxsplit=1)[-1]
    commands = [
        bootstrap_command,
        f"git clone --depth 1 --branch {tag} https://github.com/{repo}.git",
        f"cd {directory}",
        build_command,
    ]
    if install_command:
        commands.append(install_command)

    return "\n".join(
        [
            RETENTION_START,
            "## Historical source installation",
            "",
            "This release is retained as source history, but its prebuilt assets and tap-backed package have been retired.",
            "The public Homebrew formula intentionally follows only the newest release in each lane, so it cannot select this historical tag.",
            "Use Homebrew to bootstrap the build tools, then build this exact source tag:",
            "",
            "```sh",
            *commands,
            "```",
            "",
            f"For the matched stack layout and verification steps, use `{source_guidance}` from this checkout.",
            RETENTION_END,
        ]
    )


def active_homebrew_note(*, prerelease: bool, install_command: str) -> str:
    lane = "current prerelease" if prerelease else "stable release"
    return "\n".join(
        [
            RETENTION_START,
            "## Homebrew installation",
            "",
            f"This is the newest published {lane}, so its prebuilt package remains available through Homebrew.",
            "",
            "```sh",
            "brew tap stephenlclarke/tap",
            "brew trust --tap stephenlclarke/tap",
            "brew update",
            install_command,
            "```",
            RETENTION_END,
        ]
    )


def replace_retention_note(body: str, note: str) -> str:
    start = body.find(RETENTION_START)
    if start < 0:
        return body.rstrip() + "\n\n" + note + "\n"
    end = body.find(RETENTION_END, start)
    if end < 0:
        raise ValueError("release retention marker is missing its end marker")
    end += len(RETENTION_END)
    return body[:start].rstrip() + "\n\n" + note + body[end:].rstrip() + "\n"


def remove_legacy_pin_highlights(body: str) -> str:
    """Drop internal dependency-pin statements from user-facing release notes."""
    return LEGACY_PIN_HIGHLIGHT.sub("", body)


def list_releases(repo: str) -> list[dict]:
    pages = json.loads(
        run_gh(
            "api",
            "--paginate",
            "--slurp",
            f"repos/{repo}/releases?per_page=100",
        )
    )
    return [release for page in pages for release in page]


def delete_assets(repo: str, release: dict) -> None:
    for asset in release.get("assets", []):
        run_gh("api", "--method", "DELETE", f"repos/{repo}/releases/assets/{asset['id']}")


def stale_current_assets(release: dict, retained_names: set[str]) -> list[dict]:
    """Return superseded assets from the sole mutable current release."""

    return [
        asset
        for asset in release.get("assets", [])
        if asset.get("name") not in retained_names
    ]


def delete_named_assets(repo: str, assets: Iterable[dict]) -> None:
    for asset in assets:
        run_gh("api", "--method", "DELETE", f"repos/{repo}/releases/assets/{asset['id']}")


def update_release_notes(repo: str, release: dict, body: str) -> None:
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as notes_file:
        notes_file.write(body)
        notes_path = Path(notes_file.name)
    try:
        run_gh(
            "release",
            "edit",
            release["tag_name"],
            "--repo",
            repo,
            "--notes-file",
            str(notes_path),
        )
    finally:
        notes_path.unlink(missing_ok=True)


def delete_release(repo: str, release: dict) -> None:
    """Delete only a release object; source tags remain available for reference."""
    run_gh("release", "delete", release["tag_name"], "--repo", repo, "--yes")


def main() -> None:
    args = parse_args()
    releases = list_releases(args.repo)
    retained = retained_release_ids(releases)
    stale = [release for release in published_releases(releases) if release["id"] not in retained]

    retained_tags = [
        release["tag_name"]
        for release in published_releases(releases)
        if release["id"] in retained
    ]
    print(f"retaining release assets for: {', '.join(retained_tags) or 'none'}")

    for release in published_releases(releases):
        if release["id"] not in retained:
            continue
        current_body = release.get("body") or ""
        body = replace_retention_note(
            remove_legacy_pin_highlights(current_body),
            active_homebrew_note(
                prerelease=bool(release.get("prerelease")),
                install_command=(
                    args.current_install_command
                    if release.get("prerelease")
                    else args.stable_install_command
                ),
            ),
        )
        if body == current_body:
            continue
        print(f"documenting Homebrew installation for {release['tag_name']}")
        if args.apply:
            update_release_notes(args.repo, release, body)

    retained_current_assets = set(args.current_asset)
    if retained_current_assets:
        for release in published_releases(releases):
            if release["id"] not in retained or release.get("tag_name") != "current":
                continue
            stale_assets = stale_current_assets(release, retained_current_assets)
            if not stale_assets:
                continue
            print(
                "retiring superseded current assets: "
                + ", ".join(str(asset.get("name")) for asset in stale_assets)
            )
            if args.apply:
                delete_named_assets(args.repo, stale_assets)

    for release in stale:
        if args.delete_superseded_current_releases and obsolete_current_release(release):
            print(f"removing superseded current release object: {release['tag_name']}")
            if args.apply:
                delete_release(args.repo, release)
            continue

        current_body = release.get("body") or ""
        note = historical_source_note(
            repo=args.repo,
            tag=release["tag_name"],
            bootstrap_command=args.bootstrap_command,
            build_command=args.build_command,
            source_guidance=args.source_guidance,
            install_command=args.install_command,
        )
        body = replace_retention_note(remove_legacy_pin_highlights(current_body), note)
        asset_count = len(release.get("assets", []))
        if not asset_count and body == current_body:
            continue
        print(f"retiring {release['tag_name']}: {asset_count} asset(s)")
        if args.apply:
            if asset_count:
                delete_assets(args.repo, release)
            if body != current_body:
                update_release_notes(args.repo, release, body)


if __name__ == "__main__":
    main()
