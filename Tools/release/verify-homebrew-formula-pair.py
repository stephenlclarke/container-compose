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

"""Verify the complete stable Homebrew formula-pair publication contract."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


SHA256 = re.compile(r"[0-9a-f]{64}")
FIELD = {
    "sha256": re.compile(r'^  sha256 "([^"]*)"$', re.MULTILINE),
    "url": re.compile(r'^  url "([^"]*)"$', re.MULTILINE),
    "version": re.compile(r'^  version "([^"]*)"$', re.MULTILINE),
}


class FormulaError(RuntimeError):
    """A formula pair does not describe the expected stable closure."""


def regular_text(path: Path) -> str:
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        raise FormulaError(f"formula must be an absolute regular file: {path}")
    return path.read_text(encoding="utf-8")


def one_field(text: str, name: str, label: str) -> str:
    matches = FIELD[name].findall(text)
    if len(matches) != 1:
        raise FormulaError(f"{label} must contain exactly one {name}")
    return matches[0]


def verify(
    compose_path: Path,
    runtime_path: Path,
    compose_url: str,
    runtime_url: str,
    compose_sha: str,
    runtime_sha: str,
) -> None:
    if SHA256.fullmatch(compose_sha) is None or SHA256.fullmatch(runtime_sha) is None:
        raise FormulaError("expected formula digests must be lowercase SHA-256 values")
    compose = regular_text(compose_path)
    runtime = regular_text(runtime_path)
    if one_field(compose, "url", "compose formula") != compose_url:
        raise FormulaError("compose formula URL does not match the stable asset")
    if one_field(runtime, "url", "runtime formula") != runtime_url:
        raise FormulaError("runtime formula URL does not match the stable asset")
    if one_field(compose, "sha256", "compose formula") != compose_sha:
        raise FormulaError("compose formula digest does not match the stable asset")
    if one_field(runtime, "sha256", "runtime formula") != runtime_sha:
        raise FormulaError("runtime formula digest does not match the stable asset")
    if FIELD["version"].findall(compose):
        raise FormulaError("stable compose formula must derive its version from its URL")
    if 'depends_on "stephenlclarke/tap/container"' not in compose:
        raise FormulaError("stable compose formula is missing its runtime dependency")
    if "opt/container-compose/libexec/container-plugins/compose" not in runtime:
        raise FormulaError("stable runtime formula does not register the compose plugin")


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compose-formula", required=True, type=Path)
    parser.add_argument("--runtime-formula", required=True, type=Path)
    parser.add_argument("--compose-url", required=True)
    parser.add_argument("--runtime-url", required=True)
    parser.add_argument("--compose-sha256", required=True)
    parser.add_argument("--runtime-sha256", required=True)
    options = parser.parse_args(arguments)
    try:
        verify(
            options.compose_formula,
            options.runtime_formula,
            options.compose_url,
            options.runtime_url,
            options.compose_sha256,
            options.runtime_sha256,
        )
    except (FormulaError, OSError, UnicodeError) as error:
        print(f"verify-homebrew-formula-pair: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
