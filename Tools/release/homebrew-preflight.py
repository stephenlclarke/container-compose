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

"""Fail fast on Homebrew release configuration before product builds begin."""

from __future__ import annotations

import argparse
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse


EXPECTED_REMOTE = "https://github.com/stephenlclarke/homebrew-tap.git"
EXPECTED_REPOSITORY = "stephenlclarke/container-compose"
FORMULAE = {
    "container": ("Container", "container-release-arm64.tar.gz", "stable"),
    "container-compose": (
        "ContainerCompose",
        "container-compose-plugin-release-arm64.tar.gz",
        "stable",
    ),
    "container-current": ("ContainerCurrent", None, "current"),
    "container-compose-current": ("ContainerComposeCurrent", None, "current"),
}


@dataclass(frozen=True)
class Formula:
    name: str
    class_name: str
    url: str
    sha256: str
    version: str | None

    @property
    def release_tag(self) -> str:
        match = re.search(r"/releases/download/([^/]+)/", self.url)
        if not match:
            raise ValueError(f"{self.name}: URL is not a GitHub release asset: {self.url}")
        return match.group(1)

    @property
    def asset(self) -> str:
        return Path(urlparse(self.url).path).name


def run(*arguments: str, cwd: Path | None = None) -> str:
    result = subprocess.run(
        list(arguments),
        cwd=cwd,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return result.stdout.strip()


def parse_formula(path: Path) -> Formula:
    text = path.read_text(encoding="utf-8")
    class_match = re.search(r"^class\s+(\w+)\s+<\s+Formula\s*$", text, re.MULTILINE)
    url_match = re.search(r'^\s*url\s+"([^"]+)"\s*$', text, re.MULTILINE)
    sha_match = re.search(r'^\s*sha256\s+"([0-9a-f]{64})"\s*$', text, re.MULTILINE)
    version_match = re.search(r'^\s*version\s+"([^"]+)"\s*$', text, re.MULTILINE)
    if not class_match or not url_match or not sha_match:
        raise ValueError(f"{path}: formula must declare class, URL, and SHA-256")
    run("ruby", "-c", str(path))
    return Formula(
        path.stem,
        class_match.group(1),
        url_match.group(1),
        sha_match.group(1),
        version_match.group(1) if version_match else None,
    )


def validate_template(repository: Path, relative_path: str) -> None:
    path = repository / relative_path
    if not path.is_file():
        raise ValueError(f"Homebrew formula template is missing: {path}")
    run("ruby", "-c", str(path))


def validate_container_formula_source(repository: Path) -> None:
    candidates = (
        "Tools/release/container.rb.in",
        "Formula/container.rb",
    )
    for relative_path in candidates:
        path = repository / relative_path
        if path.is_file():
            run("ruby", "-c", str(path))
            return
    raise ValueError(f"Container Homebrew formula source is missing: {repository}")


def validate_tap(tap: Path, require_clean: bool) -> dict[str, Formula]:
    if not (tap / ".git").exists():
        raise ValueError(f"Homebrew tap is not a Git checkout: {tap}")
    origin = run("git", "remote", "get-url", "origin", cwd=tap)
    normalized_origin = origin.removesuffix("/")
    if normalized_origin not in {
        EXPECTED_REMOTE.removesuffix(".git"),
        EXPECTED_REMOTE,
        "git@github.com:stephenlclarke/homebrew-tap.git",
    }:
        raise ValueError(f"unexpected Homebrew tap origin: {origin}")
    if require_clean and run("git", "status", "--porcelain", cwd=tap):
        raise ValueError(f"Homebrew tap has uncommitted changes: {tap}")

    formulae: dict[str, Formula] = {}
    for name, (expected_class, expected_asset, lane) in FORMULAE.items():
        formula = parse_formula(tap / "Formula" / f"{name}.rb")
        formulae[name] = formula
        if formula.class_name != expected_class:
            raise ValueError(
                f"{name}: expected class {expected_class}, found {formula.class_name}"
            )
        parsed = urlparse(formula.url)
        if parsed.scheme != "https" or parsed.netloc != "github.com":
            raise ValueError(f"{name}: release URL must use https://github.com")
        if f"/{EXPECTED_REPOSITORY}/releases/download/" not in parsed.path:
            raise ValueError(f"{name}: release URL points outside {EXPECTED_REPOSITORY}")
        if lane == "stable":
            if not re.fullmatch(r"[0-9]+[.][0-9]+[.][0-9]+", formula.release_tag):
                raise ValueError(f"{name}: stable formula tag is invalid: {formula.release_tag}")
            if formula.version is not None:
                raise ValueError(f"{name}: stable formula must derive its version from the URL")
            if formula.asset != expected_asset:
                raise ValueError(
                    f"{name}: expected stable asset {expected_asset}, found {formula.asset}"
                )
        else:
            if formula.release_tag != "current":
                raise ValueError(f"{name}: Current formula must use the current release tag")
            if not formula.version or not re.fullmatch(
                r"current[.][0-9]+[.][0-9a-f]{12}", formula.version
            ):
                raise ValueError(f"{name}: Current formula version is invalid: {formula.version}")

    if formulae["container"].release_tag != formulae["container-compose"].release_tag:
        raise ValueError("stable Container and Compose formulae do not use the same release tag")
    if formulae["container-current"].version != formulae["container-compose-current"].version:
        raise ValueError("Current Container and Compose formulae do not use the same version")
    return formulae


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tap", type=Path, required=True)
    parser.add_argument("--compose-repository", type=Path, required=True)
    parser.add_argument("--container-repository", type=Path)
    parser.add_argument("--allow-dirty-tap", action="store_true")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    validate_tap(arguments.tap.resolve(), not arguments.allow_dirty_tap)
    validate_template(
        arguments.compose_repository.resolve(), "Tools/release/container-compose.rb.in"
    )
    if arguments.container_repository:
        validate_container_formula_source(arguments.container_repository.resolve())
    print("Homebrew release configuration preflight passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
