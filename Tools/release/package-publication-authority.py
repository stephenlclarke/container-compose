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

"""Verify one published release and its optional Homebrew output closure."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from collections.abc import Sequence
from urllib.parse import urlparse

REPOSITORY_PATTERN = re.compile(
    r"[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?/"
    r"[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?"
)
SHA_PATTERN = re.compile(r"[0-9a-f]{40}")
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
TAG_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")


def run_command(arguments: Sequence[str], cwd: Path | None = None) -> str:
    completed = subprocess.run(
        arguments,
        cwd=cwd,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"authority command failed ({completed.returncode}): "
            f"{' '.join(arguments)}\n{completed.stderr.strip()}"
        )
    return completed.stdout.strip()


def resolve_tag(repository: str, tag: str) -> str:
    output = run_command(
        (
            "git",
            "ls-remote",
            "--tags",
            f"https://github.com/{repository}.git",
            f"refs/tags/{tag}",
            f"refs/tags/{tag}^{{}}",
        )
    )
    direct = ""
    peeled = ""
    for line in output.splitlines():
        fields = line.split()
        if len(fields) != 2:
            continue
        if fields[1] == f"refs/tags/{tag}^{{}}":
            peeled = fields[0]
        elif fields[1] == f"refs/tags/{tag}":
            direct = fields[0]
    resolved = peeled or direct
    if SHA_PATTERN.fullmatch(resolved) is None:
        raise ValueError(f"published tag is missing or invalid: {repository}@{tag}")
    return resolved


def parse_formula(path: Path) -> tuple[str, str]:
    text = path.read_text(encoding="utf-8")
    url_match = re.search(r'^\s*url\s+"([^"]+)"\s*$', text, re.MULTILINE)
    sha_match = re.search(
        r'^\s*sha256\s+"([0-9a-f]{64})"\s*$', text, re.MULTILINE
    )
    if url_match is None or sha_match is None:
        raise ValueError(f"formula must declare one URL and SHA-256: {path}")
    run_command(("ruby", "-c", str(path)))
    return url_match.group(1), sha_match.group(1)


def parse_expected_assets(declarations: Sequence[str]) -> dict[str, str]:
    assets: dict[str, str] = {}
    for declaration in declarations:
        name, separator, digest = declaration.partition("=")
        if (
            not separator
            or not name
            or Path(name).name != name
            or SHA256_PATTERN.fullmatch(digest) is None
        ):
            raise ValueError(f"invalid release asset declaration: {declaration}")
        if name in assets:
            raise ValueError(f"duplicate release asset declaration: {name}")
        assets[name] = digest
    return assets


def verify_formula(
    path: Path,
    repository: str,
    tag: str,
    release_assets: dict[str, str],
) -> dict[str, str]:
    url, expected_digest = parse_formula(path)
    parsed = urlparse(url)
    prefix = f"/{repository}/releases/download/{tag}/"
    asset = Path(parsed.path).name
    if parsed.scheme != "https" or parsed.netloc != "github.com":
        raise ValueError(f"formula URL is not an HTTPS GitHub release asset: {path}")
    if not parsed.path.startswith(prefix) or not asset:
        raise ValueError(f"formula URL does not use {repository}@{tag}: {path}")
    actual_digest = release_assets.get(asset)
    if actual_digest != expected_digest:
        raise ValueError(
            f"formula digest does not match published asset {asset}: "
            f"expected {expected_digest}, got {actual_digest or 'missing'}"
        )
    return {"asset": asset, "path": str(path), "sha256": expected_digest}


def verify_tap(
    tap: Path,
    expected_ref: str,
    formulae: Sequence[Path],
    repository: str,
    tag: str,
    release_assets: dict[str, str],
) -> dict[str, object]:
    actual_ref = run_command(("git", "rev-parse", "HEAD"), cwd=tap)
    remote_ref = run_command(
        ("git", "ls-remote", "--heads", "origin", "refs/heads/main"), cwd=tap
    ).partition("\t")[0]
    if actual_ref != expected_ref or remote_ref != expected_ref:
        raise ValueError(
            "Homebrew tap authority changed: "
            f"expected {expected_ref}, local {actual_ref}, remote {remote_ref}"
        )
    relative_formulae = [str(path.relative_to(tap)) for path in formulae]
    status = run_command(
        ("git", "status", "--porcelain", "--", *relative_formulae), cwd=tap
    )
    if status:
        raise ValueError("Homebrew formula output is not committed")
    return {
        "formulae": [
            verify_formula(path, repository, tag, release_assets)
            for path in formulae
        ],
        "ref": actual_ref,
    }


def parse_arguments(arguments: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--release-tag", required=True)
    parser.add_argument("--release-ref", required=True)
    parser.add_argument(
        "--release-prerelease", choices=("true", "false"), required=True
    )
    parser.add_argument("--asset", action="append", default=[])
    parser.add_argument("--tap", type=Path)
    parser.add_argument("--tap-ref")
    parser.add_argument("--formula", action="append", type=Path, default=[])
    options = parser.parse_args(arguments)
    if REPOSITORY_PATTERN.fullmatch(options.repository) is None:
        parser.error(f"repository is invalid: {options.repository}")
    if TAG_PATTERN.fullmatch(options.release_tag) is None:
        parser.error(f"release tag is invalid: {options.release_tag}")
    if SHA_PATTERN.fullmatch(options.release_ref) is None:
        parser.error(f"release ref is not an immutable SHA: {options.release_ref}")
    tap_arguments = (
        options.tap is not None,
        options.tap_ref is not None,
        bool(options.formula),
    )
    if any(tap_arguments) and not all(tap_arguments):
        parser.error("tap, tap-ref, and at least one formula must be provided together")
    if options.tap_ref is not None and SHA_PATTERN.fullmatch(options.tap_ref) is None:
        parser.error(f"tap ref is not an immutable SHA: {options.tap_ref}")
    return options


def authority_digest(options: argparse.Namespace) -> str:
    expected_assets = parse_expected_assets(options.asset)
    release = json.loads(
        run_command(
            (
                "gh",
                "api",
                f"repos/{options.repository}/releases/tags/{options.release_tag}",
            )
        )
    )
    expected_prerelease = options.release_prerelease == "true"
    if (
        release.get("tag_name") != options.release_tag
        or release.get("draft") is not False
        or release.get("prerelease") is not expected_prerelease
        or not isinstance(release.get("id"), int)
    ):
        raise ValueError(
            f"published release state changed: {options.repository}@{options.release_tag}"
        )
    if resolve_tag(options.repository, options.release_tag) != options.release_ref:
        raise ValueError(
            f"published release tag moved: {options.repository}@{options.release_tag}"
        )
    published_assets = {
        asset.get("name"): str(asset.get("digest", "")).removeprefix("sha256:")
        for asset in release.get("assets", [])
        if isinstance(asset, dict) and isinstance(asset.get("name"), str)
    }
    for name, expected_digest in expected_assets.items():
        actual_digest = published_assets.get(name)
        if actual_digest != expected_digest:
            raise ValueError(
                f"published asset changed: {name} "
                f"(expected {expected_digest}, got {actual_digest or 'missing'})"
            )
    authority: dict[str, object] = {
        "assets": expected_assets,
        "release": {
            "id": release.get("id"),
            "prerelease": expected_prerelease,
            "repository": options.repository,
            "sha": options.release_ref,
            "tag": options.release_tag,
        },
        "schema": 1,
    }
    if options.tap is not None:
        authority["tap"] = verify_tap(
            options.tap.resolve(),
            options.tap_ref,
            [path.resolve() for path in options.formula],
            options.repository,
            options.release_tag,
            published_assets,
        )
    encoded = json.dumps(
        authority, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def main(arguments: Sequence[str]) -> int:
    try:
        print(authority_digest(parse_arguments(arguments)))
    except (json.JSONDecodeError, OSError, RuntimeError, ValueError) as error:
        print(
            f"package publication authority verification failed: {error}",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
