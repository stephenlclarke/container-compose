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

"""Prune older GitHub release assets after release notes explain source rebuilds."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any


SOURCE_INSTALL_HEADING = "## Source Install From This Release"
SHA256_PATTERN = re.compile(r"\b[0-9a-fA-F]{64}\b")
PRE_RELEASE_TAG_PATTERN = re.compile(
    r"^[0-9]+[.][0-9]+[.][0-9]+-pre(?:[.][0-9]+[.][0-9a-fA-F]{12,})?$"
)


@dataclass(frozen=True)
class Release:
    tag_name: str
    name: str
    prerelease: bool
    draft: bool
    published_at: str
    target_commitish: str
    assets: tuple[dict[str, Any], ...]
    body: str

    @property
    def has_assets(self) -> bool:
        return len(self.assets) > 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--current-tag", required=True)
    parser.add_argument(
        "--execute",
        action="store_true",
        help="Actually edit release notes and delete assets. Without this, only print the plan.",
    )
    return parser.parse_args()


def release_from_json(value: dict[str, Any]) -> Release:
    return Release(
        tag_name=value["tag_name"],
        name=value.get("name") or value["tag_name"],
        prerelease=bool(value.get("prerelease")),
        draft=bool(value.get("draft")),
        published_at=value.get("published_at") or value.get("created_at") or "",
        target_commitish=value.get("target_commitish") or value["tag_name"],
        assets=tuple(value.get("assets") or ()),
        body=value.get("body") or "",
    )


def current_tag_prerelease(releases: list[Release], current_tag: str) -> bool:
    current_release = next((release for release in releases if release.tag_name == current_tag), None)
    if current_release is not None:
        return current_release.prerelease
    return PRE_RELEASE_TAG_PATTERN.fullmatch(current_tag) is not None


def retained_tags(releases: list[Release], current_tag: str) -> set[str]:
    retained = {current_tag}
    current_prerelease = current_tag_prerelease(releases, current_tag)
    for prerelease in (True, False):
        if current_prerelease == prerelease:
            continue
        channel_releases = [
            release
            for release in releases
            if not release.draft and release.prerelease == prerelease and release.has_assets
        ]
        channel_releases.sort(key=lambda release: release.published_at, reverse=True)
        if channel_releases:
            retained.add(channel_releases[0].tag_name)
    return retained


def releases_to_prune(releases: list[Release], current_tag: str) -> list[Release]:
    retained = retained_tags(releases, current_tag)
    return [
        release
        for release in releases
        if not release.draft and release.has_assets and release.tag_name not in retained
    ]


def prebuilt_asset_name(release: Release) -> str:
    for asset in release.assets:
        name = asset.get("name") or ""
        if name.endswith(".tar.gz"):
            return name
    return "container-compose-plugin-release-arm64.tar.gz"


def source_install_section(
    release: Release,
    *,
    prebuilt_sha256: str | None = None,
) -> str:
    original_sha = prebuilt_sha256 or "unknown"
    asset_name = prebuilt_asset_name(release)
    return f"""\
{SOURCE_INSTALL_HEADING}

Original pruned prebuilt asset SHA-256:

```text
{original_sha}
```

The binary assets for this release were pruned. The source tag remains available. To rebuild and install this release with Homebrew, paste:

```sh
FORMULA="$(mktemp -t container-compose-source).rb"

cat >"${{FORMULA}}" <<RUBY
class ContainerComposeSource < Formula
  desc "Docker Compose style plugin for Apple's container CLI"
  homepage "https://github.com/stephenlclarke/container-compose"
  url "https://github.com/stephenlclarke/container-compose.git",
      tag: "{release.tag_name}",
      revision: "{release.target_commitish}"
  license "Apache-2.0"

  depends_on arch: :arm64
  depends_on macos: :sequoia
  depends_on "go" => :build
  depends_on "stephenlclarke/tap/container"

  def install
    original_prebuilt_sha256 = "{original_sha}"
    archive = "{asset_name}"
    system "make", "package-release", "PLUGIN_ARCHIVE=#{{archive}}"
    rebuilt_sha256 = `shasum -a 256 #{{archive}}`.split.first
    if original_prebuilt_sha256 != "unknown" && rebuilt_sha256 != original_prebuilt_sha256
      opoo "Local rebuild SHA-256 #{{rebuilt_sha256}} differs from pruned prebuilt SHA-256 #{{original_prebuilt_sha256}}."
      opoo "The install continues because local Swift, Go, and gzip output may not be byte-identical to the original CI artifact."
    end
    plugin = libexec/"container-plugins/compose"
    plugin.install Dir["dist/compose/*"]
    bin.install_symlink plugin/"bin/compose" => "container-compose"
  end
end
RUBY

brew tap stephenlclarke/tap
brew uninstall --ignore-dependencies stephenlclarke/tap/container-compose container-compose-source || true
brew install --build-from-source "${{FORMULA}}"
brew postinstall stephenlclarke/tap/container
brew services restart stephenlclarke/tap/container
```
"""


def body_without_source_install(existing_body: str) -> str:
    stripped = existing_body.rstrip()
    heading_index = stripped.find(SOURCE_INSTALL_HEADING)
    if heading_index == -1:
        return stripped
    return stripped[:heading_index].rstrip()


def body_with_source_install(
    existing_body: str,
    release: Release,
    *,
    prebuilt_sha256: str | None = None,
) -> str:
    stripped = body_without_source_install(existing_body)
    if stripped:
        return stripped + "\n\n" + source_install_section(release, prebuilt_sha256=prebuilt_sha256)
    return source_install_section(release, prebuilt_sha256=prebuilt_sha256)


def gh_output(arguments: list[str]) -> str:
    result = subprocess.run(arguments, check=True, capture_output=True, text=True)
    return result.stdout


def load_releases(repo: str) -> list[Release]:
    output = gh_output(
        [
            "gh",
            "api",
            "--paginate",
            "--slurp",
            f"repos/{repo}/releases",
        ]
    )
    pages = json.loads(output)
    releases: list[Release] = []
    for page in pages:
        releases.extend(release_from_json(release) for release in page)
    return releases


def release_asset_sha256(repo: str, release: Release) -> str | None:
    checksum_assets = [
        asset for asset in release.assets if (asset.get("name") or "").endswith(".sha256")
    ]
    if checksum_assets:
        with tempfile.TemporaryDirectory() as directory:
            checksum_name = checksum_assets[0]["name"]
            subprocess.run(
                [
                    "gh",
                    "release",
                    "download",
                    release.tag_name,
                    "--repo",
                    repo,
                    "--pattern",
                    checksum_name,
                    "--dir",
                    directory,
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            checksum_text = (Path(directory) / checksum_name).read_text(encoding="utf-8")
            match = SHA256_PATTERN.search(checksum_text)
            if match is not None:
                return match.group(0).lower()

    match = SHA256_PATTERN.search(release.body)
    if match is not None:
        return match.group(0).lower()
    return None


def edit_release_notes(repo: str, release: Release) -> None:
    body = body_with_source_install(
        release.body,
        release,
        prebuilt_sha256=release_asset_sha256(repo, release),
    )
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as notes:
        notes.write(body)
        notes_path = Path(notes.name)
    try:
        subprocess.run(
            [
                "gh",
                "release",
                "edit",
                release.tag_name,
                "--repo",
                repo,
                "--notes-file",
                str(notes_path),
            ],
            check=True,
        )
    finally:
        notes_path.unlink(missing_ok=True)


def delete_release_assets(repo: str, release: Release) -> None:
    for asset in release.assets:
        asset_id = asset["id"]
        subprocess.run(
            [
                "gh",
                "api",
                "-X",
                "DELETE",
                f"repos/{repo}/releases/assets/{asset_id}",
            ],
            check=True,
        )


def main() -> None:
    args = parse_args()
    releases = load_releases(args.repo)
    prune = releases_to_prune(releases, args.current_tag)
    if not prune:
        print("No older release assets to prune.")
        return

    for release in prune:
        asset_names = ", ".join(asset.get("name", str(asset["id"])) for asset in release.assets)
        print(f"Pruning {release.tag_name}: {asset_names}")
        if args.execute:
            edit_release_notes(args.repo, release)
            delete_release_assets(args.repo, release)


if __name__ == "__main__":
    main()
