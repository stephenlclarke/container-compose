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
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any


SOURCE_INSTALL_HEADING = "## Source Install From This Release"


@dataclass(frozen=True)
class Release:
    tag_name: str
    name: str
    prerelease: bool
    draft: bool
    published_at: str
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
        assets=tuple(value.get("assets") or ()),
        body=value.get("body") or "",
    )


def retained_tags(releases: list[Release], current_tag: str) -> set[str]:
    retained = {current_tag}
    for prerelease in (True, False):
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


def source_install_section(release: Release) -> str:
    return f"""\
{SOURCE_INSTALL_HEADING}

The binary assets for this release were pruned. The source tag remains available. To rebuild and install this release with Homebrew, paste:

```sh
FORMULA="$(mktemp -t container-compose-source).rb"

cat >"${{FORMULA}}" <<RUBY
class ContainerComposeSource < Formula
  desc "Docker Compose style plugin for Apple's container CLI"
  homepage "https://github.com/stephenlclarke/container-compose"
  url "https://github.com/stephenlclarke/container-compose/archive/refs/tags/{release.tag_name}.tar.gz"
  sha256 :no_check
  license "Apache-2.0"

  depends_on arch: :arm64
  depends_on macos: :sequoia
  depends_on "go" => :build
  depends_on "stephenlclarke/tap/container"

  def install
    system "make", "package-release"
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


def body_with_source_install(existing_body: str, release: Release) -> str:
    stripped = existing_body.rstrip()
    if SOURCE_INSTALL_HEADING in stripped:
        return stripped + "\n"
    if stripped:
        return stripped + "\n\n" + source_install_section(release)
    return source_install_section(release)


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


def edit_release_notes(repo: str, release: Release) -> None:
    body = body_with_source_install(release.body, release)
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
