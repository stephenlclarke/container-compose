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

"""Update a Homebrew formula to point at a branch release asset."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--formula", required=True, type=Path)
    parser.add_argument("--template", type=Path)
    parser.add_argument("--formula-class")
    parser.add_argument("--conflicts-with")
    parser.add_argument("--url", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--plugin-version")
    parser.add_argument("--asset", required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--sha256", required=True)
    return parser.parse_args()


def replace_once(pattern: str, replacement: str, text: str) -> str:
    updated, count = re.subn(pattern, replacement, text, count=1, flags=re.MULTILINE)
    if count != 1:
        raise SystemExit(f"expected exactly one match for pattern: {pattern}")
    return updated


def update_conflict(formula_name: str | None, text: str) -> str:
    conflict_pattern = r'^  conflicts_with "[^"]+", because: ".+"$'
    conflict_line = (
        f'  conflicts_with "{formula_name}", because: '
        '"both formulae install the container-compose command and compose plugin"'
    )
    if formula_name is None:
        return text

    updated, count = re.subn(conflict_pattern, conflict_line, text, count=1, flags=re.MULTILINE)
    if count == 1:
        return updated

    dependency_pattern = r'(^  depends_on "stephenlclarke/tap/container"$)'
    updated, count = re.subn(
        dependency_pattern,
        rf"\1\n\n{conflict_line}",
        text,
        count=1,
        flags=re.MULTILINE,
    )
    if count != 1:
        raise SystemExit("expected container dependency before conflict insertion")
    return updated


def main() -> None:
    args = parse_args()
    if args.formula.exists():
        text = args.formula.read_text(encoding="utf-8")
    elif args.template is not None:
        text = args.template.read_text(encoding="utf-8")
    else:
        raise SystemExit(f"formula does not exist and no template was supplied: {args.formula}")

    if args.formula_class is not None:
        text = replace_once(r"^class \w+ < Formula$", f"class {args.formula_class} < Formula", text)
    text = update_conflict(args.conflicts_with, text)

    text = replace_once(r'^  url ".+"$', f'  url "{args.url}"', text)
    text = replace_once(r"^  sha256 .+$", f'  sha256 "{args.sha256}"', text)
    text = replace_once(r'^  version ".+"$', f'  version "{args.version}"', text)
    if args.plugin_version is not None:
        text = replace_once(
            r'assert_match "[^"]+", shell_output\("#\{bin\}/container-compose version --short"\)',
            f'assert_match "{args.plugin_version}", shell_output("#{{bin}}/container-compose version --short")',
            text,
        )
    text = replace_once(
        r"This formula installs the .+ prebuilt (?:release|package) asset:\n        .+\.tar\.gz",
        f"This formula installs the {args.label} prebuilt package asset:\n        {args.asset}",
        text,
    )
    args.formula.parent.mkdir(parents=True, exist_ok=True)
    args.formula.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
